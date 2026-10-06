import CryptoKit
import Darwin
import Foundation
import Testing

/// 只绑定临时 Unix socket, 不访问用户的 Codex 服务或配置
final nonisolated class SharedServerFixture: @unchecked Sendable {
    let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).sock")
    private let descriptor: Int32
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failure: (any Error)?

    init(connections: Int = 1, handler: @escaping @Sendable (Peer) throws -> Void) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw FixtureError.io }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            Array(url.path.utf8CString).withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw FixtureError.io
        }
        DispatchQueue.global().async { [self] in
            defer { completed.signal() }
            do {
                for _ in 0 ..< connections {
                    var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    guard poll(&poller, 1, 5000) > 0 else { throw FixtureError.io }
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else { throw FixtureError.io }
                    defer { Darwin.close(client) }
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var enabled: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                    let peer = Peer(descriptor: client)
                    try peer.handshake()
                    try handler(peer)
                }
            } catch {
                lock.withLock { failure = error }
            }
        }
    }

    func finish() throws {
        guard completed.wait(timeout: .now() + 6) == .success else { throw FixtureError.io }
        if let error = lock.withLock({ failure }) {
            throw error
        }
    }

    func close() {
        Darwin.close(descriptor)
        try? FileManager.default.removeItem(at: url)
    }

    struct Peer {
        let descriptor: Int32

        func handshake() throws {
            var header = Data()
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 16384 {
                try header.append(read(1))
            }
            let text = try #require(String(data: header, encoding: .utf8))
            let key = try #require(text.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key: ") }?.dropFirst(19))
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            try write(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        }

        func readMessage() throws -> [String: Any] {
            let data = try readPayload(opcode: 1)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func readPayload(opcode: UInt8) throws -> Data {
            let header = try [UInt8](read(2))
            #expect(header[0] == 0x80 | opcode)
            #expect(header[1] & 0x80 != 0)
            var length = Int(header[1] & 127)
            if length == 126 || length == 127 {
                length = try read(length == 126 ? 2 : 8).reduce(0) { ($0 << 8) | Int($1) }
            }
            guard length < 65536 else { throw FixtureError.io }
            let mask = try [UInt8](read(4))
            return try Data(read(length).enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }

        func reply(to request: [String: Any], result: [String: Any]) throws {
            try send(["id": #require(request["id"]), "result": result])
        }

        func send(_ object: [String: Any]) throws {
            try sendRaw(JSONSerialization.data(withJSONObject: object))
        }

        func sendRaw(_ payload: Data, opcode: UInt8 = 1) throws {
            var frame = Data([0x80 | opcode])
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else {
                frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
            }
            frame.append(payload)
            try write(frame)
        }

        private func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                var buffer = [UInt8](repeating: 0, count: count - data.count)
                let received = Darwin.read(descriptor, &buffer, buffer.count)
                guard received > 0 else { throw FixtureError.io }
                data.append(contentsOf: buffer.prefix(received))
            }
            return data
        }

        private func write(_ data: Data) throws {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { throw FixtureError.io }
                    offset += written
                }
            }
        }
    }

    private enum FixtureError: Error { case io }
}
