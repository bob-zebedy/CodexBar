import CloudKit
import Foundation

/// 每个线程轮次一个云端累计记录, 多设备通过条件写入收敛到同一份用量
actor CodexTokenHistorySync {
    private let database: CKDatabase
    private let directoryURL: URL
    private var fileCache: CodexTokenFileCache<TokenSyncCache>
    static let recordType = "CodexBarTokenTurn"
    private static let currentSchema = 1

    init(database: CKDatabase, directoryURL: URL) {
        self.database = database
        self.directoryURL = directoryURL
        fileCache = CodexTokenFileCache(url: directoryURL.appendingPathComponent("cache.json"))
    }

    func recoveryBaseline(accountScopedDeviceID: String?) -> CodexTokenHistoryBaseline? {
        guard let accountScopedDeviceID, let cache = try? load(), cache.accountScopedDeviceID == accountScopedDeviceID else { return nil }
        return CodexTokenHistoryBaseline(salt: cache.salt, turns: cache.turns)
    }

    func snapshot(local: [CodexTokenTurn], accountScopedDeviceID: String?) -> [String: CodexTokenUsage] {
        guard let cache = try? load(), cache.accountScopedDeviceID == accountScopedDeviceID else {
            return CodexTokenTurn.dailyUsage(local)
        }
        return CodexTokenTurn.dailyUsage(CodexTokenTurn.pseudonymized(local, salt: cache.salt) + Array(cache.turns.values))
    }

    func hasPendingUpdates(local: [CodexTokenTurn], accountScopedDeviceID: String?) -> Bool {
        let records = CodexTokenTurn.syncable(local)
        guard let cache = try? load(), cache.accountScopedDeviceID == accountScopedDeviceID else { return !records.isEmpty }
        return records.contains { turn in
            let candidate = turn.pseudonymized(salt: cache.salt)
            guard let remote = cache.turns[candidate.id] else { return true }
            return remote.merging(candidate) != remote
        }
    }

    func synchronize(local: [CodexTokenTurn], accountScopedDeviceID: String, salt: Data, zoneID: CKRecordZone.ID) async throws {
        // 整轮同步共用非阻塞锁, 防止另一个进程用较早的快照覆盖游标, 界面读取不等待网络
        guard let lock = try CodexTokenFileStorage.acquireLock(in: directoryURL, name: "sync.lock", nonblocking: true) else { return }
        defer { CodexTokenFileStorage.releaseLock(lock) }
        var cache = try load() ?? TokenSyncCache(accountScopedDeviceID: accountScopedDeviceID, salt: salt)
        if cache.accountScopedDeviceID != accountScopedDeviceID || cache.salt != salt {
            cache = TokenSyncCache(accountScopedDeviceID: accountScopedDeviceID, salt: salt)
        }
        do {
            try await fetch(into: &cache, zoneID: zoneID)
        } catch let error as CKError where error.code == .changeTokenExpired {
            cache.cursor = nil
            cache.turns = [:]
            try await fetch(into: &cache, zoneID: zoneID)
        }
        // 先落盘拉取结果, 上传失败时也能展示已经读取的其他设备贡献
        try save(cache)
        try await upload(local: local, cache: &cache, zoneID: zoneID)
        try await prune(cache: &cache, zoneID: zoneID)
        try save(cache)
    }

    private func fetch(into cache: inout TokenSyncCache, zoneID: CKRecordZone.ID) async throws {
        var token = try cache.cursor.flatMap {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        var more = true
        while more {
            try Task.checkCancellation()
            let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: nil, resultsLimit: 200)
            for modification in result.modificationResultsByID.values {
                if let turn = try Self.turn(from: modification.get().record) {
                    cache.turns[turn.id] = turn
                }
            }
            for deletion in result.deletions where deletion.recordType == Self.recordType {
                cache.turns.removeValue(forKey: deletion.recordID.recordName)
            }
            token = result.changeToken
            more = result.moreComing
        }
        cache.cursor = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    private func upload(local: [CodexTokenTurn], cache: inout TokenSyncCache, zoneID: CKRecordZone.ID) async throws {
        let pending = CodexTokenTurn.pseudonymized(CodexTokenTurn.syncable(local), salt: cache.salt)
            .filter { candidate in
                guard let remote = cache.turns[candidate.id] else { return true }
                return remote.merging(candidate) != remote
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        let deadline = Date().addingTimeInterval(20)
        for offset in stride(from: 0, to: pending.count, by: 25) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let batch = Array(pending[offset ..< min(offset + 25, pending.count)])
            let ids = batch.map { Self.recordID($0.id, zoneID: zoneID) }
            let existing = try await database.records(for: ids)
            var saving: [CKRecord] = []
            for candidate in batch {
                let id = Self.recordID(candidate.id, zoneID: zoneID)
                let record = try fetchedRecord(existing[id])
                    ?? CKRecord(recordType: Self.recordType, recordID: id)
                let remote = Self.turn(from: record)
                let merged = remote?.merging(candidate) ?? candidate
                if remote == merged {
                    cache.turns[merged.id] = merged
                    continue
                }
                Self.apply(merged, to: record)
                saving.append(record)
            }
            if saving.isEmpty {
                continue
            }
            let result = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            var failure: (any Error)?
            for record in saving {
                switch result.saveResults[record.recordID] {
                case let .success(saved):
                    if let turn = Self.turn(from: saved) {
                        cache.turns[turn.id] = turn
                    }
                case let .failure(error): failure = error
                case nil: failure = TokenHistorySyncError.missingRecordResult
                }
            }
            try save(cache)
            // 冲突不会使用覆盖写入, 下一轮重新获取服务端累计值后合并
            if let failure {
                throw failure
            }
        }
    }

    private func fetchedRecord(_ result: Result<CKRecord, any Error>?) throws -> CKRecord? {
        switch result {
        case let .success(record): record
        case let .failure(error as CKError) where error.code == .unknownItem: nil
        case let .failure(error): throw error
        case nil: throw TokenHistorySyncError.missingRecordResult
        }
    }

    private func prune(cache: inout TokenSyncCache, zoneID: CKRecordZone.ID) async throws {
        let cutoff = WorkflowStorage.retentionCutoffDate()
        let requiredRoots = Set(cache.turns.values.filter { $0.updatedAt >= cutoff }.map(\.rootID))
        let expired = cache.turns.values.filter {
            $0.updatedAt < cutoff && !requiredRoots.contains($0.id)
        }.prefix(200)
        let ids = expired.map { Self.recordID($0.id, zoneID: zoneID) }
        guard !ids.isEmpty else { return }
        let result = try await database.modifyRecords(saving: [], deleting: ids, atomically: false)
        for id in ids {
            guard let deletion = result.deleteResults[id] else { throw TokenHistorySyncError.missingRecordResult }
            do { try deletion.get() } catch let error as CKError where error.code == .unknownItem {}
            cache.turns.removeValue(forKey: id.recordName)
        }
    }

    private func load() throws -> TokenSyncCache? {
        try CodexTokenFileStorage.withLock(in: directoryURL) {
            let cache = try fileCache.load()
            guard cache == nil || cache?.schema == TokenSyncCache.currentSchema else { throw CocoaError(.fileReadCorruptFile) }
            return cache
        }
    }

    private func save(_ cache: TokenSyncCache) throws {
        try CodexTokenFileStorage.withLock(in: directoryURL) {
            try fileCache.save(cache)
        }
    }

    static func recordID(_ id: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    static func apply(_ turn: CodexTokenTurn, to record: CKRecord) {
        record["schemaVersion"] = currentSchema as CKRecordValue
        record["rootID"] = turn.rootID as CKRecordValue
        record["startedAt"] = turn.startedAt as CKRecordValue?
        record["observedAt"] = turn.updatedAt as CKRecordValue
        record["rebuiltAt"] = turn.rebuiltAt as CKRecordValue?
        record["usage"] = turn.usage.flatMap { try? JSONLines.stableEncoder.encode($0) } as CKRecordValue?
    }

    static func turn(from record: CKRecord) -> CodexTokenTurn? {
        guard record.recordType == recordType, (record["schemaVersion"] as? NSNumber)?.intValue == currentSchema,
              let rootID = record["rootID"] as? String,
              let updatedAt = record["observedAt"] as? Date else { return nil }
        let id = record.recordID.recordName
        guard isHash(id), isHash(rootID) else { return nil }
        var usage: CodexTokenUsage?
        if let value = record["usage"] {
            guard let data = value as? Data, let decoded = try? JSONDecoder().decode(CodexTokenUsage.self, from: data), decoded.isValid else { return nil }
            usage = decoded
        }
        if let rebuiltAt = record["rebuiltAt"], !(rebuiltAt is Date) {
            return nil
        }
        return CodexTokenTurn(
            id: id, rootID: rootID, startedAt: record["startedAt"] as? Date, updatedAt: updatedAt,
            usage: usage, rebuiltAt: record["rebuiltAt"] as? Date
        )
    }

    private static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }
}

private nonisolated struct TokenSyncCache: Codable, Equatable {
    static let currentSchema = 1
    var schema = currentSchema
    let accountScopedDeviceID: String
    let salt: Data
    var turns: [String: CodexTokenTurn] = [:]
    var cursor: Data?

    private enum CodingKeys: String, CodingKey {
        case schema
        case accountScopedDeviceID = "accountID"
        case salt, turns, cursor
    }
}

private nonisolated enum TokenHistorySyncError: Error {
    case missingRecordResult
}
