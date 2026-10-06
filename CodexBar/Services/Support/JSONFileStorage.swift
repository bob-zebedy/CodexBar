import Darwin
import Foundation

nonisolated enum JSONFileStorage {
    static func withLock<T>(in directory: URL, _ operation: () throws -> T) throws -> T {
        guard let descriptor = try acquireLock(in: directory) else { throw POSIXError(.EIO) }
        defer { releaseLock(descriptor) }
        return try operation()
    }

    static func acquireLock(in directory: URL, name: String = "store.lock", nonblocking: Bool = false) throws -> Int32? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(name).path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            let code = errno
            close(descriptor)
            if nonblocking, code == EWOULDBLOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    static func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func load<T: Decodable>(_: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONLines.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    static func save(_ value: some Encodable, to url: URL) throws {
        let data = try JSONLines.stableEncoder.encode(value)
        guard (try? Data(contentsOf: url)) != data else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

// 调用方持有文件锁, 每次核对磁盘字节后复用解码结果, 不依赖 mtime 判断跨进程修改
