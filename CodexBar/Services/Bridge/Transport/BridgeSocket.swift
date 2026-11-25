import Darwin
import Foundation

nonisolated struct BridgeEndpoint {
    let path: String

    init(in directory: URL) throws {
        let url = directory.appendingPathComponent("mcp.sock")
        guard let path = try CodexPaths.unixSocketPath(url) else { throw BridgeFailure("socket_path_too_long") }
        self.path = path
    }

    func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var address = sockaddr_un()
        let length = socklen_t(MemoryLayout.size(ofValue: address))
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

/// 监听源独占描述符, 待已提交的事件处理完再关闭
final nonisolated class BridgeSocketListener {
    private let source: DispatchSourceRead
    private let path: String
    private let identity: stat

    init(in directory: URL, queue: DispatchQueue, onAccept: @escaping @Sendable (Int32) -> Void) throws {
        let endpoint = try BridgeEndpoint(in: directory)
        path = endpoint.path
        var entry = stat()
        if lstat(path, &entry) == 0 {
            guard entry.st_uid == getuid(), entry.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else { throw BridgeFailure("unsafe_socket_path") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        do {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
                  endpoint.withAddress({ Darwin.bind(fd, $0, $1) }) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            guard lstat(path, &entry) == 0, listen(fd, SOMAXCONN) == 0 else {
                let error = POSIXError(.init(rawValue: errno) ?? .EIO)
                unlink(path)
                throw error
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        identity = entry
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler {
            let client = Darwin.accept(fd, nil, nil)
            if client >= 0 {
                onAccept(client)
            }
        }
        source.activate()
    }

    deinit {
        source.cancel()
        var current = stat()
        if lstat(path, &current) == 0, current.st_dev == identity.st_dev, current.st_ino == identity.st_ino {
            unlink(path)
        }
    }
}

nonisolated struct BridgeSocketConnection: Sendable {
    private let channel: DispatchIO
    private let queue: DispatchQueue
    private static let chunkSize = 16384

    init(taking descriptor: Int32, queue: DispatchQueue) throws {
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            let error = POSIXError(.init(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in Darwin.close(descriptor) }
        channel.setLimit(lowWater: 1)
    }

    func close() {
        channel.close(flags: .stop)
    }

    func write(_ data: Data) async throws {
        let bytes = data.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.write(offset: 0, data: bytes, queue: queue) { done, _, error in
                guard done else { return }
                if error != 0 {
                    continuation.resume(throwing: POSIXError(.init(rawValue: error) ?? .EIO))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func readMessages(into peer: BridgePeer) async throws {
        var reader = BridgeLineReader(limit: 256 * 1024)
        while !Task.isCancelled {
            var received = 0
            for try await var chunk in readBatch() {
                received += chunk.count
                while let message = try reader.nextLine(in: &chunk) {
                    try await peer.accept(message)
                }
            }
            if received < Self.chunkSize {
                return
            }
        }
    }

    /// 短消息一有数据就交付, 消费完本批后再从 socket 读取下一批
    private func readBatch() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            channel.read(offset: 0, length: Self.chunkSize, queue: queue) { done, data, error in
                if let data, !data.isEmpty {
                    continuation.yield(Data(data))
                }
                if done {
                    if error == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: POSIXError(.init(rawValue: error) ?? .EIO))
                    }
                }
            }
        }
    }
}
