import Darwin
import Foundation
import os

nonisolated struct ProtectionRecord: Codable, Equatable, Sendable {
    let taskIdentifier: String
    let lastProgressAt: Date
    let markedAt: Date
    let expiresAt: Date
}

nonisolated struct ProtectionRemoval: Sendable {
    let taskIdentifier: String
    let matchingMarkedAt: Date?

    init(taskIdentifier: String, matchingMarkedAt: Date? = nil) {
        self.taskIdentifier = taskIdentifier
        self.matchingMarkedAt = matchingMarkedAt
    }
}

/// 异常任务标记的本地存储, actor 隔离进程内访问, flock 保护同一构建的多进程访问
actor ProtectionStore {
    private let directoryURL: URL
    private let stateURL: URL
    private let lockURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? AppStorage.directoryURL(fileManager: fileManager)
            .appendingPathComponent("Protection", isDirectory: true)
        stateURL = self.directoryURL.appendingPathComponent("state.json", isDirectory: false)
        lockURL = self.directoryURL.appendingPathComponent("state.lock", isDirectory: false)
    }

    func load(now: Date = Date()) throws -> [String: ProtectionRecord] {
        try withExclusiveLock {
            var records = try loadRecordsWithoutLock()
            let originalCount = records.count
            records = records.filter { $0.value.expiresAt > now }
            if records.count != originalCount {
                try saveRecordsWithoutLock(records)
            }
            return records
        }
    }

    func apply(
        upserts: [ProtectionRecord] = [],
        removals: [ProtectionRemoval] = [],
        now: Date = Date()
    ) throws {
        try withExclusiveLock {
            var records = try loadRecordsWithoutLock()
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

    private func loadRecordsWithoutLock() throws -> [String: ProtectionRecord] {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: stateURL)
        try StorageVersion.validate(data, current: ProtectionState.currentVersion, name: "Protection")
        let state = try JSONDecoder().decode(ProtectionState.self, from: data)

        return Dictionary(
            state.records.map { ($0.taskIdentifier, $0) },
            uniquingKeysWith: { current, candidate in
                current.markedAt >= candidate.markedAt ? current : candidate
            }
        )
    }

    private func saveRecordsWithoutLock(
        _ records: [String: ProtectionRecord]
    ) throws {
        let state = ProtectionState(
            version: ProtectionState.currentVersion,
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

private nonisolated struct ProtectionState: Codable {
    static let currentVersion = 1

    let version: Int
    let records: [ProtectionRecord]
}
