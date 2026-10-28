import Darwin
import Foundation

nonisolated enum JSONFileStorage {
    static func withLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        guard let descriptor = try acquireLock(at: url) else { throw POSIXError(.EIO) }
        defer { releaseLock(descriptor) }
        return try operation()
    }

    static func acquireLock(at url: URL, nonblocking: Bool = false) throws -> Int32? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 原子创建并打开锁文件, 避免替换其他进程已锁定的 inode
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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

    static func save(_ value: some Encodable, to url: URL) throws {
        let data = try JSONLines.stableEncoder.encode(value)
        guard (try? Data(contentsOf: url)) != data else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
