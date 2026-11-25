import Darwin
import Foundation

nonisolated enum BridgeStdio {
    static func run(directory: URL = BridgeStore.directory) -> Int32 {
        do {
            guard let token = ProcessInfo.processInfo.environment["CODEXBAR_BRIDGE_TOKEN"], !token.isEmpty, token.utf8.count <= 128 else {
                throw BridgeFailure("missing_credential", "Set CODEXBAR_BRIDGE_TOKEN using the MCP configuration for your token in CodexBar.")
            }
            signal(SIGPIPE, SIG_IGN)
            let relay = try BridgeStdioRelay(endpoint: BridgeEndpoint(in: directory), token: token)
            try relay.run()
            return EXIT_SUCCESS
        } catch is BridgeIPC.EndSession {
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return EXIT_FAILURE
        }
    }
}

/// 一次 stdio 会话由客户端持有, 期间可以替换主 App 的本地连接
final nonisolated class BridgeStdioRelay {
    private struct Envelope: Decodable {
        let jsonrpc: String?
        let id: BridgeJSON?
        let method: String?
        let session: BridgeJSON?

        func cancelledRequest(in line: Data) throws -> BridgeJSON? {
            guard method == "notifications/cancelled" else { return nil }
            return try JSONDecoder().decode(BridgeJSON.self, from: line)["params"]["requestId"].rpcID
        }
    }

    private let endpoint: BridgeEndpoint
    private let token: String
    private let input: Int32
    private let output: Int32
    private var socket: Int32 = -1
    private var clientReader = BridgeLineReader(limit: 256 * 1024)
    private var hostReader = BridgeLineReader(limit: 16 * 1024 * 1024)
    private var session: BridgeJSON = .null
    private var initialized = false
    private var pending = Set<BridgeJSON>()
    private var forms = Set<BridgeJSON>()

    init(endpoint: BridgeEndpoint, token: String, input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.endpoint = endpoint
        self.token = token
        self.input = input
        self.output = output
    }

    func run() throws {
        let flags = fcntl(output, F_GETFL)
        guard flags >= 0, fcntl(output, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        defer { _ = fcntl(output, F_SETFL, flags) }
        try connect()
        defer { closeSocket() }
        while true {
            var sources = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0), pollfd(fd: input, events: Int16(POLLIN), revents: 0)]
            let count = poll(&sources, 2, -1)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { throw POSIXError(.EIO) }
            // 两端同时就绪时先处理主 App 的响应或断开, 再决定新请求的去向
            if sources[0].revents != 0 {
                try receiveHost()
            }
            if sources[1].revents != 0 {
                guard let lines = try clientReader.read(from: input) else { return }
                for line in lines {
                    try receiveClient(line)
                }
            }
        }
    }

    private func connect() throws {
        do {
            socket = try BridgeIPC.connect(to: endpoint, hello: ["credential": .string(token), "session": session, "initialized": .bool(initialized)])
        } catch is BridgeIPC.EndSession {
            throw BridgeIPC.EndSession()
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
            throw BridgeFailure("bridge_busy", "CodexBar did not finish the handshake in time. Retry the connection.")
        } catch {
            throw BridgeFailure("bridge_unavailable", "Open CodexBar and enable Codex Bridge.")
        }
    }

    private func receiveClient(_ line: Data) throws {
        let message = try JSONDecoder().decode(Envelope.self, from: line)
        guard message.jsonrpc == "2.0" else { throw BridgeFailure("invalid_rpc") }
        if message.method == "notifications/initialized" {
            initialized = session != .null
        }
        if let id = try message.cancelledRequest(in: line) {
            pending.remove(id)
        }
        if let id = message.id?.rpcID, message.method != nil {
            guard pending.count < 64, !pending.contains(id) else {
                try fail(id, "Busy or duplicate request")
                return
            }
            if socket < 0 {
                do { try connect() } catch let failure as BridgeFailure {
                    try fail(id, failure.localizedDescription)
                    return
                }
            }
            pending.insert(id)
        } else if let id = message.id?.rpcID {
            guard forms.remove(id) != nil else { return }
        }
        guard socket >= 0 else { return }
        do { try BridgeIPC.write(line, to: socket) } catch { try disconnected() }
    }

    private func receiveHost() throws {
        guard let lines = try? hostReader.read(from: socket) else {
            try disconnected()
            return
        }
        for line in lines {
            if line == BridgeIPC.endSession {
                throw BridgeIPC.EndSession()
            }
            let message = try JSONDecoder().decode(Envelope.self, from: line)
            guard message.jsonrpc == "2.0" else { throw BridgeFailure("invalid_rpc") }
            if let id = try message.cancelledRequest(in: line) {
                forms.remove(id)
            }
            if let id = message.id?.rpcID {
                if message.method == nil {
                    pending.remove(id)
                } else {
                    forms.insert(id)
                }
            }
            if let negotiated = message.session, var fields = try JSONDecoder().decode(BridgeJSON.self, from: line).fields {
                session = negotiated
                fields.removeValue(forKey: "session")
                try send(.object(fields))
            } else {
                try writeOutput(line)
            }
        }
    }

    private func writeOutput(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                guard count < 0, errno == EAGAIN else { throw POSIXError(.EPIPE) }
                try waitForOutput()
            }
        }
    }

    private func waitForOutput() throws {
        // EV_EOF 在 socket 还有未读数据时也能识别主机断开
        let queue = kqueue()
        guard queue >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(queue) }
        var changes = [kevent(ident: UInt(output), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD), fflags: 0, data: 0, udata: nil)]
        if socket >= 0 {
            changes.append(kevent(ident: UInt(socket), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil))
        }
        guard kevent(queue, &changes, Int32(changes.count), nil, 0, nil) == 0 else { throw POSIXError(.EIO) }
        let deadline = ContinuousClock.now + .seconds(socket >= 0 ? 30 : 1)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw POSIXError(.ETIMEDOUT) }
            let (seconds, attoseconds) = remaining.components
            var timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1000000000))
            var event = kevent()
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { throw POSIXError(count == 0 ? .ETIMEDOUT : .EIO) }
            if event.ident == UInt(output) {
                guard event.flags & UInt16(EV_EOF | EV_ERROR) == 0 else { throw POSIXError(.EPIPE) }
                return
            }
            if event.flags & UInt16(EV_EOF | EV_ERROR) != 0 {
                var writable = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
                guard poll(&writable, 1, 1000) > 0 else { throw POSIXError(.ETIMEDOUT) }
                return
            }
        }
    }

    private func closeSocket() {
        if socket >= 0 {
            Darwin.close(socket)
        }
        socket = -1
    }

    private func disconnected() throws {
        closeSocket()
        hostReader = BridgeLineReader(limit: hostReader.limit)
        for id in forms {
            try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]])
        }
        forms.removeAll()
        for id in pending {
            try fail(id, "bridge_disconnected: The connection to CodexBar closed before a response arrived. Check the task before retrying.")
        }
        pending.removeAll()
    }

    private func fail(_ id: BridgeJSON, _ message: String) throws {
        try send(["jsonrpc": "2.0", "id": id, "error": ["code": .integer(-32000), "message": .string(message)]])
    }

    private func send(_ message: BridgeJSON) throws {
        try writeOutput(message.data() + Data([10]))
    }
}
