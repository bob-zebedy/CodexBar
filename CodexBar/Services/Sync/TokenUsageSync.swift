import CloudKit
import Foundation

/// 按设备和日期覆盖每日数量, 本机数据与其他设备的汇总分别保留
actor TokenUsageSync {
    private let database: any SyncDatabase
    private let storage: AppStorage
    private let isEnabled: @Sendable () -> Bool
    private var fileCache: TokenUsageFileCache<TokenUsageSyncCache>
    static let recordType = "TokenUsage"
    private static let schemaVersion = 1

    init(database: any SyncDatabase, directoryURL: URL, isEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled() }) {
        self.database = database
        storage = AppStorage(rootURL: directoryURL)
        self.isEnabled = isEnabled
        fileCache = TokenUsageFileCache(url: AppStorage(rootURL: directoryURL).tokenUsageSyncCacheURL)
    }

    func snapshot(local: [TokenUsageAggregate], accountScopedDeviceID: String?) throws -> [String: TokenUsage] {
        guard let deviceID = accountScopedDeviceID, let cache = try load(), cache.state.deviceID == deviceID else {
            return TokenUsageAggregate.tokenUsageByDate(local)
        }
        var records = cache.records
        for record in try TokenUsageSyncRecord.dailyRecords(local: local, deviceID: deviceID) {
            records[record.id] = record
        }
        return TokenUsageSyncRecord.tokenUsageByDate(Array(records.values))
    }

    func hasPendingUpdates(local: [TokenUsageAggregate], accountScopedDeviceID: String?) -> Bool {
        guard let deviceID = accountScopedDeviceID else { return !local.isEmpty }
        guard let records = try? TokenUsageSyncRecord.dailyRecords(local: local, deviceID: deviceID) else { return true }
        guard let cache = try? load(), cache.state.deviceID == deviceID else { return !records.isEmpty }
        return records.contains { cache.records[$0.id]?.hasSameData(as: $0) != true }
    }

    func resetCache() throws {
        try SyncCancellation.check(isEnabled: isEnabled)
        guard let lock = try JSONFileStorage.acquireLock(at: storage.lockURL(.tokenUsageSync), nonblocking: true) else {
            throw POSIXError(.EWOULDBLOCK)
        }
        defer { JSONFileStorage.releaseLock(lock) }
        try JSONFileStorage.withLock(at: storage.lockURL(.tokenUsageSyncCache)) {
            do { _ = try Self.loadCache(&fileCache) } catch is DecodingError {
                // 已知格式损坏可清除, 未知版本继续向上抛出
            }
            if FileManager.default.fileExists(atPath: fileCache.url.path) {
                try FileManager.default.removeItem(at: fileCache.url)
            }
            fileCache = TokenUsageFileCache(url: fileCache.url)
        }
    }

    func synchronize(local: [TokenUsageAggregate], accountScopedDeviceID: String, zoneID: CKRecordZone.ID, canUpload: Bool = true) async throws {
        try SyncCancellation.check(isEnabled: isEnabled)
        // 整轮同步共用非阻塞锁, 防止另一个进程用较早的快照覆盖游标, 界面读取不等待网络
        guard let lock = try JSONFileStorage.acquireLock(at: storage.lockURL(.tokenUsageSync), nonblocking: true) else { return }
        defer { JSONFileStorage.releaseLock(lock) }
        var cache: TokenUsageSyncCache
        do {
            cache = try load() ?? TokenUsageSyncCache(state: TokenUsageSyncState(deviceID: accountScopedDeviceID))
        } catch is DecodingError {
            cache = TokenUsageSyncCache(state: TokenUsageSyncState(deviceID: accountScopedDeviceID))
        }
        if cache.state.deviceID != accountScopedDeviceID {
            cache = TokenUsageSyncCache(state: TokenUsageSyncState(deviceID: accountScopedDeviceID))
        }
        do {
            try await fetch(into: &cache, zoneID: zoneID)
        } catch where SyncRecovery.isInvalidCursor(error) {
            var rebuilt = TokenUsageSyncCache(state: TokenUsageSyncState(deviceID: accountScopedDeviceID))
            try await fetch(into: &rebuilt, zoneID: zoneID)
            cache = rebuilt
        }
        // 先落盘拉取结果, 上传失败时也能展示已经读取的其他设备贡献
        try save(cache)
        // 原始事件不完整时仍可拉取其他设备数量, 但不能用局部结果替换整天的数量
        if canUpload {
            try await upload(local: local, cache: &cache, zoneID: zoneID)
        }
        try await prune(cache: &cache, zoneID: zoneID)
        try save(cache)
    }

    private func fetch(into cache: inout TokenUsageSyncCache, zoneID: CKRecordZone.ID) async throws {
        var token = try cache.cursor.map(SyncRecovery.decodeCursor)
        var records = token == nil ? [:] : cache.records
        var more = true
        while more {
            try Task.checkCancellation()
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.fetchChanges(inZoneWith: zoneID, since: token, resultsLimit: 200)
            for modification in result.records.values {
                if let record = try Self.dailyRecord(from: modification.get()) {
                    records[record.id] = record
                }
            }
            for deletion in result.deletions where deletion.type == Self.recordType {
                records.removeValue(forKey: deletion.id.recordName)
            }
            token = result.token
            more = result.moreComing
        }
        cache.records = records
        cache.cursor = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    private func upload(local: [TokenUsageAggregate], cache: inout TokenUsageSyncCache, zoneID: CKRecordZone.ID) async throws {
        let pending = try TokenUsageSyncRecord.dailyRecords(local: local, deviceID: cache.state.deviceID)
            .filter { cache.records[$0.id]?.hasSameData(as: $0) != true }
            .sorted { $0.date > $1.date }
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
                do {
                    let fetched = try fetchedRecord(existing[id])
                    if let remote = try fetched.flatMap(Self.dailyRecord), remote.hasSameData(as: candidate) {
                        cache.records[candidate.id] = remote
                        continue
                    }
                    let record = fetched ?? CKRecord(recordType: Self.recordType, recordID: id)
                    try Self.apply(candidate, to: record)
                    saving.append(record)
                } catch {
                    failures.record(error)
                    if failures.stopping != nil {
                        break
                    }
                }
            }
            try save(cache)
            try failures.checkStopping()
            guard !saving.isEmpty else { continue }
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.modifyRecords(saving: saving, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            for record in saving {
                switch result.saveResults[record.recordID] {
                case let .success(saved):
                    if let tokenUsageRecord = try Self.dailyRecord(from: saved) {
                        cache.records[tokenUsageRecord.id] = tokenUsageRecord
                    }
                case let .failure(error): failures.record(error)
                case nil: failures.record(TokenUsageSyncError.missingRecordResult)
                }
            }
            try save(cache)
            // 条件写入冲突后下轮重新读取, 每次都提交本机当前的完整日汇总
            try failures.checkStopping()
        }
        try failures.check()
    }

    private func fetchedRecord(_ result: Result<CKRecord, any Error>?) throws -> CKRecord? {
        switch result {
        case let .success(record): record
        case let .failure(error as CKError) where error.code == .unknownItem: nil
        case let .failure(error): throw error
        case nil: throw TokenUsageSyncError.missingRecordResult
        }
    }

    private func prune(cache: inout TokenUsageSyncCache, zoneID: CKRecordZone.ID) async throws {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        let expired = cache.records.values.filter {
            $0.deviceID == cache.state.deviceID && $0.date < cutoff
        }.prefix(200)
        let ids = expired.map { Self.recordID($0.id, zoneID: zoneID) }
        guard !ids.isEmpty else { return }
        try SyncCancellation.check(isEnabled: isEnabled)
        let result = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .ifServerRecordUnchanged, atomically: false)
        for id in ids {
            guard let deletion = result.deleteResults[id] else { throw TokenUsageSyncError.missingRecordResult }
            do { try deletion.get() } catch let error as CKError where error.code == .unknownItem {}
            cache.records.removeValue(forKey: id.recordName)
        }
    }

    private func load() throws -> TokenUsageSyncCache? {
        try JSONFileStorage.withLock(at: storage.lockURL(.tokenUsageSyncCache)) { try Self.loadCache(&fileCache) }
    }

    private nonisolated static func loadCache(_ fileCache: inout TokenUsageFileCache<TokenUsageSyncCache>) throws -> TokenUsageSyncCache? {
        let cache = try fileCache.load()
        guard cache?.state.containerIdentifier == SyncCloudKit.containerIdentifier else { return nil }
        return cache
    }

    private func save(_ cache: TokenUsageSyncCache) throws {
        try JSONFileStorage.withLock(at: storage.lockURL(.tokenUsageSyncCache)) {
            var cache = cache
            cache.prune()
            try fileCache.save(cache)
        }
    }

    nonisolated static func pruneLocalCache(in directoryURL: URL, now: Date) throws {
        let storage = AppStorage(rootURL: directoryURL)
        try JSONFileStorage.withLock(at: storage.lockURL(.tokenUsageSyncCache)) {
            var fileCache = TokenUsageFileCache<TokenUsageSyncCache>(url: AppStorage(rootURL: directoryURL).tokenUsageSyncCacheURL)
            if var cache = try loadCache(&fileCache), cache.prune(now: now) {
                try fileCache.save(cache)
            }
        }
    }

    static func recordID(_ id: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id, zoneID: zoneID)
    }

    static func apply(_ tokenUsageRecord: TokenUsageSyncRecord, to record: CKRecord) throws {
        record["schemaVersion"] = schemaVersion as CKRecordValue
        record["aggregationVersion"] = tokenUsageRecord.aggregationVersion as CKRecordValue
        record["deviceID"] = tokenUsageRecord.deviceID as CKRecordValue
        record["date"] = tokenUsageRecord.date as CKRecordValue
        record["updatedAt"] = Date() as CKRecordValue
        let tokenUsage = tokenUsageRecord.tokenUsage
        let tokenUsageCounts: [String: Int64?] = [
            "inputTokens": tokenUsage?.inputTokens, "cachedInputTokens": tokenUsage?.cachedInputTokens,
            "cacheWriteInputTokens": tokenUsage?.cacheWriteInputTokens, "outputTokens": tokenUsage?.outputTokens,
            "reasoningOutputTokens": tokenUsage?.reasoningOutputTokens, "totalTokens": tokenUsage?.totalTokens
        ]
        record["tokenUsage"] = try JSONLines.stableEncoder.encode(tokenUsageCounts) as CKRecordValue
    }

    static func dailyRecord(from record: CKRecord) throws -> TokenUsageSyncRecord? {
        guard record.recordType == recordType else { return nil }
        try StorageVersion.require((record["schemaVersion"] as? NSNumber)?.intValue ?? -1, current: schemaVersion, name: "CloudTokenUsage")
        let aggregationVersion = (record["aggregationVersion"] as? NSNumber)?.intValue ?? -1
        try AggregationVersion.require(aggregationVersion, current: AggregationVersion.tokenUsage, name: "tokenUsage")
        guard let deviceID = record["deviceID"] as? String, !deviceID.isEmpty,
              let date = record["date"] as? String, HistoryStorage.isValidDateKey(date),
              let data = record["tokenUsage"] as? Data else { throw StorageCompatibilityError.incompleteSource }
        let tokenUsageCounts = try JSONDecoder().decode([String: Int64?].self, from: data)
        guard Set(tokenUsageCounts.keys) == [
            "inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens"
        ], tokenUsageCounts.values.compactMap(\.self).allSatisfy({ $0 >= 0 }) else { throw StorageCompatibilityError.incompleteSource }
        var tokenUsage: TokenUsage?
        if tokenUsageCounts.values.allSatisfy({ $0 != nil }) {
            let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
            guard decoded.isValid else { throw StorageCompatibilityError.incompleteSource }
            tokenUsage = decoded
        }
        let tokenUsageRecord = TokenUsageSyncRecord(
            aggregationVersion: aggregationVersion, deviceID: deviceID, date: date, tokenUsage: tokenUsage,
            updatedAt: record["updatedAt"] as? Date ?? record.modificationDate
        )
        guard tokenUsageRecord.id == record.recordID.recordName else { throw StorageCompatibilityError.incompleteSource }
        return tokenUsageRecord
    }
}

typealias TokenUsageSyncCache = SyncCache<TokenUsageSyncRecord, TokenUsageSyncState>

nonisolated struct TokenUsageSyncState: Codable, Equatable {
    var containerIdentifier = SyncCloudKit.containerIdentifier
    let deviceID: String
}

nonisolated extension SyncCache where Record == TokenUsageSyncRecord, State == TokenUsageSyncState {
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        let retained = records.filter { $0.value.date >= cutoff }
        guard retained.count != records.count else { return false }
        records = retained
        // 本地先过期, 云端删除仍可能失败. 下次完整拉取让过期记录重新进入删除流程
        cursor = nil
        return true
    }
}

private nonisolated enum TokenUsageSyncError: Error {
    case missingRecordResult
}
