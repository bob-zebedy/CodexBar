import Darwin
import Foundation

nonisolated enum BridgeIPC {
    struct EndSession: Error {}
    static let connected = Data("{\"bridge\":\"connected\"}\n".utf8)
    static let endSession = Data("{\"bridge\":\"end\"}\n".utf8)

    static func connect(to endpoint: BridgeEndpoint, hello: BridgeJSON) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        do {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            if endpoint.withAddress({ Darwin.connect(fd, $0, $1) }) != 0 {
                guard errno == EINPROGRESS else { throw POSIXError(.ENOTCONN) }
                var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout.size(ofValue: error))
                guard poll(&event, 1, 1000) > 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw POSIXError(.ENOTCONN) }
            }
            guard fcntl(fd, F_SETFL, 0) == 0 else { throw POSIXError(.EIO) }
            try write(hello.data() + Data([10]), to: fd)
            // 握手应答之前不会发送 MCP 消息
            var reply = Data()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(1)
            while reply.count < connected.count {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw POSIXError(.ETIMEDOUT) }
                let milliseconds = Int32((remaining / .milliseconds(1)).rounded(.up))
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, milliseconds) > 0 else { throw POSIXError(.ETIMEDOUT) }
                var buffer = [UInt8](repeating: 0, count: connected.count - reply.count)
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { throw POSIXError(.ENOTCONN) }
                reply.append(contentsOf: buffer.prefix(count))
                if reply.contains(10) {
                    break
                }
            }
            if reply == endSession {
                throw EndSession()
            }
            guard reply == connected else { throw POSIXError(.EPROTO) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let size = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if size < 0, errno == EINTR {
                    continue
                }
                guard size > 0 else { throw POSIXError(.EPIPE) }
                offset += size
            }
        }
    }
}

nonisolated struct BridgeLineReader {
    let limit: Int
    private var partial = Data()

    init(limit: Int) {
        self.limit = limit
    }

    mutating func read(from descriptor: Int32) throws -> [Data]? {
        var buffer = Data(count: 16384)
        let size = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if size < 0, errno == EINTR {
            return []
        }
        guard size >= 0 else { throw POSIXError(.EIO) }
        guard size > 0 else { return nil }
        var bytes = buffer.prefix(size)
        var lines: [Data] = []
        while let line = try nextLine(in: &bytes) {
            lines.append(line)
        }
        return lines
    }

    /// 只扫描新收到的字节, 保留跨分片的半行及完整消息的换行符
    mutating func nextLine(in bytes: inout Data) throws -> Data? {
        while !bytes.isEmpty {
            let newline = bytes.firstIndex(of: 10)
            let end = newline ?? bytes.endIndex
            let fragment = bytes[..<end]
            guard fragment.count <= limit - partial.count else { throw BridgeFailure("message_too_large") }
            partial.append(fragment)
            guard let newline else {
                bytes = Data()
                return nil
            }
            bytes = bytes.suffix(from: newline + 1)
            if !partial.isEmpty {
                partial.append(10)
                let line = partial
                partial = Data()
                return line
            }
        }
        return nil
    }
}
