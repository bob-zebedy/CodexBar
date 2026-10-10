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
    case tokens
    case prune
}

/// 将本机 daily.jsonl 中不含 threadIDs 和 turnIds 的聚合行同步到 CloudKit private database
actor SyncService {
    private let container: CKContainer?
    private let suppliedDatabase: (any SyncDatabase)?
    private lazy var database: any SyncDatabase = suppliedDatabase ?? (container ?? SyncCloudKit.makeContainer()).privateCloudDatabase
    private let directoryURL: URL
    private let activityEventsDirectoryURL: URL
    private let isEnabled: @Sendable () -> Bool
    private lazy var tokenSync = TokenSync(
        database: database, directoryURL: directoryURL.appendingPathComponent("Tokens"), isEnabled: isEnabled
    )

    // zone 存在性跨轮缓存, 共享故障后重新确认
    // salt 只在单轮内复用, 每轮确认同名 zone 是否已经被其他设备重建
    private var isSyncZoneConfirmed = false
    private var cachedAccountSalt: Data?
    private var lastActivityCacheRetentionCutoff: Date?
    private var lastTokenCacheRetentionCutoff: Date?
    private var isActivityCacheComplete = true

    init(
        container: CKContainer? = nil,
        database: (any SyncDatabase)? = nil,
        directoryURL: URL = HistoryStorage.syncDirectoryURL(),
        activityEventsDirectoryURL: URL? = nil,
        isEnabled: @escaping @Sendable () -> Bool = { SyncSettings.isEnabled() }
    ) {
        self.container = container
        suppliedDatabase = database
        self.directoryURL = directoryURL
        self.activityEventsDirectoryURL = activityEventsDirectoryURL ?? HistoryStorage.eventsDirectoryURL(in: directoryURL.deletingLastPathComponent())
        self.isEnabled = isEnabled
    }

    // MARK: - 同步入口

    func pruneLocalCaches(now: Date = Date()) {
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        if lastActivityCacheRetentionCutoff != cutoff {
            do {
                try activityStore.prune(now: now)
                lastActivityCacheRetentionCutoff = cutoff
            } catch {
                AppLog.sync.error("活动同步缓存过期清理失败")
            }
        }
        if lastTokenCacheRetentionCutoff != cutoff {
            do {
                try TokenSync.pruneLocalCache(in: directoryURL.appendingPathComponent("Tokens"), now: now)
                lastTokenCacheRetentionCutoff = cutoff
            } catch {
                AppLog.sync.error("Token 同步缓存过期清理失败")
            }
        }
    }

    func snapshotFromCacheIfEnabled(localTokenTurns: [TokenTurn] = []) async -> SyncSnapshot {
        guard isEnabled() else {
            return .disabled
        }

        let state = activityStore.loadState()
        return await snapshot(from: state, localTokenTurns: localTokenTurns)
    }

    func tokenRecoveryBaselineIfEnabled() async -> TokenHistoryBaseline? {
        guard isEnabled() else { return nil }
        return await tokenSync.recoveryBaseline(accountScopedDeviceID: activityStore.loadState().deviceID)
    }

    func hasPendingActivityUpdates(local: [ActivityAggregate]) -> Bool {
        guard isEnabled() else { return false }
        guard let state = try? activityStore.load().state else { return !local.isEmpty }
        return local.contains { aggregate in
            (try? hash(for: aggregate.syncedAggregate)) != state.hashByDate[aggregate.date]
        }
    }

    func hasPendingTokenUpdates(local: [TokenTurn]) async -> Bool {
        guard isEnabled() else { return false }
        return await tokenSync.hasPendingUpdates(local: local, accountScopedDeviceID: activityStore.loadState().deviceID)
    }

    func synchronizeIfEnabled(
        localAggregates: [ActivityAggregate],
        localTokenTurns: [TokenTurn] = [],
        recoveredTokenIDs: Set<String> = [],
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

        var state: SyncState
        do { state = try activityStore.load().state } catch {
            failureMessage = SyncFailureReason.classify(error).message
            return SyncSnapshot(records: [], currentDeviceID: nil, isActivityComplete: false)
        }

        // 显式开启同步允许恢复缺失的 zone, 同一轮最多重新执行一次
        cachedAccountSalt = nil
        for attempt in 0 ..< 2 {
            do {
                try SyncCancellation.check(isEnabled: isEnabled)
                failureMessage = try await synchronizeOnce(
                    localAggregates: localAggregates, localTokenTurns: localTokenTurns, recoveredTokenIDs: recoveredTokenIDs,
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
                try? activityStore.saveState(state)
                break
            }
        }

        guard !Task.isCancelled, isEnabled() else { return .disabled }
        let latestState = activityStore.loadState()
        return await snapshot(from: latestState, localTokenTurns: localTokenTurns)
    }

    private func synchronizeOnce(
        localAggregates: [ActivityAggregate], localTokenTurns: [TokenTurn], recoveredTokenIDs: Set<String>,
        state: inout SyncState, stage: inout SyncStage, trigger: LogTrigger
    ) async throws -> String? {
        let duration = LogDuration()
        try await ensureSyncZoneExists(state: &state)
        stage = .device
        let deviceID = try await resolveCurrentDeviceID()
        try await resetStateIfDeviceChanged(deviceID, state: &state)

        var localByDate: [String: SyncedActivity] = [:]
        var confirmedDates = Set<String>()
        var activityFailure: Error?
        do {
            stage = .upload
            localByDate = try Self.syncedAggregatesByDate(localAggregates)
            confirmedDates = try await synchronizeActivity(
                localByDate: localByDate, deviceID: deviceID, state: &state, stage: &stage
            )
        } catch {
            isActivityCacheComplete = false
            if SyncRecovery.stopsOtherSync(error) {
                throw error
            }
            activityFailure = error
            logSyncFailed(
                trigger: trigger,
                stage: stage,
                elapsed: duration.elapsed,
                reason: SyncFailureReason.classify(error),
                detail: error.localizedDescription
            )
        }
        stage = .tokens
        try await tokenSync.synchronize(
            local: localTokenTurns, recoveredIDs: recoveredTokenIDs, accountScopedDeviceID: deviceID, salt: accountSalt(), zoneID: syncZoneID
        )
        if let activityFailure {
            try SyncCancellation.check(isEnabled: isEnabled)
            try activityStore.saveState(state)
            return (activityFailure as? ActivitySyncError)?.errorDescription ?? SyncFailureReason.classify(activityFailure).message
        }
        stage = .prune
        let deletedCount = try await pruneCurrentDeviceRecordsIfNeeded(deviceID: deviceID, state: &state)
        try activityStore.saveState(state)
        // confirmed 是本地与远端已对齐的日期数, 含哈希未变而无需上传的那些
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

    private func synchronizeActivity(
        localByDate: [String: SyncedActivity], deviceID _: String,
        state: inout SyncState, stage: inout SyncStage
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
        isActivityCacheComplete = true
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
        state: inout SyncState
    ) async throws {
        guard state.deviceID != deviceID else {
            return
        }

        try await resetSyncState(state: &state)
        state.deviceID = deviceID
        try activityStore.saveState(state)
    }

    private func resetSyncState(state: inout SyncState) async throws {
        try SyncCancellation.check(isEnabled: isEnabled)
        // 先持久化未绑定状态, 中途失败或退出后仍会重新清理, 不把旧缓存当作已恢复
        state = SyncState()
        try activityStore.reset(state: state)
        try await tokenSync.resetCache()
        try SyncCancellation.check(isEnabled: isEnabled)
    }

    private static func syncedAggregatesByDate(
        _ aggregates: [ActivityAggregate]
    ) throws -> [String: SyncedActivity] {
        try aggregates.reduce(into: [String: SyncedActivity]()) { result, aggregate in
            _ = try aggregate.syncedAggregate.requiredGenerationID()
            result[aggregate.date] = aggregate.syncedAggregate
        }
    }

    private func snapshot(from state: SyncState, localTokenTurns: [TokenTurn]) async -> SyncSnapshot {
        var result = SyncSnapshot(records: [], currentDeviceID: state.deviceID)
        do {
            let cache = try activityStore.load()
            result = SyncSnapshot(records: Self.filteredRetained(records: cache.records), currentDeviceID: cache.state.deviceID)
        } catch {
            result.isActivityComplete = false
        }
        result.tokenUsageByDate = try? await tokenSync.snapshot(local: localTokenTurns, accountScopedDeviceID: state.deviceID)
        result.isActivityComplete = result.isActivityComplete && isActivityCacheComplete
        return result
    }
}

private extension SyncService {
    struct PendingUpload {
        let date: String
        let aggregate: SyncedActivity
        let hash: String
    }

    struct PendingRecord {
        let upload: PendingUpload
        let recordID: CKRecord.ID
    }

    struct RecordToSave {
        let upload: PendingUpload
        let record: CKRecord
    }

    struct UploadBatchResult {
        var confirmed: [ConfirmedHash] = []
        var failures = SyncFailures()
    }

    struct ConfirmedHash {
        let date: String
        let hash: String
        let didUpload: Bool
    }

    enum Metrics {
        static let syncVersion = ActivityRecordCodec.version
        static let saltByteCount = 32
        static let recordFetchLimit = 200
        static let queryFetchLimit = 200
        static let uploadBatchSize = 25
        static let uploadTimeBudget: TimeInterval = 20
    }

    typealias RecordTypes = ActivityRecordCodec.RecordTypes
    typealias FieldKeys = ActivityRecordCodec.FieldKeys

    static let accountSaltRecordName = "accountSalt"

    var syncZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    var accountSaltRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.accountSaltRecordName, zoneID: syncZoneID)
    }

    private var activityStore: ActivitySyncStore {
        ActivitySyncStore(directoryURL: directoryURL)
    }

    // MARK: - 上传

    func uploadChangedAggregates(
        localByDate: [String: SyncedActivity],
        state: inout SyncState
    ) async throws -> Set<String> {
        guard let deviceID = state.deviceID else {
            return []
        }

        // 每个日期的 hash 是一次 JSON 编码加 SHA256, 本轮只算一次
        // 既用来判定"和上次一样不必上传", 也直接填进待上传项
        let localHashByDate = try localByDate.mapValues { try hash(for: $0) }

        var confirmedDates = Set<String>()
        for (date, hash) in localHashByDate where state.hashByDate[date] == hash {
            confirmedDates.insert(date)
        }

        let pendingUploads = makePendingUploads(
            localByDate: localByDate,
            localHashByDate: localHashByDate,
            state: state
        )
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
            try applyConfirmedHashes(result.confirmed, to: &state)
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

    func applyConfirmedHashes(
        _ confirmedBatch: [ConfirmedHash],
        to state: inout SyncState
    ) throws {
        guard !confirmedBatch.isEmpty else {
            return
        }

        for confirmation in confirmedBatch {
            state.hashByDate[confirmation.date] = confirmation.hash
        }

        if confirmedBatch.contains(where: \.didUpload) {
            state.lastUploadAt = Date()
        }
        try activityStore.saveState(state)
    }

    /// hash 由调用方一次算好传进来, 这里只做筛选
    func makePendingUploads(
        localByDate: [String: SyncedActivity],
        localHashByDate: [String: String],
        state: SyncState
    ) -> [PendingUpload] {
        localByDate.compactMap { date, local in
            guard let hash = localHashByDate[date],
                  state.hashByDate[date] != hash else {
                return nil
            }

            return PendingUpload(
                date: date,
                aggregate: local,
                hash: hash
            )
        }
        .sorted { $0.date < $1.date }
    }

    /// 单条待上传记录落到哪个 CKRecord 上, 或者本轮不需要上传
    private enum UploadTarget {
        case skip
        case save(CKRecord)
    }

    /// 只有可验证的同源日志前缀才能覆盖, 算法改变后计数减少也允许提交
    private func resolveUploadTarget(
        _ pendingRecord: PendingRecord,
        existingRecords: [CKRecord.ID: Result<CKRecord, any Error>]
    ) throws -> UploadTarget {
        guard let candidateCheckpoint = pendingRecord.upload.aggregate.sourceCheckpoint else {
            throw StorageCompatibilityError.incompleteSource
        }
        let candidate = pendingRecord.upload.aggregate
        let journal = HistoryStorage.eventLogURL(
            for: candidate.date,
            in: activityEventsDirectoryURL
        )
        let header = try AppServerEventJournal.header(at: journal)
        guard header.date == candidate.date, header.generationID == candidate.generationID,
              try candidateCheckpoint.matchesSource(ActivitySourceCheckpoint.read(at: journal, byteCount: candidateCheckpoint.byteCount)) else {
            throw StorageCompatibilityError.sourceConflict
        }
        let existing = try Self.fetchedRecord(from: existingRecords[pendingRecord.recordID])
        if let existing {
            guard let remote = try ActivityRecordCodec.remoteDailyRecord(from: existing),
                  remote.daily.generationID == candidate.generationID,
                  let checkpoint = remote.daily.sourceCheckpoint else {
                throw ActivitySyncError.invalidRecordIdentity
            }
            if remote.daily.aggregationVersion > candidate.aggregationVersion || checkpoint.byteCount > candidateCheckpoint.byteCount {
                return .skip
            }
            guard try checkpoint.matchesSource(ActivitySourceCheckpoint.read(at: journal, byteCount: checkpoint.byteCount)) else {
                throw StorageCompatibilityError.sourceConflict
            }
            return .save(existing)
        }
        return .save(CKRecord(recordType: RecordTypes.activity, recordID: pendingRecord.recordID))
    }

    func processUploadBatch(
        _ pendingUploads: [PendingUpload],
        deviceID: String
    ) async throws -> UploadBatchResult {
        let pendingRecords = try pendingUploads.map { upload in
            try PendingRecord(
                upload: upload,
                recordID: recordID(deviceID: deviceID, date: upload.date, generation: upload.aggregate.requiredGenerationID())
            )
        }
        let recordIDs = pendingRecords.map(\.recordID)
        try SyncCancellation.check(isEnabled: isEnabled)
        let existingRecords = try await database.records(for: recordIDs, desiredKeys: nil)
        var outcome = UploadBatchResult()
        var recordsToSave = [RecordToSave]()

        for pendingRecord in pendingRecords {
            do {
                switch try resolveUploadTarget(
                    pendingRecord,
                    existingRecords: existingRecords
                ) {
                case .skip:
                    outcome.confirmed.append(
                        ConfirmedHash(
                            date: pendingRecord.upload.date,
                            hash: pendingRecord.upload.hash,
                            didUpload: false
                        )
                    )
                case let .save(record):
                    ActivityRecordCodec.apply(pendingRecord.upload.aggregate, deviceID: deviceID, to: record)
                    recordsToSave.append(
                        RecordToSave(upload: pendingRecord.upload, record: record)
                    )
                }
            } catch {
                outcome.failures.record(error)
                if outcome.failures.stopping != nil {
                    return outcome
                }
            }
        }

        guard !recordsToSave.isEmpty else {
            return outcome
        }

        let records = recordsToSave.map(\.record)

        try SyncCancellation.check(isEnabled: isEnabled)
        let result = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .ifServerRecordUnchanged,
            atomically: false
        )

        for pendingRecord in recordsToSave {
            switch result.saveResults[pendingRecord.record.recordID] {
            case .success:
                outcome.confirmed.append(
                    ConfirmedHash(
                        date: pendingRecord.upload.date,
                        hash: pendingRecord.upload.hash,
                        didUpload: true
                    )
                )
            case let .failure(error):
                outcome.failures.record(error)
            case nil:
                outcome.failures.record(SyncRecovery.Failure.missingRecordResult)
            }
        }

        return outcome
    }

    // MARK: - 拉取与缓存

    func refreshCacheFromRemote() async throws {
        do {
            let cache = try activityStore.load()
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
        cachedRecords: [ActivitySyncRecord]
    ) async throws {
        var cacheByID = Self.recordsByID(records: cachedRecords)
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

        try activityStore.saveFetchedRecords(
            Self.filteredRetained(records: Array(cacheByID.values)), cursor: token
        )
    }

    func rebuildCacheFromRemote() async throws {
        try await applyZoneChangesToCache(since: nil, cachedRecords: [])
    }

    func fetchCurrentDeviceRecordIDsToPrune(
        deviceID: String,
        cutoffKey: String
    ) async throws -> [CKRecord.ID] {
        let query = CKQuery(
            recordType: RecordTypes.activity,
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
            guard let decoded = try ActivityRecordCodec.remoteDailyRecord(from: record) else {
                throw ActivitySyncError.invalidRecordIdentity
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
        into cacheByID: inout [String: ActivitySyncRecord]
    ) throws {
        for modificationResult in modificationResults {
            let modification = try modificationResult.get()
            guard let record = try ActivityRecordCodec.remoteDailyRecord(from: modification) else {
                continue
            }

            cacheByID[record.id] = record
        }
    }

    func removeDeletedRecords(
        _ deletions: [(id: CKRecord.ID, type: String)],
        from cacheByID: inout [String: ActivitySyncRecord]
    ) {
        for deletion in deletions where deletion.type == RecordTypes.activity {
            guard let cacheID = cacheID(fromRecordName: deletion.id.recordName) else {
                continue
            }
            cacheByID.removeValue(forKey: cacheID)
        }
    }

    @discardableResult
    func pruneCurrentDeviceRecordsIfNeeded(
        deviceID: String,
        state: inout SyncState
    ) async throws -> Int {
        let today = HistoryStorage.dateKey(for: Date())
        guard state.lastPrunedDate != today else {
            return 0
        }

        let cutoffKey = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        let expiredDates = Set(state.hashByDate.keys.filter { $0 < cutoffKey })
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

        for date in expiredDates {
            state.hashByDate.removeValue(forKey: date)
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

    func accountSalt() async throws -> Data {
        if let cachedAccountSalt {
            return cachedAccountSalt
        }

        let recordID = accountSaltRecordID
        let salt: Data = if let fetched = try await fetchAccountSalt(recordID) {
            fetched
        } else {
            try await createAccountSalt(recordID)
        }

        cachedAccountSalt = salt
        return salt
    }

    func fetchAccountSalt(_ recordID: CKRecord.ID) async throws -> Data? {
        try SyncCancellation.check(isEnabled: isEnabled)
        let result = try await database.records(for: [recordID], desiredKeys: nil)
        guard let record = try Self.fetchedRecord(from: result[recordID]) else {
            return nil
        }
        try StorageVersion.require(ActivityRecordCodec.optionalIntValue(record[FieldKeys.version]) ?? -1, current: ActivityRecordCodec.metadataVersion, name: "CloudMetadata")
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
        record[FieldKeys.version] = ActivityRecordCodec.metadataVersion as CKRecordValue

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

    func ensureSyncZoneExists(state: inout SyncState) async throws {
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
        cachedAccountSalt = nil
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

    func recordID(deviceID: String, date: String, generation: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: ActivitySyncRecord.recordName(deviceID: deviceID, date: date, generation: generation),
            zoneID: syncZoneID
        )
    }

    func cacheID(fromRecordName recordName: String) -> String? {
        recordName.isEmpty ? nil : recordName
    }

    func hash(for aggregate: SyncedActivity) throws -> String {
        let digest = try SHA256.hash(data: aggregate.jsonLineData())
        return Self.hexString(Data(digest))
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
    /// 设置页读取最近上传时间, 与内部 loadState 使用同一 version 校验口径
    nonisolated static func loadLastUploadAt() -> Date? {
        ActivitySyncStore(directoryURL: HistoryStorage.syncDirectoryURL()).loadState().lastUploadAt
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
        records: [ActivitySyncRecord]
    ) -> [ActivitySyncRecord] {
        let cutoffKey = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        return records.filter { $0.date >= cutoffKey }
    }

    static func recordsByID(
        records: [ActivitySyncRecord]
    ) -> [String: ActivitySyncRecord] {
        filteredRetained(records: records)
            .reduce(into: [String: ActivitySyncRecord]()) { result, record in
                result[record.id] = record
            }
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

/// records 包含所有设备的日聚合, 不含 threadIDs 和 turnIds
/// currentDeviceId 用于展示时替换本机云端副本, 避免重复计数
nonisolated struct SyncSnapshot: Equatable {
    let records: [ActivitySyncRecord]
    let currentDeviceID: String?
    var tokenUsageByDate: [String: TokenUsage]?
    var isActivityComplete = true

    static let disabled = SyncSnapshot(records: [], currentDeviceID: nil)
}

private nonisolated enum SyncError: Error {
    case missingAccountSalt
    case missingIOPlatformUUID
    case missingRecordResult
    case randomSaltFailed
}
