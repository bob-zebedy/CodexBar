import CloudKit
import CryptoKit
import Foundation
import IOKit
import os
import Security

nonisolated enum SyncCloudKit {
    static let containerIdentifier = "iCloud.app.zabrian.codexbar.data"

    static let zoneName = "CodexBarAppZone"

    static func makeContainer() -> CKContainer {
        CKContainer(identifier: containerIdentifier)
    }
}

/// 同步失败时定位到哪一步, 只用于日志
private nonisolated enum SyncStage: String {
    case zone
    case device
    case fetch
    case upload
    case tokenUsage
    case prune
}

/// 同步各设备的每日汇总, 本机数量只覆盖本设备记录
actor SyncService {
    private let container: CKContainer?
    private let suppliedDatabase: (any SyncDatabase)?
    private lazy var database: any SyncDatabase = suppliedDatabase ?? (container ?? SyncCloudKit.makeContainer()).privateCloudDatabase
    private let directoryURL: URL
    private let isEnabled: @Sendable () -> Bool
    private lazy var tokenUsageSync = TokenUsageSync(
        database: database, directoryURL: directoryURL, isEnabled: isEnabled
    )

    // zone 存在性跨轮缓存, 共享故障后重新确认
    private var isSyncZoneConfirmed = false
    private var lastActivityDataCacheRetentionCutoff: Date?
    private var lastTokenUsageCacheRetentionCutoff: Date?
    private var isActivityDataCacheComplete = true

    init(
        container: CKContainer? = nil,
        database: (any SyncDatabase)? = nil,
        directoryURL: URL = AppStorage.directoryURL(),
        isEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled() }
    ) {
        self.container = container
        suppliedDatabase = database
        self.directoryURL = directoryURL
        self.isEnabled = isEnabled
    }

    // MARK: - 同步入口

    func pruneLocalCaches(now: Date = Date()) {
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        if lastActivityDataCacheRetentionCutoff != cutoff {
            do {
                try activityDataStore.prune(now: now)
                lastActivityDataCacheRetentionCutoff = cutoff
            } catch {
                AppLog.sync.error("活动同步缓存过期清理失败")
            }
        }
        if lastTokenUsageCacheRetentionCutoff != cutoff {
            do {
                try TokenUsageSync.pruneLocalCache(in: directoryURL, now: now)
                lastTokenUsageCacheRetentionCutoff = cutoff
            } catch {
                AppLog.sync.error("Token 同步缓存过期清理失败")
            }
        }
    }

    func snapshotFromCacheIfEnabled(localTokenUsageAggregates: [TokenUsageAggregate] = []) async -> SyncSnapshot {
        guard isEnabled() else {
            return .disabled
        }

        let state = activityDataStore.loadState()
        return await snapshot(from: state, localTokenUsageAggregates: localTokenUsageAggregates)
    }

    func hasPendingActivityDataUpdates(local: [ActivityDataAggregate]) -> Bool {
        guard isEnabled() else { return false }
        guard let cache = try? activityDataStore.load(), let deviceID = cache.state.deviceID else { return !local.isEmpty }
        return local.contains { aggregate in
            let id = ActivityDataSyncRecord.recordName(deviceID: deviceID, date: aggregate.date)
            return cache.records[id]?.activityData != aggregate.syncedAggregate
        }
    }

    func hasPendingTokenUsageUpdates(local: [TokenUsageAggregate]) async -> Bool {
        guard isEnabled() else { return false }
        return await tokenUsageSync.hasPendingUpdates(local: local, accountScopedDeviceID: activityDataStore.loadState().deviceID)
    }

    func synchronizeIfEnabled(
        localActivityDataAggregates: [ActivityDataAggregate],
        localTokenUsageAggregates: [TokenUsageAggregate] = [],
        isTokenUsageSourceComplete: Bool = true,
        trigger: LogTrigger
    ) async -> SyncSnapshot {
        guard isEnabled(), !Task.isCancelled else {
            logSyncSkipped(trigger: trigger)
            return .disabled
        }

        AppLog.sync.notice("同步开始: trigger=\(trigger.rawValue, privacy: .public)")
        let duration = LogDuration()
        var stage = SyncStage.zone
        var didSucceed = false
        var failureMessage: String?
        Self.postSyncNotification(.syncDidStart)
        defer {
            Self.postSyncNotification(
                .syncDidFinish,
                didSucceed: didSucceed,
                failureMessage: failureMessage
            )
        }

        var state: ActivityDataSyncState
        do { state = try activityDataStore.load().state } catch {
            failureMessage = SyncFailureReason.classify(error).message
            return SyncSnapshot(activityData: [], currentDeviceID: nil, isActivityDataComplete: false)
        }

        // 显式开启同步允许恢复缺失的 zone, 同一轮最多重新执行一次
        for attempt in 0 ..< 2 {
            do {
                try SyncCancellation.check(isEnabled: isEnabled)
                failureMessage = try await synchronizeOnce(
                    localActivityDataAggregates: localActivityDataAggregates, localTokenUsageAggregates: localTokenUsageAggregates,
                    isTokenUsageSourceComplete: isTokenUsageSourceComplete,
                    state: &state, stage: &stage, trigger: trigger
                )
                didSucceed = failureMessage == nil
                break
            } catch {
                var failure = error
                if SyncRecovery.stopsOtherSync(error) {
                    invalidateAccountScopedCaches()
                }
                if SyncRecovery.isMissingZone(error, zoneID: syncZoneID), !Task.isCancelled, isEnabled() {
                    do {
                        try await resetSyncState(state: &state)
                        if attempt == 0 {
                            AppLog.sync.notice("云端 zone 已失效, 重置同步状态后重试")
                            stage = .zone
                            continue
                        }
                    } catch {
                        failure = error
                    }
                }
                if !(failure is CancellationError), !Task.isCancelled, isEnabled() {
                    let reason = SyncFailureReason.classify(failure)
                    logSyncFailed(trigger: trigger, stage: stage, elapsed: duration.elapsed, reason: reason, detail: failure.localizedDescription)
                    failureMessage = reason.message
                }
                try? activityDataStore.saveState(state)
                break
            }
        }

        guard !Task.isCancelled, isEnabled() else { return .disabled }
        let latestState = activityDataStore.loadState()
        return await snapshot(from: latestState, localTokenUsageAggregates: isTokenUsageSourceComplete ? localTokenUsageAggregates : [])
    }

    private func synchronizeOnce(
        localActivityDataAggregates: [ActivityDataAggregate], localTokenUsageAggregates: [TokenUsageAggregate], isTokenUsageSourceComplete: Bool,
        state: inout ActivityDataSyncState, stage: inout SyncStage, trigger: LogTrigger
    ) async throws -> String? {
        let duration = LogDuration()
        try await ensureSyncZoneExists(state: &state)
        stage = .device
        let deviceID = try await resolveCurrentDeviceID()
        try await resetStateIfDeviceChanged(deviceID, state: &state)

        var localByDate: [String: SyncedActivityData] = [:]
        var confirmedDates = Set<String>()
        var activityDataFailure: Error?
        do {
            stage = .upload
            localByDate = try Self.syncedAggregatesByDate(localActivityDataAggregates)
            confirmedDates = try await synchronizeActivityData(
                localByDate: localByDate, state: &state, stage: &stage
            )
        } catch {
            isActivityDataCacheComplete = false
            if SyncRecovery.stopsOtherSync(error) {
                throw error
            }
            activityDataFailure = error
            logSyncFailed(
                trigger: trigger,
                stage: stage,
                elapsed: duration.elapsed,
                reason: SyncFailureReason.classify(error),
                detail: error.localizedDescription
            )
        }
        stage = .tokenUsage
        try await tokenUsageSync.synchronize(
            local: localTokenUsageAggregates, accountScopedDeviceID: deviceID, zoneID: syncZoneID, canUpload: isTokenUsageSourceComplete
        )
        if let activityDataFailure {
            try SyncCancellation.check(isEnabled: isEnabled)
            try activityDataStore.saveState(state)
            return (activityDataFailure as? ActivityDataSyncError)?.errorDescription ?? SyncFailureReason.classify(activityDataFailure).message
        }
        stage = .prune
        let deletedCount = try await pruneCurrentDeviceRecordsIfNeeded(deviceID: deviceID, state: &state)
        try activityDataStore.saveState(state)
        // confirmed 是本地与远端已对齐的日期数, 含缓存内容相同而无需上传的日期
        // 它小于 local 就说明这一轮还有日期没落到云上
        let elapsed = duration.elapsed
        logSyncCompleted(
            trigger: trigger,
            localCount: localByDate.count,
            confirmedCount: confirmedDates.count,
            deletedCount: deletedCount,
            elapsed: elapsed
        )
        return nil
    }

    private func synchronizeActivityData(
        localByDate: [String: SyncedActivityData],
        state: inout ActivityDataSyncState, stage: inout SyncStage
    ) async throws -> Set<String> {
        stage = .fetch
        try await refreshCacheFromRemote()
        stage = .upload
        let dates = try await uploadChangedAggregates(
            localByDate: localByDate,
            state: &state
        )
        stage = .fetch
        try await refreshCacheFromRemote()
        isActivityDataCacheComplete = true
        return dates
    }

    private func logSyncSkipped(trigger: LogTrigger) {
        let details = LogFields.joined(
            "trigger=\(trigger.rawValue)",
            "reason=syncOff"
        )
        AppLog.sync.notice("同步已跳过: \(details, privacy: .public)")
    }

    private func logSyncCompleted(
        trigger: LogTrigger,
        localCount: Int,
        confirmedCount: Int,
        deletedCount: Int,
        elapsed: String
    ) {
        let details = LogFields.joined(
            "trigger=\(trigger.rawValue)",
            "local=\(localCount)",
            "confirmed=\(confirmedCount)",
            "deleted=\(deletedCount)",
            "elapsed=\(elapsed)"
        )
        AppLog.sync.notice("同步完成: \(details, privacy: .public)")
    }

    private func logSyncFailed(
        trigger: LogTrigger,
        stage: SyncStage,
        elapsed: String,
        reason: SyncFailureReason,
        detail: String
    ) {
        let details = LogFields.joined(
            "trigger=\(trigger.rawValue)",
            "stage=\(stage.rawValue)",
            "elapsed=\(elapsed)",
            "reason=\(reason.rawValue)",
            "detail=\(detail)"
        )
        AppLog.sync.error("同步失败: \(details, privacy: .public)")
    }

    private func resetStateIfDeviceChanged(
        _ deviceID: String,
        state: inout ActivityDataSyncState
    ) async throws {
        guard state.deviceID != deviceID else {
            return
        }

        try await resetSyncState(state: &state)
        state.deviceID = deviceID
        try activityDataStore.saveState(state)
    }

    private func resetSyncState(state: inout ActivityDataSyncState) async throws {
        try SyncCancellation.check(isEnabled: isEnabled)
        // 先持久化未绑定状态, 中途失败或退出后仍会重新清理, 不把旧缓存当作已恢复
        state = ActivityDataSyncState()
        try activityDataStore.reset(state: state)
        try await tokenUsageSync.resetCache()
        try SyncCancellation.check(isEnabled: isEnabled)
    }

    private static func syncedAggregatesByDate(
        _ aggregates: [ActivityDataAggregate]
    ) throws -> [String: SyncedActivityData] {
        try aggregates.reduce(into: [String: SyncedActivityData]()) { result, aggregate in
            guard HistoryStorage.isValidDateKey(aggregate.date) else { throw ActivityDataSyncError.invalidRecordIdentity }
            result[aggregate.date] = aggregate.syncedAggregate
        }
    }

    private func snapshot(from state: ActivityDataSyncState, localTokenUsageAggregates: [TokenUsageAggregate]) async -> SyncSnapshot {
        var result = SyncSnapshot(activityData: [], currentDeviceID: state.deviceID)
        do {
            let cache = try activityDataStore.load()
            result = SyncSnapshot(activityData: Self.filteredRetained(records: cache.sortedRecords), currentDeviceID: cache.state.deviceID)
        } catch {
            result.isActivityDataComplete = false
        }
        result.tokenUsageByDate = try? await tokenUsageSync.snapshot(local: localTokenUsageAggregates, accountScopedDeviceID: state.deviceID)
        result.isActivityDataComplete = result.isActivityDataComplete && isActivityDataCacheComplete
        return result
    }
}

