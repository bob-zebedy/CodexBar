import CloudKit
import Foundation

/// 每个线程轮次一个云端累计记录, 多设备通过条件写入收敛到同一份用量
actor TokenSync {
    private let database: any SyncDatabase
    private let directoryURL: URL
    private let isEnabled: @Sendable () -> Bool
    private var fileCache: TokenFileCache<TokenSyncCache>
    static let recordType = "Tokens"
    private static let currentVersion = 1

    init(database: any SyncDatabase, directoryURL: URL, isEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled() }) {
        self.database = database
        self.directoryURL = directoryURL
        self.isEnabled = isEnabled
        fileCache = TokenFileCache(url: directoryURL.appendingPathComponent("cache.json"))
    }

    func recoveryBaseline(accountScopedDeviceID: String?) -> TokenHistoryBaseline? {
        guard let accountScopedDeviceID, let cache = try? load(), cache.accountScopedDeviceID == accountScopedDeviceID else { return nil }
        return TokenHistoryBaseline(salt: cache.salt, turns: cache.turns)
    }

    func snapshot(local: [TokenTurn], accountScopedDeviceID: String?) throws -> [String: TokenUsage] {
        guard let cache = try load(), cache.accountScopedDeviceID == accountScopedDeviceID else {
            return TokenTurn.dailyUsage(local)
        }
        let merged = try TokenTurn.merged(TokenTurn.pseudonymized(local, salt: cache.salt) + Array(cache.turns.values))
        return TokenTurn.dailyUsage(Array(merged.values))
    }

    func hasPendingUpdates(local: [TokenTurn], accountScopedDeviceID: String?) -> Bool {
        let records = TokenTurn.syncable(local)
        guard let cache = try? load(), cache.accountScopedDeviceID == accountScopedDeviceID else { return !records.isEmpty }
        return records.contains { turn in
            let candidate = turn.pseudonymized(salt: cache.salt)
            guard let remote = cache.turns[candidate.id] else { return true }
            return (try? remote.merging(candidate)) != remote
        }
    }

    func resetCache() throws {
        try SyncCancellation.check(isEnabled: isEnabled)
        guard let lock = try JSONFileStorage.acquireLock(in: directoryURL, name: "sync.lock", nonblocking: true) else {
            throw POSIXError(.EWOULDBLOCK)
        }
        defer { JSONFileStorage.releaseLock(lock) }
        try JSONFileStorage.withLock(in: directoryURL) {
            do { _ = try Self.loadCache(&fileCache) } catch is DecodingError {
                // 已知格式损坏可清除, 未知版本继续向上抛出
            }
            if FileManager.default.fileExists(atPath: fileCache.url.path) {
                try FileManager.default.removeItem(at: fileCache.url)
            }
            fileCache = TokenFileCache(url: fileCache.url)
        }
    }

    func synchronize(local: [TokenTurn], recoveredIDs: Set<String> = [], accountScopedDeviceID: String, salt: Data, zoneID: CKRecordZone.ID) async throws {
        try SyncCancellation.check(isEnabled: isEnabled)
        // 整轮同步共用非阻塞锁, 防止另一个进程用较早的快照覆盖游标, 界面读取不等待网络
        guard let lock = try JSONFileStorage.acquireLock(in: directoryURL, name: "sync.lock", nonblocking: true) else { return }
        defer { JSONFileStorage.releaseLock(lock) }
        var cache: TokenSyncCache
        do {
            cache = try load() ?? TokenSyncCache(accountScopedDeviceID: accountScopedDeviceID, salt: salt)
        } catch is DecodingError {
            cache = TokenSyncCache(accountScopedDeviceID: accountScopedDeviceID, salt: salt)
        }
        if cache.accountScopedDeviceID != accountScopedDeviceID || cache.salt != salt {
            cache = TokenSyncCache(accountScopedDeviceID: accountScopedDeviceID, salt: salt)
        }
        do {
            try await fetch(into: &cache, zoneID: zoneID)
        } catch where SyncRecovery.isInvalidCursor(error) {
            var rebuilt = TokenSyncCache(accountScopedDeviceID: accountScopedDeviceID, salt: salt)
            try await fetch(into: &rebuilt, zoneID: zoneID)
            cache = rebuilt
        }
        // 先落盘拉取结果, 上传失败时也能展示已经读取的其他设备贡献
        try save(cache)
        try await upload(local: local, recoveredIDs: recoveredIDs, cache: &cache, zoneID: zoneID)
        try await prune(cache: &cache, zoneID: zoneID)
        try save(cache)
    }

    private func fetch(into cache: inout TokenSyncCache, zoneID: CKRecordZone.ID) async throws {
        var token = try cache.cursor.map(SyncRecovery.decodeCursor)
        var turns = token == nil ? [:] : cache.turns
        var more = true
        while more {
            try Task.checkCancellation()
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.fetchChanges(inZoneWith: zoneID, since: token, resultsLimit: 200)
            for modification in result.records.values {
                if let turn = try Self.turn(from: modification.get()) {
                    turns[turn.id] = turn
                }
            }
            for deletion in result.deletions where deletion.type == Self.recordType {
                turns.removeValue(forKey: deletion.id.recordName)
            }
            token = result.token
            more = result.moreComing
        }
        cache.turns = turns
        cache.cursor = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    private func upload(local: [TokenTurn], recoveredIDs: Set<String>, cache: inout TokenSyncCache, zoneID: CKRecordZone.ID) async throws {
        // 恢复结果先与本轮新鲜云端基线建立替换关系, 再执行普通条件写入
        let baseline = TokenHistoryBaseline(salt: cache.salt, turns: cache.turns)
        let candidates = local.compactMap { turn -> TokenTurn? in
            guard recoveredIDs.contains(turn.id) else { return turn }
            guard baseline.acceptsRecovery(turn) else { return nil }
            return baseline.replacement(for: turn, recovering: true) ?? turn
        }
        let pending = try TokenTurn.pseudonymized(TokenTurn.syncable(candidates), salt: cache.salt)
            .filter { candidate in
                guard let remote = cache.turns[candidate.id] else { return true }
                return try remote.merging(candidate) != remote
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        let deadline = Date().addingTimeInterval(20)
        var failures = SyncFailures()
        for offset in stride(from: 0, to: pending.count, by: 25) {
            try Task.checkCancellation()
            guard Date() < deadline else { break }
            let batch = Array(pending[offset ..< min(offset + 25, pending.count)])
            let ids = batch.map { Self.recordID($0.id, zoneID: zoneID) }
            try SyncCancellation.check(isEnabled: isEnabled)
            let existing = try await database.records(for: ids, desiredKeys: nil)
            var saving: [CKRecord] = []
            for candidate in batch {
                let id = Self.recordID(candidate.id, zoneID: zoneID)
                let record: CKRecord
                let remote: TokenTurn?
                do {
                    let fetched = try fetchedRecord(existing[id])
                    remote = try fetched.flatMap(Self.turn)
                    record = fetched ?? CKRecord(recordType: Self.recordType, recordID: id)
                } catch {
                    failures.record(error)
                    if failures.stopping != nil {
                        break
                    }
                    continue
                }
                let merged = try remote?.merging(candidate) ?? candidate
                if remote == merged {
                    cache.turns[merged.id] = merged
                    continue
                }
                Self.apply(merged, to: record)
                saving.append(record)
            }
            try save(cache)
            try failures.checkStopping()
            if saving.isEmpty {
                continue
            }
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            for record in saving {
                switch result.saveResults[record.recordID] {
                case let .success(saved):
                    if let turn = try Self.turn(from: saved) {
                        cache.turns[turn.id] = turn
                    }
                case let .failure(error): failures.record(error)
                case nil: failures.record(TokenSyncError.missingRecordResult)
                }
            }
            try save(cache)
            // 冲突不会使用覆盖写入, 下一轮重新获取服务端累计值后合并
            try failures.checkStopping()
        }
        try failures.check()
    }

    private func fetchedRecord(_ result: Result<CKRecord, any Error>?) throws -> CKRecord? {
        switch result {
        case let .success(record): record
        case let .failure(error as CKError) where error.code == .unknownItem: nil
        case let .failure(error): throw error
        case nil: throw TokenSyncError.missingRecordResult
        }
    }

    private func prune(cache: inout TokenSyncCache, zoneID: CKRecordZone.ID) async throws {
        let cutoff = HistoryStorage.retentionCutoffDate()
        let requiredRoots = Set(cache.turns.values.filter { $0.updatedAt >= cutoff }.map(\.rootID))
        let expired = cache.turns.values.filter {
            $0.updatedAt < cutoff && !requiredRoots.contains($0.id)
        }.prefix(200)
        let ids = expired.map { Self.recordID($0.id, zoneID: zoneID) }
        guard !ids.isEmpty else { return }
        try SyncCancellation.check(isEnabled: isEnabled)
        let result = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
        for id in ids {
            guard let deletion = result.deleteResults[id] else { throw TokenSyncError.missingRecordResult }
            do { try deletion.get() } catch let error as CKError where error.code == .unknownItem {}
            cache.turns.removeValue(forKey: id.recordName)
        }
    }

    private func load() throws -> TokenSyncCache? {
        try JSONFileStorage.withLock(in: directoryURL) { try Self.loadCache(&fileCache) }
    }

    private nonisolated static func loadCache(_ fileCache: inout TokenFileCache<TokenSyncCache>) throws -> TokenSyncCache? {
        try fileCache.load { data in
            let header = try JSONLines.decoder.decode(TokenSyncCacheHeader.self, from: data)
            guard header.version == TokenSyncCache.currentVersion else { throw SyncRecovery.Failure.unsupportedCacheVersion }
        }
    }

    private func save(_ cache: TokenSyncCache) throws {
        try JSONFileStorage.withLock(in: directoryURL) {
            var cache = cache
            cache.prune()
            try fileCache.save(cache)
        }
    }

    nonisolated static func pruneLocalCache(in directoryURL: URL, now: Date) throws {
        try JSONFileStorage.withLock(in: directoryURL) {
            var fileCache = TokenFileCache<TokenSyncCache>(url: directoryURL.appendingPathComponent("cache.json"))
            if var cache = try loadCache(&fileCache), cache.prune(now: now) {
                try fileCache.save(cache)
            }
        }
    }

    static func recordID(_ id: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    static func apply(_ turn: TokenTurn, to record: CKRecord) {
        record["version"] = currentVersion as CKRecordValue
        record["aggregationVersion"] = turn.aggregationVersion as CKRecordValue
        record["rootID"] = turn.rootID as CKRecordValue
        record["startedAt"] = turn.startedAt as CKRecordValue?
        record["updatedAt"] = turn.updatedAt as CKRecordValue
        record["rebuiltAt"] = turn.rebuiltAt as CKRecordValue?
        record["generationID"] = turn.generationID as CKRecordValue
        record["ancestorIDs"] = turn.ancestorIDs.sorted() as CKRecordValue
        record["checkpoint"] = try? JSONLines.stableEncoder.encode(turn.checkpoint) as CKRecordValue
        record["hasConflict"] = (turn.hasConflict ? 1 : 0) as CKRecordValue
        record["usage"] = turn.usage.flatMap { try? JSONLines.stableEncoder.encode($0) } as CKRecordValue?
    }

    static func turn(from record: CKRecord) throws -> TokenTurn? {
        guard record.recordType == recordType else { return nil }
        try StorageVersion.require((record["version"] as? NSNumber)?.intValue ?? -1, current: currentVersion, name: "CloudTokens")
        try AggregationVersion.require((record["aggregationVersion"] as? NSNumber)?.intValue ?? -1, current: AggregationVersion.tokens, name: "Tokens")
        guard
            let rootID = record["rootID"] as? String,
            let updatedAt = record["updatedAt"] as? Date,
            let generationID = record["generationID"] as? String,
            let ancestors = record["ancestorIDs"] as? [String],
            let checkpointData = record["checkpoint"] as? Data,
            let checkpoint = try? JSONDecoder().decode([String: TokenObservationCheckpoint].self, from: checkpointData),
            checkpoint.values.allSatisfy({ $0.sequence > 0 && $0.usage.isValid }),
            let hasConflict = record["hasConflict"] as? NSNumber else { throw StorageCompatibilityError.incompleteSource }
        let id = record.recordID.recordName
        guard isHash(id), isHash(rootID) else { throw StorageCompatibilityError.incompleteSource }
        var usage: TokenUsage?
        if let value = record["usage"] {
            guard let data = value as? Data, let decoded = try? JSONDecoder().decode(TokenUsage.self, from: data),
                  decoded.isValid else { throw StorageCompatibilityError.incompleteSource }
            usage = decoded
        }
        guard usage == nil || !checkpoint.isEmpty else { throw StorageCompatibilityError.incompleteSource }
        if let rebuiltAt = record["rebuiltAt"], !(rebuiltAt is Date) {
            throw StorageCompatibilityError.incompleteSource
        }
        return TokenTurn(
            id: id, rootID: rootID, startedAt: record["startedAt"] as? Date, updatedAt: updatedAt,
            usage: usage, rebuiltAt: record["rebuiltAt"] as? Date,
            generationID: generationID, ancestorIDs: Set(ancestors),
            checkpoint: checkpoint, hasConflict: hasConflict.boolValue,
            aggregationVersion: (record["aggregationVersion"] as? NSNumber)?.intValue ?? -1
        )
    }

    private static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }
}

private nonisolated struct TokenSyncCacheHeader: Decodable { let version: Int }

private nonisolated struct TokenSyncCache: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    let accountScopedDeviceID: String
    let salt: Data
    var turns: [String: TokenTurn] = [:]
    var cursor: Data?

    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        let roots = Set(turns.values.filter { $0.updatedAt >= cutoff }.map(\.rootID))
        let retained = turns.filter { $0.value.updatedAt >= cutoff || roots.contains($0.key) }
        guard retained.count != turns.count else { return false }
        turns = retained
        // 本地先过期, 云端删除仍可能失败. 下次完整拉取让过期记录重新进入删除流程
        cursor = nil
        return true
    }
}

private nonisolated enum TokenSyncError: Error {
    case missingRecordResult
}
