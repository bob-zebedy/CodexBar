import Darwin
import Foundation
import os

nonisolated struct ActivityProtectionRecord: Codable, Equatable, Sendable {
    let taskIdentifier: String
    let lastProgressAt: Date
    let markedAt: Date
    let expiresAt: Date
}

nonisolated struct ActivityProtectionRemoval: Sendable {
    let taskIdentifier: String
    let matchingMarkedAt: Date?

    init(taskIdentifier: String, matchingMarkedAt: Date? = nil) {
        self.taskIdentifier = taskIdentifier
        self.matchingMarkedAt = matchingMarkedAt
    }
}

/// 异常任务标记的本地存储, actor 隔离进程内访问, flock 保护 Debug 和 Release 共用文件
actor ActivityProtectionStateStore {
    private let directoryURL: URL
    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        directoryURL = applicationSupportURL
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("ActivityProtection", isDirectory: true)
        stateURL = directoryURL.appendingPathComponent("state.json", isDirectory: false)
        lockURL = directoryURL.appendingPathComponent("state.lock", isDirectory: false)
    }

    func load(now: Date = Date()) -> [String: ActivityProtectionRecord] {
        do {
            return try withExclusiveLock {
                var records = loadRecordsWithoutLock()
                let originalCount = records.count
                records = records.filter { $0.value.expiresAt > now }
                if records.count != originalCount {
                    try saveRecordsWithoutLock(records)
                }
                return records
            }
        } catch {
            AppLog.activity.error(
                "异常任务状态读取失败: reason=\(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    func apply(
        upserts: [ActivityProtectionRecord] = [],
        removals: [ActivityProtectionRemoval] = [],
        now: Date = Date()
    ) throws {
        try withExclusiveLock {
            var records = loadRecordsWithoutLock()
            records = records.filter { $0.value.expiresAt > now }

            for removal in removals {
                guard let existing = records[removal.taskIdentifier] else {
                    continue
                }
                if let matchingMarkedAt = removal.matchingMarkedAt,
                   existing.markedAt != matchingMarkedAt {
                    continue
                }
                records.removeValue(forKey: removal.taskIdentifier)
            }

            for record in upserts {
                guard record.expiresAt > now else {
                    continue
                }
                if let existing = records[record.taskIdentifier],
                   existing.markedAt > record.markedAt {
                    continue
                }
                records[record.taskIdentifier] = record
            }

            try saveRecordsWithoutLock(records)
        }
    }

    private func withExclusiveLock<T>(_ work: () throws -> T) throws -> T {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let fileDescriptor = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(fileDescriptor)
        }

        let lockDeadline = ProcessInfo.processInfo.systemUptime + Self.lockTimeout
        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN || lockError == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
            }
            guard ProcessInfo.processInfo.systemUptime < lockDeadline else {
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(Self.lockRetryMicroseconds)
        }
        defer {
            flock(fileDescriptor, LOCK_UN)
        }

        return try work()
    }

    private static let lockTimeout: TimeInterval = 2
    private static let lockRetryMicroseconds: useconds_t = 50000

    private func loadRecordsWithoutLock() -> [String: ActivityProtectionRecord] {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return [:]
        }
        guard let data = try? Data(contentsOf: stateURL), !data.isEmpty,
              let state = try? JSONDecoder().decode(ActivityProtectionState.self, from: data),
              state.schemaVersion == ActivityProtectionState.currentSchemaVersion else {
            AppLog.activity.error("异常任务状态已忽略: reason=invalidState")
            return [:]
        }

        return Dictionary(
            state.records.map { ($0.taskIdentifier, $0) },
            uniquingKeysWith: { current, candidate in
                current.markedAt >= candidate.markedAt ? current : candidate
            }
        )
    }

    private func saveRecordsWithoutLock(
        _ records: [String: ActivityProtectionRecord]
    ) throws {
        let state = ActivityProtectionState(
            schemaVersion: ActivityProtectionState.currentSchemaVersion,
            records: records.values.sorted {
                $0.taskIdentifier < $1.taskIdentifier
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
        chmod(stateURL.path, 0o600)
    }
}

private nonisolated struct ActivityProtectionState: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let records: [ActivityProtectionRecord]
}