private extension SyncService {
    struct UploadBatchResult {
        var confirmed: [ActivityDataSyncRecord] = []
        var didUpload = false
        var failures = SyncFailures()
    }

    enum Metrics {
        static let saltByteCount = 32
        static let recordFetchLimit = 200
        static let queryFetchLimit = 200
        static let uploadBatchSize = 25
        static let uploadTimeBudget: TimeInterval = 20
    }

    typealias RecordTypes = ActivityDataRecordCodec.RecordTypes
    typealias FieldKeys = ActivityDataRecordCodec.FieldKeys

    static let accountSaltRecordName = "accountSalt"

    var syncZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    var accountSaltRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.accountSaltRecordName, zoneID: syncZoneID)
    }

    private var activityDataStore: ActivityDataSyncStore {
        ActivityDataSyncStore(directoryURL: directoryURL)
    }

    // MARK: - 上传

    func uploadChangedAggregates(
        localByDate: [String: SyncedActivityData],
        state: inout ActivityDataSyncState
    ) async throws -> Set<String> {
        guard let deviceID = state.deviceID else {
            return []
        }

        let cache = try activityDataStore.load()
        var confirmedDates = Set<String>()
        for (date, aggregate) in localByDate {
            let id = ActivityDataSyncRecord.recordName(deviceID: deviceID, date: date)
            if cache.records[id]?.activityData == aggregate {
                confirmedDates.insert(date)
            }
        }
        let pendingUploads = localByDate.values.filter { !confirmedDates.contains($0.date) }.sorted { $0.date < $1.date }
        guard !pendingUploads.isEmpty else {
            return confirmedDates
        }

        let deadline = Date().addingTimeInterval(Metrics.uploadTimeBudget)
        var failures = SyncFailures()

        for batchStart in stride(from: 0, to: pendingUploads.count, by: Metrics.uploadBatchSize) {
            try SyncCancellation.check(isEnabled: isEnabled)
            guard Date() < deadline else {
                break
            }

            let batchEnd = min(batchStart + Metrics.uploadBatchSize, pendingUploads.count)
            let batch = Array(pendingUploads[batchStart ..< batchEnd])
            let result = try await processUploadBatch(batch, deviceID: deviceID)
            if !result.confirmed.isEmpty {
                let lastUploadAt = result.didUpload ? Date() : nil
                try activityDataStore.saveConfirmedRecords(result.confirmed, lastUploadAt: lastUploadAt)
                if let lastUploadAt {
                    state.lastUploadAt = lastUploadAt
                }
            }
            confirmedDates.formUnion(result.confirmed.map(\.date))
            try result.failures.checkStopping()
            if let error = result.failures.first {
                failures.record(error)
            }
        }
        try failures.check()

        return confirmedDates
    }

    func deleteRecords(_ recordIDs: [CKRecord.ID]) async throws {
        for batchStart in stride(from: 0, to: recordIDs.count, by: Metrics.uploadBatchSize) {
            let batchEnd = min(batchStart + Metrics.uploadBatchSize, recordIDs.count)
            let batch = Array(recordIDs[batchStart ..< batchEnd])
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.modifyRecords(
                saving: [],
                deleting: batch,
                savePolicy: .ifServerRecordUnchanged,
                atomically: false
            )

            for recordID in batch {
                switch result.deleteResults[recordID] {
                case .success:
                    continue
                case let .failure(error as CKError) where error.code == .unknownItem:
                    continue
                case let .failure(error):
                    throw error
                case nil:
                    throw SyncError.missingRecordResult
                }
            }
        }
    }

    func processUploadBatch(
        _ aggregates: [SyncedActivityData],
        deviceID: String
    ) async throws -> UploadBatchResult {
        let recordIDs = aggregates.map { recordID(deviceID: deviceID, date: $0.date) }
        try SyncCancellation.check(isEnabled: isEnabled)
        let existingRecords = try await database.records(for: recordIDs, desiredKeys: nil)
        var outcome = UploadBatchResult()
        var recordsToSave: [CKRecord] = []

        for (aggregate, id) in zip(aggregates, recordIDs) {
            do {
                let existing = try Self.fetchedRecord(from: existingRecords[id])
                if let existing {
                    guard let remote = try ActivityDataRecordCodec.remoteDailyRecord(from: existing) else {
                        throw ActivityDataSyncError.invalidRecordIdentity
                    }
                    if remote.activityData == aggregate {
                        outcome.confirmed.append(remote)
                        continue
                    }
                }
                let record = existing ?? CKRecord(recordType: RecordTypes.activityData, recordID: id)
                try ActivityDataRecordCodec.apply(aggregate, deviceID: deviceID, to: record)
                recordsToSave.append(record)
            } catch {
                outcome.failures.record(error)
                if outcome.failures.stopping != nil {
                    return outcome
                }
            }
        }

        guard !recordsToSave.isEmpty else { return outcome }
        try SyncCancellation.check(isEnabled: isEnabled)
        let result = try await database.modifyRecords(
            saving: recordsToSave,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )
        for record in recordsToSave {
            do {
                guard let saved = result.saveResults[record.recordID] else {
                    throw SyncRecovery.Failure.missingRecordResult
                }
                guard let confirmed = try ActivityDataRecordCodec.remoteDailyRecord(from: saved.get()) else {
                    throw ActivityDataSyncError.invalidRecordIdentity
                }
                outcome.confirmed.append(confirmed)
                outcome.didUpload = true
            } catch {
                outcome.failures.record(error)
            }
        }
        return outcome
    }

    // MARK: - 拉取与缓存

    func refreshCacheFromRemote() async throws {
        do {
            let cache = try activityDataStore.load()
            guard let token = try cache.cursor.map(SyncRecovery.decodeCursor) else {
                try await rebuildCacheFromRemote()
                return
            }
            try await applyZoneChangesToCache(
                since: token,
                cachedRecords: cache.records
            )
        } catch where SyncRecovery.isInvalidCursor(error) {
            try SyncCancellation.check(isEnabled: isEnabled)
            // 增量拉取退化成全量重建, 代价高得多, 反复出现说明游标或缓存有问题
            let details = LogFields.joined(
                "detail=\(error.localizedDescription)",
                "action=fullRebuild"
            )
            AppLog.sync.notice("增量拉取已降级: \(details, privacy: .public)")
            try await rebuildCacheFromRemote()
        }
    }

    func applyZoneChangesToCache(
        since initialToken: CKServerChangeToken?,
        cachedRecords: [String: ActivityDataSyncRecord]
    ) async throws {
        var cacheByID = cachedRecords
        var token: CKServerChangeToken? = initialToken
        var moreComing = true

        while moreComing {
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.fetchChanges(
                inZoneWith: syncZoneID,
                since: token,
                resultsLimit: Metrics.recordFetchLimit
            )

            try mergeChangedRecords(
                result.records.values,
                into: &cacheByID
            )
            removeDeletedRecords(result.deletions, from: &cacheByID)

            token = result.token
            moreComing = result.moreComing
        }

        try activityDataStore.saveFetchedRecords(cacheByID, cursor: token)
    }

    func rebuildCacheFromRemote() async throws {
        try await applyZoneChangesToCache(since: nil, cachedRecords: [:])
    }

    func fetchCurrentDeviceRecordIDsToPrune(
        deviceID: String,
        cutoffKey: String
    ) async throws -> [CKRecord.ID] {
        let query = CKQuery(
            recordType: RecordTypes.activityData,
            predicate: NSPredicate(
                format: "%K == %@",
                FieldKeys.deviceID,
                deviceID
            )
        )

        let currentDeviceMatches = try await fetchAllRecordMatches(
            matching: query,
            desiredKeys: nil
        )
        return try currentDeviceMatches.compactMap { recordID, result in
            let record = try result.get()
            guard let decoded = try ActivityDataRecordCodec.remoteDailyRecord(from: record) else {
                throw ActivityDataSyncError.invalidRecordIdentity
            }
            return decoded.date < cutoffKey ? recordID : nil
        }
    }

    func fetchAllRecordMatches(
        matching query: CKQuery,
        desiredKeys: [String]? = nil
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        try SyncCancellation.check(isEnabled: isEnabled)
        let firstPage = try await database.records(
            matching: query,
            inZoneWith: syncZoneID,
            desiredKeys: desiredKeys,
            resultsLimit: Metrics.queryFetchLimit
        )
        var matches = firstPage.matchResults
        var cursor = firstPage.queryCursor

        while let currentCursor = cursor {
            try SyncCancellation.check(isEnabled: isEnabled)
            let page = try await database.records(
                continuingMatchFrom: currentCursor,
                desiredKeys: desiredKeys,
                resultsLimit: Metrics.queryFetchLimit
            )
            matches.append(contentsOf: page.matchResults)
            cursor = page.queryCursor
        }

        return matches
    }

    func mergeChangedRecords(
        _ modificationResults: Dictionary<CKRecord.ID, Result<CKRecord, Error>>.Values,
        into cacheByID: inout [String: ActivityDataSyncRecord]
    ) throws {
        for modificationResult in modificationResults {
            let modification = try modificationResult.get()
            guard let record = try ActivityDataRecordCodec.remoteDailyRecord(from: modification) else {
                continue
            }

            cacheByID[record.id] = record
        }
    }

    func removeDeletedRecords(
        _ deletions: [(id: CKRecord.ID, type: String)],
        from cacheByID: inout [String: ActivityDataSyncRecord]
    ) {
        for deletion in deletions where deletion.type == RecordTypes.activityData {
            guard let cacheID = cacheID(fromRecordName: deletion.id.recordName) else {
                continue
            }
            cacheByID.removeValue(forKey: cacheID)
        }
    }

    @discardableResult
    func pruneCurrentDeviceRecordsIfNeeded(
        deviceID: String,
        state: inout ActivityDataSyncState
    ) async throws -> Int {
        let today = HistoryStorage.dateKey(for: Date())
        guard state.lastPrunedDate != today else {
            return 0
        }

        let cutoffKey = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        let recordIDs = try await Set(
            fetchCurrentDeviceRecordIDsToPrune(
                deviceID: deviceID,
                cutoffKey: cutoffKey
            )
        )

        if !recordIDs.isEmpty {
            try await deleteRecords(
                recordIDs.sorted { $0.recordName < $1.recordName }
            )
        }

        state.lastPrunedDate = today
        return recordIDs.count
    }

    // MARK: - 账号与设备标识

    func resolveCurrentDeviceID() async throws -> String {
        let salt = try await accountSalt()
        let uuid = try Self.ioPlatformUUID()
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(uuid.utf8),
            using: SymmetricKey(data: salt)
        )
        return Self.hexString(Data(mac))
    }

    /// 每轮读取最新 salt, 识别其他设备重建同名 zone 后的设备身份变化
    func accountSalt() async throws -> Data {
        let recordID = accountSaltRecordID
        if let salt = try await fetchAccountSalt(recordID) {
            return salt
        }
        return try await createAccountSalt(recordID)
    }

    func fetchAccountSalt(_ recordID: CKRecord.ID) async throws -> Data? {
        try SyncCancellation.check(isEnabled: isEnabled)
        let result = try await database.records(for: [recordID], desiredKeys: nil)
        guard let record = try Self.fetchedRecord(from: result[recordID]) else {
            return nil
        }
        try StorageVersion.require(
            ActivityDataRecordCodec.optionalIntValue(record[FieldKeys.schemaVersion]) ?? -1,
            current: ActivityDataRecordCodec.metadataSchemaVersion, name: "CloudMetadata"
        )
        guard let salt = record[FieldKeys.salt] as? Data,
              salt.count == Metrics.saltByteCount else {
            throw SyncError.missingAccountSalt
        }
        return salt
    }

    func createAccountSalt(_ recordID: CKRecord.ID) async throws -> Data {
        let salt = try Self.randomSalt()
        let record = CKRecord(recordType: RecordTypes.metadata, recordID: recordID)
        record[FieldKeys.salt] = salt as CKRecordValue
        record[FieldKeys.schemaVersion] = ActivityDataRecordCodec.metadataSchemaVersion as CKRecordValue

        do {
            try SyncCancellation.check(isEnabled: isEnabled)
            let saveResult = try await database.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            switch saveResult.saveResults[recordID] {
            case .success:
                return salt
            case let .failure(error):
                throw error
            case nil:
                throw SyncError.missingRecordResult
            }
        } catch let error as CKError where error.code == .serverRecordChanged || error.code == .constraintViolation {
            if let salt = try await fetchAccountSalt(recordID) {
                return salt
            }
        }

        throw SyncError.missingAccountSalt
    }

    // MARK: - 记录与 zone 维护

    func ensureSyncZoneExists(state: inout ActivityDataSyncState) async throws {
        guard !isSyncZoneConfirmed else {
            return
        }

        if try await syncZoneExists() == false {
            invalidateAccountScopedCaches()
            try await resetSyncState(state: &state)
            let zone = CKRecordZone(zoneID: syncZoneID)
            try SyncCancellation.check(isEnabled: isEnabled)
            let result = try await database.modifyRecordZones(saving: [zone], deleting: [])

            switch result.saveResults[syncZoneID] {
            case .success:
                break
            case let .failure(error):
                throw error
            case nil:
                throw SyncError.missingRecordResult
            }
        }

        try SyncCancellation.check(isEnabled: isEnabled)
        isSyncZoneConfirmed = true
    }

    func invalidateAccountScopedCaches() {
        isSyncZoneConfirmed = false
    }

    func syncZoneExists() async throws -> Bool {
        do {
            try SyncCancellation.check(isEnabled: isEnabled)
            _ = try await database.recordZone(for: syncZoneID)
            return true
        } catch where SyncRecovery.isMissingZone(error, zoneID: syncZoneID, queryingZone: true) {
            return false
        }
    }

    func recordID(deviceID: String, date: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: ActivityDataSyncRecord.recordName(deviceID: deviceID, date: date),
            zoneID: syncZoneID
        )
    }

    func cacheID(fromRecordName recordName: String) -> String? {
        recordName.isEmpty ? nil : recordName
    }

    nonisolated static func postSyncNotification(
        _ name: Notification.Name,
        didSucceed: Bool? = nil,
        failureMessage: String? = nil
    ) {
        Task { @MainActor in
            var userInfo = [String: Any]()
            if let didSucceed {
                userInfo[SyncNotificationKey.didSucceed] = didSucceed
            }
            if let failureMessage {
                userInfo[SyncNotificationKey.failureMessage] = failureMessage
            }

            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: userInfo.isEmpty ? nil : userInfo
            )
        }
    }
}

