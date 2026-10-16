import Darwin
import Foundation

nonisolated enum HookConfigurationAccess {
    static func recoveryURL(for hooksURL: URL) -> URL {
        hooksURL.deletingLastPathComponent().appending(path: "hooks.codexbar-uninstall.json")
    }

    static func acquire(hooksURL: URL, recovering: Bool = false) throws -> AppUninstallLease {
        let directory = hooksURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = try AppUninstallLease.acquire(exclusive: true, url: directory.appending(path: "hooks.codexbar.lock"))
        guard recovering || !FileManager.default.fileExists(atPath: recoveryURL(for: hooksURL).path) else {
            throw AppUninstallError("Hook 卸载尚未完成, 请先重新运行卸载命令")
        }
        return lease
    }

    static func read(_ url: URL, limit: Int = 1024 * 1024) throws -> Data? {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= limit else {
                throw AppUninstallError("Hook 配置或恢复记录为符号链接或过大")
            }
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func replace(_ url: URL, expected: Data?, with data: Data) throws {
        guard try read(url) == expected else {
            throw AppUninstallError("Hook 配置被其他进程修改")
        }
        try data.write(to: url, options: .atomic)
    }

    static func saveRecovery(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".codexbar-recovery-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directoryDescriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 || errno == EINVAL || errno == ENOTSUP else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
