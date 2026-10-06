import Darwin
import Foundation

enum SleepOwnership: String, Codable {
    case idle
    case owned
    case restoring

    var needsRestore: Bool {
        self != .idle
    }

    var sharedState: CodexBarSleepOwnershipState {
        switch self {
        case .idle:
            .idle
        case .owned:
            .owned
        case .restoring:
            .restoring
        }
    }
}

struct SleepOwnershipRecord: Codable {
    let schema: Int
    let state: SleepOwnership
    let transaction: UUID
    let identifier: String?
    let updated: Date
}

enum OwnershipRecordState {
    case absent
    case present(SleepOwnershipRecord)
    case unreadable(Error)
}

protocol OwnershipStoring {
    var url: URL { get }
    func ensureOwnershipDirectory() throws
    func writeOwnershipDataDurably(_ data: Data) throws
    func ownershipRecordState() -> OwnershipRecordState
}

struct OwnershipStore: OwnershipStoring {
    let url: URL

    func ensureOwnershipDirectory() throws {
        let directoryURL = url.deletingLastPathComponent()
        var info = stat()
        if lstat(directoryURL.path, &info) == 0 {
            try validateOwnershipDirectory(info)
            return
        }

        guard errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755],
            ofItemAtPath: directoryURL.path
        )
    }

    private func validateOwnershipDirectory(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFDIR else {
            let details = LogFields.joined(
                "actual=\(fileTypeName(info.st_mode))",
                "expected=directory"
            )
            throw HelperError.insecureOwnershipDirectory(
                "目录类型错误: \(details)"
            )
        }
        guard info.st_uid == 0 else {
            let details = LogFields.joined(
                "actual=\(info.st_uid)",
                "expected=0"
            )
            throw HelperError.insecureOwnershipDirectory(
                "所有者错误: \(details)"
            )
        }
        guard info.st_mode & 0o022 == 0 else {
            let details = LogFields.joined(
                "actual=\(permissionString(info.st_mode))",
                "forbidden=0022"
            )
            throw HelperError.insecureOwnershipDirectory(
                "目录权限错误: \(details)"
            )
        }
    }

    func writeOwnershipDataDurably(_ data: Data) throws {
        let directoryURL = url.deletingLastPathComponent()
        let temporaryURL = directoryURL.appending(
            path: ".helper-state.\(UUID().uuidString).tmp"
        )
        var descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw ownershipWriteError(operation: "open")
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                _ = Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL.path)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }

            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw ownershipWriteError(operation: "write")
                }
                offset += written
            }
        }

        guard fchown(descriptor, 0, 0) == 0 else {
            throw ownershipWriteError(operation: "fchown")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ownershipWriteError(operation: "fchmod")
        }
        try synchronizeOwnershipFile(descriptor)

        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw ownershipWriteError(operation: "close")
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw ownershipWriteError(operation: "rename")
        }
        shouldRemoveTemporaryFile = false
        try synchronizeOwnershipDirectory(directoryURL)
    }

    private func synchronizeOwnershipFile(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        guard fsync(descriptor) == 0 else {
            throw ownershipWriteError(operation: "fsync")
        }
    }

    private func synchronizeOwnershipDirectory(_ directoryURL: URL) throws {
        let descriptor = open(directoryURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ownershipWriteError(operation: "openDirectory")
        }
        defer {
            _ = Darwin.close(descriptor)
        }

        guard fsync(descriptor) == 0 else {
            let errorCode = errno
            // 部分文件系统不支持对目录执行 fsync, 文件本身已经完成 F_FULLFSYNC
            if errorCode == EINVAL || errorCode == ENOTSUP {
                return
            }
            throw ownershipWriteError(operation: "fsyncDirectory", code: errorCode)
        }
    }

    private func ownershipWriteError(
        operation: String,
        code: Int32 = errno
    ) -> HelperError {
        .ownershipWriteFailed(operation: operation, code: code)
    }

    func ownershipRecordState() -> OwnershipRecordState {
        do {
            guard let record = try readOwnershipRecord() else {
                return .absent
            }
            return .present(record)
        } catch {
            return .unreadable(error)
        }
    }

    private func readOwnershipRecord() throws -> SleepOwnershipRecord? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw HelperError.invalidOwnershipRecord(
                "读取属性失败: errno=\(errno)"
            )
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            let details = LogFields.joined(
                "actual=\(fileTypeName(info.st_mode))",
                "expected=file"
            )
            throw HelperError.invalidOwnershipRecord(
                "文件类型错误: \(details)"
            )
        }
        guard info.st_uid == 0 else {
            let details = LogFields.joined(
                "actual=\(info.st_uid)",
                "expected=0"
            )
            throw HelperError.invalidOwnershipRecord(
                "所有者错误: \(details)"
            )
        }
        guard info.st_mode & 0o022 == 0 else {
            let details = LogFields.joined(
                "actual=\(permissionString(info.st_mode))",
                "forbidden=0022"
            )
            throw HelperError.invalidOwnershipRecord(
                "文件权限错误: \(details)"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HelperError.invalidOwnershipRecord(
                "读取内容失败: detail=\(error.localizedDescription)"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record: SleepOwnershipRecord
        do {
            record = try decoder.decode(SleepOwnershipRecord.self, from: data)
        } catch {
            throw HelperError.invalidOwnershipRecord(
                "解码失败: detail=\(error.localizedDescription)"
            )
        }
        guard record.schema == 1 else {
            let details = LogFields.joined(
                "actual=\(record.schema)",
                "expected=1"
            )
            throw HelperError.invalidOwnershipRecord(
                "版本错误: \(details)"
            )
        }
        return record
    }

    private func fileTypeName(_ mode: mode_t) -> String {
        let type = mode & S_IFMT
        if type == S_IFREG {
            return "file"
        }
        if type == S_IFDIR {
            return "directory"
        }
        if type == S_IFLNK {
            return "symlink"
        }
        return String(format: "0x%X", Int32(type))
    }

    private func permissionString(_ mode: mode_t) -> String {
        String(format: "%04o", Int32(mode & 0o7777))
    }
}