extension SyncService {
    /// 设置页读取最近上传时间, 与内部 loadState 使用同一 schemaVersion 校验口径
    nonisolated static func loadLastUploadAt() -> Date? {
        ActivityDataSyncStore(directoryURL: AppStorage.directoryURL()).loadState().lastUploadAt
    }
}

private extension SyncService {
    static func fetchedRecord(
        from result: Result<CKRecord, Error>?
    ) throws -> CKRecord? {
        switch result {
        case let .success(record):
            return record
        case let .failure(error as CKError) where error.code == .unknownItem:
            return nil
        case let .failure(error):
            throw error
        case nil:
            throw SyncError.missingRecordResult
        }
    }

    static func filteredRetained(
        records: [ActivityDataSyncRecord]
    ) -> [ActivityDataSyncRecord] {
        let cutoffKey = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        return records.filter { $0.date >= cutoffKey }
    }

    static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Metrics.saltByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SyncError.randomSaltFailed
        }
        return Data(bytes)
    }

    static func ioPlatformUUID() throws -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else {
            throw SyncError.missingIOPlatformUUID
        }
        defer {
            IOObjectRelease(service)
        }

        guard let value = IORegistryEntryCreateCFProperty(
                  service,
                  "IOPlatformUUID" as CFString,
                  kCFAllocatorDefault,
                  0
              )?.takeRetainedValue() as? String,
              !value.isEmpty else {
            throw SyncError.missingIOPlatformUUID
        }

        return value
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// activityData 包含所有设备的日聚合, 不含 threadIDs 和 turnIds
/// currentDeviceID 用于展示时替换本机云端副本, 避免重复计数
nonisolated struct SyncSnapshot: Equatable {
    let activityData: [ActivityDataSyncRecord]
    let currentDeviceID: String?
    var tokenUsageByDate: [String: TokenUsage]?
    var isActivityDataComplete = true

    static let disabled = SyncSnapshot(activityData: [], currentDeviceID: nil)
}

private nonisolated enum SyncError: Error {
    case missingAccountSalt
    case missingIOPlatformUUID
    case missingRecordResult
    case randomSaltFailed
}
