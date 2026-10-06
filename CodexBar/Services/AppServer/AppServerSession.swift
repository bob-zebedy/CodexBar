import CryptoKit
import Darwin
import Foundation

nonisolated struct AppServerConnectionError: LocalizedError {
    let code: Int32

    var serverIsAbsent: Bool {
        code == ENOENT || code == ECONNREFUSED
    }

    var errorDescription: String? {
        String(localized: "codex-status.app-server.error.connection-closed") + " (\(String(cString: strerror(code))), errno=\(code))"
    }
}

/// 每条连接由所属 actor 独占, 通过 Unix WebSocket 访问 Codex 后台服务, 不拥有 daemon 生命周期
final nonisolated class AppServerSession {
    private var descriptor: Int32 = -1
    private var nextID = 0
    private var notifications: [Data] = []
    private let logStorage: AppServerLogStore?
    private let socketPath: String
    private let connectionName: String
    private let retainsNotifications: Bool
    var isOpen: Bool {
        descriptor >= 0
    }

    private static let maximumMessageSize = 16 * 1024 * 1024

    init(socketURL: URL, retainsNotifications: Bool = true, logStorage: AppServerLogStore? = .shared, connectionName: String = "activity") throws {
        socketPath = socketURL.path
        self.logStorage = logStorage
        self.connectionName = connectionName
        self.retainsNotifications = retainsNotifications
        let connectionLogID = logStorage?.recordConnection(method: "connection/open", detail: socketPath, connection: connectionName, status: .pending)
        do {
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw AppServerConnectionError(code: errno) }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw AppServerConnectionError(code: errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketURL.path.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw CodexStatusError.serverConnectionClosed
            }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                path.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                let code = errno
                guard code == EINPROGRESS else { throw AppServerConnectionError(code: code) }
                guard try ready(Int16(POLLOUT), before: Date().addingTimeInterval(2)) else {
                    throw CodexStatusError.serverTimeout
                }
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
                    throw AppServerConnectionError(code: errno)
                }
                guard socketError == 0 else { throw AppServerConnectionError(code: socketError) }
            }
            var enabled: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            try handshake()
            if let connectionLogID {
                logStorage?.finishRequest(connectionLogID, response: socketPath)
            }
        } catch {
            if let connectionLogID {
                logStorage?.failRequest(connectionLogID, message: error.localizedDescription)
            }
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
        logStorage?.recordConnection(method: "connection/closed", detail: socketPath, connection: connectionName, status: .information)
    }

    func initialize() throws {
        let result: Initialization = try request("initialize", params: [
            "clientInfo": ["name": "codex_bar_activity", "version": Bundle.main.shortVersionString ?? "1.0.0"],
            "capabilities": ["experimentalApi": true]
        ])
        let version = result.userAgent.split(separator: " ").first?.split(separator: "/").last.map(String.init)
        guard let version,
              CodexVersionReader.isVersion(version, atLeast: CodexMinimumVersion.activity) == true else {
            throw CodexStatusError.unsupportedVersion(minimum: CodexMinimumVersion.activity)
        }
        try send(["method": "initialized"])
    }

    func request<Response: Decodable>(_ method: String, params: [String: Any] = [:]) throws -> Response {
        nextID += 1
        let id = nextID
        let payload = try AppServerRPC.encode(method: method, id: id, params: params)
        return try AppServerRPC.decode(exchange(payload, id: id, timeout: 10), as: Response.self)
    }

    struct PendingRequest {
        let id: Int
        let logID: UUID?
        let deadline: ContinuousClock.Instant
    }

    enum RequestPoll {
        case waiting
        case event(Data)
        case response(Data)
    }

    /// 活动连接分步等响应, 由所属 actor 在等待期间消费推送和处理取消
    func beginRequest(_ method: String, params: [String: Any]) throws -> PendingRequest {
        nextID += 1
        let payload = try AppServerRPC.encode(method: method, id: nextID, params: params)
        let request = PendingRequest(
            id: nextID,
            logID: logStorage?.beginRequest(method: method, payload: String(bytes: payload, encoding: .utf8) ?? "", connection: connectionName),
            deadline: ContinuousClock.now.advanced(by: .seconds(10))
        )
        do { try sendFrame(payload, opcode: 1) } catch {
            fail(request, error: error)
            throw error
        }
        return request
    }

    func poll(_ request: PendingRequest) throws -> RequestPoll {
        try Task.checkCancellation()
        guard ContinuousClock.now < request.deadline else { throw CodexStatusError.serverTimeout }
        guard let data = try receive(before: Date().addingTimeInterval(0.02), matchingResponseID: request.id) else { return .waiting }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexStatusError.invalidServerResponse
        }
        if object["id"] as? Int == request.id, object["result"] != nil || object["error"] != nil {
            if let logID = request.logID {
                let response = (String(bytes: data, encoding: .utf8) ?? "")
                if object["error"] != nil {
                    logStorage?.failRequest(logID, message: response)
                } else {
                    logStorage?.finishRequest(logID, response: response)
                }
            }
            return .response(data)
        }
        return .event(data)
    }

    func fail(_ request: PendingRequest, error: Error) {
        if let logID = request.logID {
            logStorage?.failRequest(logID, message: error.localizedDescription)
        }
    }

    /// 账户和活动连接共用帧协议与请求日志, 业务解码由调用方负责
    func exchange(_ payload: Data, id: Int, timeout: TimeInterval) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let method = request?["method"] as? String ?? "unknown"
        let text = String(data: payload, encoding: .utf8) ?? ""
        let token = logStorage?.beginRequest(method: method, payload: text, connection: connectionName)
        do {
            let data = try receiveResponse(payload, id: id, timeout: timeout)
            if let token {
                let response = String(data: data, encoding: .utf8) ?? ""
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if object?["error"] != nil {
                    logStorage?.failRequest(token, message: response)
                } else {
                    logStorage?.finishRequest(token, response: response)
                }
            }
            return data
        } catch {
            if let token {
                logStorage?.failRequest(token, message: error.localizedDescription)
            }
            throw error
        }
    }

    private func receiveResponse(_ payload: Data, id: Int, timeout: TimeInterval) throws -> Data {
        try sendFrame(payload, opcode: 1)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let data = try receive(before: deadline, matchingResponseID: id),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["id"] as? Int == id, object["result"] != nil || object["error"] != nil {
                return data
            }
            // 审批请求只作为观察事件, 绝不在旁观连接中回答
            if retainsNotifications {
                guard notifications.count < 4096 else { throw CodexStatusError.serverConnectionClosed }
                notifications.append(data)
            }
        }
        throw CodexStatusError.serverTimeout
    }

    func notify(_ payload: Data) throws {
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let method = object?["method"] as? String ?? "unknown"
        let text = String(data: payload, encoding: .utf8) ?? ""
        do {
            try sendFrame(payload, opcode: 1)
            logStorage?.recordSent(method: method, payload: text, connection: connectionName)
        } catch {
            logStorage?.recordSent(method: method, payload: text, connection: connectionName, error: error.localizedDescription)
            throw error
        }
    }

    func nextEvent() throws -> Data? {
        if !notifications.isEmpty {
            return notifications.removeFirst()
        }
        do {
            return try receive(before: Date().addingTimeInterval(0.05))
        } catch {
            logStorage?.recordFailure(method: "connection/receive", message: error.localizedDescription, connection: connectionName, source: .connection)
            throw error
        }
    }

    private func handshake() throws {
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let text = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let deadline = Date().addingTimeInterval(5)
        let token = logStorage?.beginRequest(method: "websocket/handshake", payload: text, connection: connectionName, source: .connection)
        var header = Data()
        do {
            try write(Data(text.utf8), before: deadline)
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 16384 {
                try header.append(read(1, before: deadline))
            }
            guard let response = String(data: header, encoding: .utf8) else { throw CodexStatusError.invalidServerResponse }
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            guard response.hasPrefix("HTTP/1.1 101 "), response.contains(expected) else {
                throw CodexStatusError.invalidServerResponse
            }
            if let token {
                logStorage?.finishRequest(token, response: response)
            }
        } catch {
            if let token {
                let received = String(data: header, encoding: .utf8) ?? header.base64EncodedString()
                logStorage?.failRequest(token, message: received.isEmpty ? error.localizedDescription : received + "\n" + error.localizedDescription)
            }
            throw error
        }
    }

    private func send(_ object: [String: Any]) throws {
        try notify(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private func sendFrame(_ payload: Data, opcode: UInt8) throws {
        let mask = (0 ..< 4).map { _ in UInt8.random(in: .min ... .max) }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0xFE)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        } else {
            frame.append(0xFF)
            frame.append(contentsOf: (0 ..< 8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 255) })
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        do {
            try write(frame, before: Date().addingTimeInterval(5))
            if opcode != 1 {
                logStorage?.recordSent(method: controlMethod(opcode), payload: framePayload(payload), connection: connectionName)
            }
        } catch {
            if opcode != 1 {
                logStorage?.recordSent(
                    method: controlMethod(opcode),
                    payload: framePayload(payload),
                    connection: connectionName,
                    error: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func receive(before deadline: Date, matchingResponseID: Int? = nil) throws -> Data? {
        guard try ready(Int16(POLLIN), before: deadline) else { return nil }
        let frameDeadline = Date().addingTimeInterval(10)
        var message = Data()
        var fragmented = false
        while true {
            let header = try [UInt8](read(2, before: frameDeadline))
            let opcode = header[0] & 15
            var length = UInt64(header[1] & 127)
            if length == 126 || length == 127 {
                length = try read(length == 126 ? 2 : 8, before: frameDeadline).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            guard length <= Self.maximumMessageSize, message.count + Int(length) <= Self.maximumMessageSize,
                  header[1] & 128 == 0 else { throw CodexStatusError.invalidServerResponse }
            let payload = try read(Int(length), before: frameDeadline)
            if opcode >= 8 {
                logStorage?.recordReceived(method: controlMethod(opcode), payload: framePayload(payload), connection: connectionName)
            }
            if opcode == 8 {
                throw CodexStatusError.serverConnectionClosed
            }
            if opcode == 9 {
                guard header[0] & 128 != 0, length <= 125 else { throw CodexStatusError.invalidServerResponse }
                try sendFrame(payload, opcode: 10)
                if !fragmented, try !ready(Int16(POLLIN), before: deadline) {
                    return nil
                }
                continue
            }
            if opcode == 10 {
                guard header[0] & 128 != 0, length <= 125 else { throw CodexStatusError.invalidServerResponse }
                if !fragmented, try !ready(Int16(POLLIN), before: deadline) {
                    return nil
                }
                continue
            }
            guard header[0] & 0x70 == 0, opcode == (fragmented ? 0 : 1) else { throw CodexStatusError.invalidServerResponse }
            message.append(payload)
            if header[0] & 128 != 0 {
                recordIncoming(message, matchingResponseID: matchingResponseID)
                return message
            }
            fragmented = true
        }
    }

    /// 在完整消息首次读取时记录, 队列取出和业务消费不重复写日志
    private func recordIncoming(_ data: Data, matchingResponseID: Int?) {
        guard let logStorage else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let matchingResponseID, object?["id"] as? Int == matchingResponseID,
           object?["result"] != nil || object?["error"] != nil {
            return
        }
        guard Self.shouldRecordIncoming(object) else { return }
        let method = object?["method"] as? String ?? "app-server/message"
        logStorage.recordReceived(method: method, payload: framePayload(data), connection: connectionName)
    }

    /// 推送只记录业务使用的状态事件, 错误和异常协议消息保留以便排查
    /// 此判断不参与消息路由, 被过滤的消息仍交给业务消费
    private static func shouldRecordIncoming(_ object: [String: Any]?) -> Bool {
        guard let object, let method = object["method"] as? String else { return true }
        if method == "error" || method == "warning" {
            return true
        }
        guard ActivityNotification.category(for: method) == .state else { return false }
        switch method {
        case "item/started", "item/completed":
            guard let params = object["params"] as? [String: Any],
                  let item = params["item"] as? [String: Any], let type = item["type"] as? String else { return true }
            return ActivityItem.isToolType(type) || type == "contextCompaction" || type == "subAgentActivity"
        default:
            return true
        }
    }

    private func controlMethod(_ opcode: UInt8) -> String {
        switch opcode {
        case 8: "websocket/close"
        case 9: "websocket/ping"
        case 10: "websocket/pong"
        default: "websocket/opcode/\(opcode)"
        }
    }

    private func framePayload(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "base64:" + data.base64EncodedString()
    }

    private func ready(_ events: Int16, before deadline: Date) throws -> Bool {
        guard descriptor >= 0 else { throw CodexStatusError.serverConnectionClosed }
        var descriptor = pollfd(fd: descriptor, events: events, revents: 0)
        while Date() < deadline {
            try Task.checkCancellation()
            let result = Darwin.poll(&descriptor, 1, Int32(max(1, min(100, deadline.timeIntervalSinceNow * 1000))))
            if result < 0, errno == EINTR {
                continue
            }
            guard result >= 0 else { throw CodexStatusError.serverConnectionClosed }
            if result == 0 {
                continue
            }
            if descriptor.revents & events != 0 {
                return true
            }
            throw CodexStatusError.serverConnectionClosed
        }
        return false
    }

    private func read(_ count: Int, before deadline: Date) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 65536))
        while result.count < count {
            guard try ready(Int16(POLLIN), before: deadline) else { throw CodexStatusError.serverTimeout }
            let size = recv(descriptor, &buffer, min(buffer.count, count - result.count), 0)
            if size < 0, errno == EINTR || errno == EAGAIN {
                continue
            }
            guard size > 0 else { throw CodexStatusError.serverConnectionClosed }
            result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }

    private func write(_ data: Data, before deadline: Date) throws {
        var offset = 0
        while offset < data.count {
            guard try ready(Int16(POLLOUT), before: deadline) else { throw CodexStatusError.serverTimeout }
            let size = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if size < 0, errno == EINTR || errno == EAGAIN {
                continue
            }
            guard size > 0 else { throw CodexStatusError.serverConnectionClosed }
            offset += size
        }
    }

    private struct Initialization: Decodable { let userAgent: String }
}
