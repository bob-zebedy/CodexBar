import CloudKit
import CryptoKit
import Foundation
import IOKit
import os
import Security

nonisolated enum WorkflowSyncCloudKit {
    private static let containerIdentifier = "iCloud.app.zabrian.codexbar"

    static func makeContainer() -> CKContainer {
        CKContainer(identifier: containerIdentifier)
    }
}

/// 同步失败时定位到哪一步, 只用于日志
private nonisolated enum WorkflowSyncStage: String {
    case zone
    case device
    case fetch
    case upload
    case prune
}

/// 将本机 daily.jsonl 的脱敏聚合行同步到 CloudKit private database
actor WorkflowSyncService {
    private let database: CKDatabase
    private let fileManager: FileManager
    private let directoryURL: URL

    // zone 存在性和 account salt 首次确认后跨轮缓存, 省掉每轮同步的两次固定往返
    // 任一轮同步失败时作废: iCloud 账号切换必然伴随请求报错, 下一轮会重新确认
    private var isSyncZoneConfirmed = false
    private var cachedAccountSalt: Data?

    init(
        container: CKContainer = WorkflowSyncCloudKit.makeContainer(),
        fileManager: FileManager = .default,
        directoryURL: URL = WorkflowStorage.syncDirectoryURL()
    ) {
        database = container.privateCloudDatabase
        self.fileManager = fileManager
        self.directoryURL = directoryURL
    }

    // MARK: - 同步入口

    func snapshotFromCacheIfEnabled() -> WorkflowSyncSnapshot {
        guard WorkflowSyncSettings.isEnabled() else {
            return .disabled
        }

        let state = loadState()
        return snapshot(from: state)
    }

    /// 显式重建后, 将所选日期标记为当前设备云端贡献的权威替换来源
    func markReplacementNeeded(for dates: [String]) throws {
        let validDates = Set(dates.filter(WorkflowStorage.isValidDateKey))
        guard !validDates.isEmpty else {
            return
        }

        var state = loadState()
        state.replacementDates = Set(state.replacementDates)
            .union(validDates)
            .sorted()
        for date in validDates {
            state.hashByDate.removeValue(forKey: date)
        }
        try saveState(state)
    }

    func hasPendingReplacement(for dates: [String]) -> Bool {
        !Set(loadState().replacementDates).isDisjoint(with: dates)
    }

    func synchronizeIfEnabled(
        localAggregates: [WorkflowDailyAggregate],
        trigger: LogTrigger
    ) async -> WorkflowSyncSnapshot {
        guard WorkflowSyncSettings.isEnabled() else {
            AppLog.sync.notice(
                "同步已跳过: trigger=\(trigger.rawValue, privacy: .public); reason=syncOff"
            )
            return .disabled
        }

        AppLog.sync.notice("同步开始: trigger=\(trigger.rawValue, privacy: .public)")
        let duration = LogDuration()
        var stage = WorkflowSyncStage.zone
        var didSucceed = false
        var failureMessage: String?
        Self.postSyncNotification(.workflowSyncDidStart)
        defer {
            Self.postSyncNotification(
                .workflowSyncDidFinish,
                didSucceed: didSucceed,
                failureMessage: failureMessage
            )
        }

        var state = loadState()

        do {
            try await ensureSyncZoneExists()
            stage = .device
            let deviceId = try await resolveCurrentDeviceId()
            try resetStateIfDeviceChanged(deviceId, state: &state)
            try await migrateStateIfNeeded(&state)

            stage = .fetch
            let localByDate = Self.syncedAggregatesByDate(localAggregates)
            try await refreshCacheBeforeUpload(
                localByDate: localByDate,
                deviceId: deviceId,
                state: &state
            )

            stage = .upload
            let forceBackfill = WorkflowSyncSettings.needsBackfill()
            let confirmedDates = try await uploadChangedAggregates(
                localByDate: localByDate,
                remoteRecords: loadCachedRecords(),
                state: &state
            )
            try finalizeUpload(
                confirmedDates: confirmedDates,
                localByDate: localByDate,
                forceBackfill: forceBackfill,
                state: &state
            )

            try await refreshCacheFromRemote()
            stage = .prune
            let deletedCount = try await pruneCurrentDeviceRecordsIfNeeded(
                deviceId: deviceId,
                state: &state
            )
            try saveState(state)
            didSucceed = true
            // confirmed 是本地与远端已对齐的日期数, 含哈希未变而无需上传的那些
            // 它小于 local 就说明这一轮还有日期没落到云上
            let elapsed = duration.elapsed
            AppLog.sync.notice(
                "同步完成: trigger=\(trigger.rawValue, privacy: .public); local=\(localByDate.count); confirmed=\(confirmedDates.count); deleted=\(deletedCount); elapsed=\(elapsed, privacy: .public)"
            )
        } catch {
            let reason = WorkflowSyncFailureReason.classify(error)
            let elapsed = duration.elapsed
            AppLog.sync.error(
                "同步失败: trigger=\(trigger.rawValue, privacy: .public); stage=\(stage.rawValue, privacy: .public); elapsed=\(elapsed, privacy: .public); reason=\(reason.rawValue, privacy: .public); detail=\(error.localizedDescription, privacy: .public)"
            )
            invalidateAccountScopedCaches()
            failureMessage = reason.message
            try? saveState(state)
        }

        let latestState = loadState()
        return snapshot(from: latestState)
    }

    private func refreshCacheBeforeUpload(
        localByDate: [String: LocalSyncAggregate],
        deviceId: String,
        state: inout WorkflowSyncState
    ) async throws {
        guard !state.replacementDates.isEmpty else {
            try await refreshCacheFromRemote()
            return
        }

        // 替换前全量拉取, 避免增量缓存遗漏同设备同日期的旧 generation
        try await rebuildCacheFromRemote()
        try await preparePendingReplacements(
            localByDate: localByDate,
            deviceId: deviceId,
            state: &state
        )
    }

    private func finalizeUpload(
        confirmedDates: Set<String>,
        localByDate: [String: LocalSyncAggregate],
        forceBackfill: Bool,
        state: inout WorkflowSyncState
    ) throws {
        let completedReplacementDates = Set(state.replacementDates).intersection(confirmedDates)
        if !completedReplacementDates.isEmpty {
            state.replacementDates.removeAll { completedReplacementDates.contains($0) }
            try saveState(state)
        }

        if forceBackfill,
           backfillCompleted(localByDate: localByDate, confirmedDates: confirmedDates) {
            WorkflowSyncSettings.clearBackfillRequest()
        }
    }

    private func resetStateIfDeviceChanged(
        _ deviceId: String,
        state: inout WorkflowSyncState
    ) throws {
        guard state.deviceId != deviceId else {
            return
        }

        try removeCursorIfPresent()
        try saveCachedRecords([])

        let resetState = WorkflowSyncState(
            deviceId: deviceId,
            replacementDates: state.replacementDates
        )
        try saveState(resetState)
        state = resetState
    }

    private static func syncedAggregatesByDate(
        _ aggregates: [WorkflowDailyAggregate]
    ) -> [String: LocalSyncAggregate] {
        aggregates.reduce(into: [String: LocalSyncAggregate]()) { result, aggregate in
            result[aggregate.date] = LocalSyncAggregate(
                aggregate: aggregate.syncedAggregate,
                sourceIsFresh: aggregate.sourceIsFresh
            )
        }
    }

    private func backfillCompleted(
        localByDate: [String: LocalSyncAggregate],
        confirmedDates: Set<String>
    ) -> Bool {
        localByDate.keys.allSatisfy(confirmedDates.contains)
    }

    private func snapshot(from state: WorkflowSyncState) -> WorkflowSyncSnapshot {
        guard let deviceId = state.deviceId else {
            return .disabled
        }

        let replacementDates = Set(state.replacementDates)
        let records = Self.filteredRetained(records: loadCachedRecords()).filter { record in
            record.deviceId != deviceId || !replacementDates.contains(record.date)
        }

        return WorkflowSyncSnapshot(
            records: records,
            currentDeviceId: deviceId
        )
    }
}

private extension WorkflowSyncService {
    struct LocalSyncAggregate {
        let aggregate: WorkflowSyncedDailyAggregate
        let sourceIsFresh: Bool
    }

    struct PendingUpload {
        let date: String
        let aggregate: WorkflowSyncedDailyAggregate
        let sourceIsFresh: Bool
        let hash: String
    }

    struct PendingRecord {
        let upload: PendingUpload
        let legacyRecordID: CKRecord.ID
        let generationRecordID: CKRecord.ID?
    }

    struct RecordToSave {
        let upload: PendingUpload
        let record: CKRecord
    }

    struct ConfirmedHash {
        let date: String
        let hash: String
        let didUpload: Bool
    }

    enum Metrics {
        static let syncSchemaVersion = 4
        static let syncZoneName = "CodexBarZone"
        static let saltByteCount = 32
        static let recordFetchLimit = 200
        static let queryFetchLimit = 200
        static let uploadBatchSize = 25
        static let uploadTimeBudget: TimeInterval = 20
    }

    enum RecordTypes {
        static let metadata = "CodexBarSyncMetadata"
        static let dailyAggregate = "CodexBarDailyAggregate"
    }

    enum FieldKeys {
        static let salt = "salt"
        static let schemaVersion = "schemaVersion"
        static let deviceId = "deviceId"
        static let date = "date"
        static let sourceGeneration = "sourceGeneration"
        static let eventCount = "eventCount"
        static let sessionStartCount = "sessionStartCount"
        static let stopCount = "stopCount"
        static let preToolUseCount = "preToolUseCount"
        static let postToolUseCount = "postToolUseCount"
        static let permissionRequestCount = "permissionRequestCount"
        static let preCompactCount = "preCompactCount"
        static let postCompactCount = "postCompactCount"
        static let subagentStartCount = "subagentStartCount"
        static let subagentStopCount = "subagentStopCount"
        static let sessionCount = "sessionCount"
        static let turnCount = "turnCount"
        static let projectCounts = "projectCounts"
        static let modelCounts = "modelCounts"
        static let updatedAt = "updatedAt"
    }

    static let accountSaltRecordName = "accountSalt"

    var syncZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Metrics.syncZoneName, ownerName: CKCurrentUserDefaultName)
    }

    var accountSaltRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.accountSaltRecordName, zoneID: syncZoneID)
    }

    nonisolated static func stateURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("state.json", isDirectory: false)
    }

    var stateURL: URL {
        Self.stateURL(in: directoryURL)
    }

    var cacheURL: URL {
        directoryURL.appendingPathComponent("cache.jsonl", isDirectory: false)
    }

    var cursorURL: URL {
        directoryURL.appendingPathComponent("cursor.data", isDirectory: false)
    }

    // MARK: - 上传

    func uploadChangedAggregates(
        localByDate: [String: LocalSyncAggregate],
        remoteRecords: [WorkflowSyncedDailyRecord],
        state: inout WorkflowSyncState
    ) async throws -> Set<String> {
        guard let deviceId = state.deviceId else {
            return []
        }

        // 每个日期的 hash 是一次 JSON 编码加 SHA256, 本轮只算一次
        // 既用来判定"和上次一样不必上传", 也直接填进待上传项
        let localHashByDate = try localByDate.mapValues { try hash(for: $0.aggregate) }

        var confirmedDates = Set<String>()
        for (date, hash) in localHashByDate where state.hashByDate[date] == hash {
            confirmedDates.insert(date)
        }

        let pendingUploads = makePendingUploads(
            for: Set(localByDate.keys),
            localByDate: localByDate,
            localHashByDate: localHashByDate,
            state: state
        )
        guard !pendingUploads.isEmpty else {
            return confirmedDates
        }

        let deadline = Date().addingTimeInterval(Metrics.uploadTimeBudget)

        for batchStart in stride(from: 0, to: pendingUploads.count, by: Metrics.uploadBatchSize) {
            guard !Task.isCancelled, Date() < deadline else {
                break
            }

            let batchEnd = min(batchStart + Metrics.uploadBatchSize, pendingUploads.count)
            let batch = Array(pendingUploads[batchStart ..< batchEnd])
            let confirmedBatch: [ConfirmedHash]
            do {
                confirmedBatch = try await processUploadBatch(
                    batch,
                    deviceId: deviceId,
                    remoteRecords: remoteRecords
                )
            } catch {
                try markPendingForRetry(batch, state: &state)
                throw error
            }

            try applyConfirmedHashes(confirmedBatch, to: &state)
            confirmedDates.formUnion(confirmedBatch.map(\.date))
        }

        return confirmedDates
    }

    func markPendingForRetry(
        _ pendingUploads: [PendingUpload],
        state: inout WorkflowSyncState
    ) throws {
        for upload in pendingUploads {
            state.hashByDate.removeValue(forKey: upload.date)
        }
        try saveState(state)
    }

    func preparePendingReplacements(
        localByDate: [String: LocalSyncAggregate],
        deviceId: String,
        state: inout WorkflowSyncState
    ) async throws {
        let replacementDates = Set(state.replacementDates).intersection(localByDate.keys)
        guard !replacementDates.isEmpty else {
            return
        }

        let cachedRecords = loadCachedRecords()
        let recordsToReplace = cachedRecords.filter {
            $0.deviceId == deviceId && replacementDates.contains($0.date)
        }
        var recordIDs = Set(recordsToReplace.map {
            CKRecord.ID(recordName: $0.id, zoneID: syncZoneID)
        })

        for date in replacementDates {
            recordIDs.insert(recordID(deviceId: deviceId, date: date))
            if let generation = localByDate[date]?.aggregate.sourceGeneration {
                recordIDs.insert(recordID(deviceId: deviceId, date: date, generation: generation))
            }
        }

        try await deleteRecords(Array(recordIDs))

        try saveCachedRecords(cachedRecords.filter {
            $0.deviceId != deviceId || !replacementDates.contains($0.date)
        })
        for date in replacementDates {
            state.hashByDate.removeValue(forKey: date)
        }
        try saveState(state)
    }

    func deleteRecords(_ recordIDs: [CKRecord.ID]) async throws {
        for batchStart in stride(from: 0, to: recordIDs.count, by: Metrics.uploadBatchSize) {
            let batchEnd = min(batchStart + Metrics.uploadBatchSize, recordIDs.count)
            let batch = Array(recordIDs[batchStart ..< batchEnd])
            let result = try await database.modifyRecords(
                saving: [],
                deleting: batch,
                savePolicy: .changedKeys,
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
                    throw WorkflowSyncError.missingRecordResult
                }
            }
        }
    }

    func applyConfirmedHashes(
        _ confirmedBatch: [ConfirmedHash],
        to state: inout WorkflowSyncState
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
        try saveState(state)
    }

    /// hash 由调用方一次算好传进来, 这里只做筛选
    func makePendingUploads(
        for candidateDates: Set<String>,
        localByDate: [String: LocalSyncAggregate],
        localHashByDate: [String: String],
        state: WorkflowSyncState
    ) -> [PendingUpload] {
        candidateDates.compactMap { date in
            guard let local = localByDate[date],
                  let hash = localHashByDate[date],
                  state.hashByDate[date] != hash else {
                return nil
            }

            return PendingUpload(
                date: date,
                aggregate: local.aggregate,
                sourceIsFresh: local.sourceIsFresh,
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

    /// 远端已有更完整的同源聚合, 或者同日已有记录且本地不是新鲜来源时都不覆盖
    private func resolveUploadTarget(
        _ pendingRecord: PendingRecord,
        deviceId: String,
        remoteRecords: [WorkflowSyncedDailyRecord],
        existingRecords: [CKRecord.ID: Result<CKRecord, any Error>]
    ) throws -> UploadTarget {
        let legacyRecord = try Self.fetchedRecord(
            from: existingRecords[pendingRecord.legacyRecordID]
        )
        let generationRecord: CKRecord? = if let recordID = pendingRecord.generationRecordID {
            try Self.fetchedRecord(from: existingRecords[recordID])
        } else {
            nil
        }
        let fetchedRecords = [legacyRecord, generationRecord].compactMap(\.self)
        let matchingRecord = fetchedRecords.first { record in
            guard let remote = Self.remoteDailyRecord(from: record) else {
                return false
            }
            return pendingRecord.upload.aggregate.matchesRemoteSource(remote.daily)
        }

        if let matchingRecord,
           let remoteAggregate = Self.remoteDailyRecord(from: matchingRecord)?.daily,
           remoteAggregate.eventCount > pendingRecord.upload.aggregate.eventCount,
           pendingRecord.upload.aggregate.sourceGeneration != nil {
            return .skip
        }

        if let matchingRecord {
            return .save(matchingRecord)
        }

        // 上面两个分支都用不到它; 放在早退之后, 命中缓存的那些 pending 就不必扫一遍全量远端记录
        var knownRemoteRecords = remoteRecords.filter {
            $0.deviceId == deviceId && $0.date == pendingRecord.upload.date
        }
        for record in fetchedRecords.compactMap({ Self.remoteDailyRecord(from: $0) })
            where !knownRemoteRecords.contains(where: { $0.id == record.id }) {
            knownRemoteRecords.append(record)
        }

        if knownRemoteRecords.isEmpty {
            return .save(CKRecord(
                recordType: RecordTypes.dailyAggregate,
                recordID: pendingRecord.generationRecordID ?? pendingRecord.legacyRecordID
            ))
        }

        if pendingRecord.upload.sourceIsFresh,
           let generationRecordID = pendingRecord.generationRecordID,
           generationRecord == nil {
            return .save(CKRecord(
                recordType: RecordTypes.dailyAggregate,
                recordID: generationRecordID
            ))
        }

        return .skip
    }

    func processUploadBatch(
        _ pendingUploads: [PendingUpload],
        deviceId: String,
        remoteRecords: [WorkflowSyncedDailyRecord]
    ) async throws -> [ConfirmedHash] {
        let pendingRecords: [PendingRecord] = pendingUploads.map { upload in
            PendingRecord(
                upload: upload,
                legacyRecordID: recordID(deviceId: deviceId, date: upload.date),
                generationRecordID: upload.aggregate.sourceGeneration.map { generation in
                    recordID(deviceId: deviceId, date: upload.date, generation: generation)
                }
            )
        }
        let recordIDs = Array(Set(pendingRecords.flatMap { pendingRecord in
            [pendingRecord.legacyRecordID, pendingRecord.generationRecordID].compactMap(\.self)
        }))
        let existingRecords = try await database.records(for: recordIDs)
        var confirmedHashes = [ConfirmedHash]()
        var recordsToSave = [RecordToSave]()

        for pendingRecord in pendingRecords {
            switch try resolveUploadTarget(
                pendingRecord,
                deviceId: deviceId,
                remoteRecords: remoteRecords,
                existingRecords: existingRecords
            ) {
            case .skip:
                confirmedHashes.append(
                    ConfirmedHash(
                        date: pendingRecord.upload.date,
                        hash: pendingRecord.upload.hash,
                        didUpload: false
                    )
                )
            case let .save(record):
                apply(pendingRecord.upload.aggregate, deviceId: deviceId, to: record)
                recordsToSave.append(
                    RecordToSave(upload: pendingRecord.upload, record: record)
                )
            }
        }

        guard !recordsToSave.isEmpty else {
            return confirmedHashes
        }

        let records = recordsToSave.map(\.record)

        let result = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: false
        )

        for pendingRecord in recordsToSave {
            switch result.saveResults[pendingRecord.record.recordID] {
            case .success:
                confirmedHashes.append(
                    ConfirmedHash(
                        date: pendingRecord.upload.date,
                        hash: pendingRecord.upload.hash,
                        didUpload: true
                    )
                )
            case let .failure(error):
                throw error
            case nil:
                throw WorkflowSyncError.missingRecordResult
            }
        }

        return confirmedHashes
    }

    // MARK: - 拉取与缓存

    func refreshCacheFromRemote() async throws {
        guard let token = try loadCursor() else {
            try await rebuildCacheFromRemote()
            return
        }

        do {
            try await applyZoneChangesToCache(
                since: token,
                cachedRecords: loadCachedRecords()
            )
        } catch {
            // 增量拉取退化成全量重建, 代价高得多, 反复出现说明游标或缓存有问题
            AppLog.sync.notice(
                "增量拉取已降级: detail=\(error.localizedDescription, privacy: .public); action=fullRebuild"
            )
            try await rebuildCacheFromRemote()
        }
    }

    func applyZoneChangesToCache(
        since initialToken: CKServerChangeToken?,
        cachedRecords: [WorkflowSyncedDailyRecord]
    ) async throws {
        var cacheByID = Self.recordsByID(records: cachedRecords)
        var token: CKServerChangeToken? = initialToken
        var moreComing = true

        while moreComing {
            let result = try await database.recordZoneChanges(
                inZoneWith: syncZoneID,
                since: token,
                desiredKeys: nil,
                resultsLimit: Metrics.recordFetchLimit
            )

            try mergeChangedRecords(
                result.modificationResultsByID.values,
                into: &cacheByID
            )
            removeDeletedRecords(result.deletions, from: &cacheByID)

            token = result.changeToken
            moreComing = result.moreComing
        }

        try saveCachedRecords(
            Self.filteredRetained(records: Array(cacheByID.values))
        )
        if let token {
            try saveCursor(token)
        }
    }

    func rebuildCacheFromRemote() async throws {
        try removeCursorIfPresent()
        let syncedRecords = try await fetchAllRemoteDailyRecords()
        let retainedRecords = Self.filteredRetained(records: syncedRecords)
        try saveCachedRecords(retainedRecords)
        await establishCursorBaseline(cachedRecords: retainedRecords)
    }

    func fetchAllRemoteDailyRecords() async throws -> [WorkflowSyncedDailyRecord] {
        let query = CKQuery(
            recordType: RecordTypes.dailyAggregate,
            predicate: NSPredicate(format: "TRUEPREDICATE")
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: FieldKeys.deviceId, ascending: true),
            NSSortDescriptor(key: FieldKeys.date, ascending: true)
        ]

        let matches = try await fetchAllRecordMatches(matching: query)
        return try Self.remoteDailyRecords(from: matches)
    }

    func fetchCurrentDeviceRecordIDsToPrune(
        deviceId: String,
        cutoffKey: String
    ) async throws -> [CKRecord.ID] {
        let query = CKQuery(
            recordType: RecordTypes.dailyAggregate,
            predicate: NSPredicate(
                format: "%K == %@",
                FieldKeys.deviceId,
                deviceId
            )
        )

        let currentDeviceMatches = try await fetchAllRecordMatches(
            matching: query,
            desiredKeys: [FieldKeys.date]
        )
        return try currentDeviceMatches.compactMap { recordID, result in
            let record = try result.get()
            guard let date = record[FieldKeys.date] as? String,
                  WorkflowStorage.isValidDateKey(date) else {
                // 无法进入保留窗口比较的当前设备记录是异常数据, 一并清理
                return recordID
            }

            return date < cutoffKey ? recordID : nil
        }
    }

    func fetchAllRecordMatches(
        matching query: CKQuery,
        desiredKeys: [String]? = nil
    ) async throws -> [(CKRecord.ID, Result<CKRecord, Error>)] {
        let firstPage = try await database.records(
            matching: query,
            inZoneWith: syncZoneID,
            desiredKeys: desiredKeys,
            resultsLimit: Metrics.queryFetchLimit
        )
        var matches = firstPage.matchResults
        var cursor = firstPage.queryCursor

        while let currentCursor = cursor {
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

    func establishCursorBaseline(cachedRecords: [WorkflowSyncedDailyRecord]) async {
        do {
            try await applyZoneChangesToCache(
                since: nil,
                cachedRecords: cachedRecords
            )
        } catch {
            // 丢掉游标, 下次同步会从头拉一遍
            AppLog.sync.notice(
                "游标基线已降级: detail=\(error.localizedDescription, privacy: .public); action=dropCursor"
            )
            try? fileManager.removeItem(at: cursorURL)
        }
    }

    func mergeChangedRecords(
        _ modificationResults: Dictionary<CKRecord.ID, Result<CKDatabase.RecordZoneChange.Modification, Error>>.Values,
        into cacheByID: inout [String: WorkflowSyncedDailyRecord]
    ) throws {
        for modificationResult in modificationResults {
            let modification = try modificationResult.get()
            guard let record = Self.remoteDailyRecord(from: modification.record) else {
                continue
            }

            cacheByID[record.id] = record
        }
    }

    func removeDeletedRecords(
        _ deletions: [CKDatabase.RecordZoneChange.Deletion],
        from cacheByID: inout [String: WorkflowSyncedDailyRecord]
    ) {
        for deletion in deletions where deletion.recordType == RecordTypes.dailyAggregate {
            guard let cacheID = cacheID(fromRecordName: deletion.recordID.recordName) else {
                continue
            }
            cacheByID.removeValue(forKey: cacheID)
        }
    }

    @discardableResult
    func pruneCurrentDeviceRecordsIfNeeded(
        deviceId: String,
        state: inout WorkflowSyncState
    ) async throws -> Int {
        let today = WorkflowStorage.dateKey(for: Date())
        guard state.lastPrunedDate != today else {
            return 0
        }

        let cutoffKey = WorkflowStorage.dateKey(for: WorkflowStorage.retentionCutoffDate())
        let expiredDates = Set(state.hashByDate.keys.filter { $0 < cutoffKey })
        state.replacementDates.removeAll { $0 < cutoffKey }
        var recordIDs = try await Set(
            fetchCurrentDeviceRecordIDsToPrune(
                deviceId: deviceId,
                cutoffKey: cutoffKey
            )
        )
        for date in expiredDates {
            recordIDs.insert(
                CKRecord.ID(
                    recordName: WorkflowSyncedDailyRecord.legacyRecordName(
                        deviceId: deviceId,
                        date: date
                    ),
                    zoneID: syncZoneID
                )
            )
        }

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

    func resolveCurrentDeviceId() async throws -> String {
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
        let result = try await database.records(for: [recordID])
        guard let record = try Self.fetchedRecord(from: result[recordID]) else {
            return nil
        }
        guard let salt = record[FieldKeys.salt] as? Data,
              salt.count == Metrics.saltByteCount else {
            throw WorkflowSyncError.missingAccountSalt
        }
        return salt
    }

    func createAccountSalt(_ recordID: CKRecord.ID) async throws -> Data {
        let salt = try Self.randomSalt()
        let record = CKRecord(recordType: RecordTypes.metadata, recordID: recordID)
        record[FieldKeys.salt] = salt as CKRecordValue
        record[FieldKeys.schemaVersion] = Metrics.syncSchemaVersion as CKRecordValue

        do {
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
                throw WorkflowSyncError.missingRecordResult
            }
        } catch let error as CKError where error.code == .serverRecordChanged || error.code == .constraintViolation {
            if let salt = try await fetchAccountSalt(recordID) {
                return salt
            }
        }

        throw WorkflowSyncError.missingAccountSalt
    }

    // MARK: - 记录与 zone 维护

    func ensureSyncZoneExists() async throws {
        guard !isSyncZoneConfirmed else {
            return
        }

        if try await syncZoneExists() == false {
            let zone = CKRecordZone(zoneID: syncZoneID)
            let result = try await database.modifyRecordZones(saving: [zone], deleting: [])

            switch result.saveResults[syncZoneID] {
            case .success:
                break
            case let .failure(error):
                throw error
            case nil:
                throw WorkflowSyncError.missingRecordResult
            }
        }

        isSyncZoneConfirmed = true
    }

    func invalidateAccountScopedCaches() {
        isSyncZoneConfirmed = false
        cachedAccountSalt = nil
    }

    func syncZoneExists() async throws -> Bool {
        do {
            _ = try await database.recordZone(for: syncZoneID)
            return true
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return false
        }
    }

    func apply(
        _ aggregate: WorkflowSyncedDailyAggregate,
        deviceId: String,
        to record: CKRecord
    ) {
        record[FieldKeys.schemaVersion] = Metrics.syncSchemaVersion as CKRecordValue
        record[FieldKeys.deviceId] = deviceId as CKRecordValue
        record[FieldKeys.date] = aggregate.date as CKRecordValue
        record[FieldKeys.sourceGeneration] = aggregate.sourceGeneration as CKRecordValue?
        record[FieldKeys.eventCount] = aggregate.eventCount as CKRecordValue
        record[FieldKeys.sessionStartCount] = aggregate.sessionStartCount as CKRecordValue
        record[FieldKeys.stopCount] = aggregate.stopCount as CKRecordValue
        record[FieldKeys.preToolUseCount] = aggregate.preToolUseCount as CKRecordValue
        record[FieldKeys.postToolUseCount] = aggregate.postToolUseCount as CKRecordValue
        record[FieldKeys.permissionRequestCount] = aggregate.permissionRequestCount as CKRecordValue
        record[FieldKeys.preCompactCount] = aggregate.preCompactCount as CKRecordValue
        record[FieldKeys.postCompactCount] = aggregate.postCompactCount as CKRecordValue
        record[FieldKeys.subagentStartCount] = aggregate.subagentStartCount as CKRecordValue
        record[FieldKeys.subagentStopCount] = aggregate.subagentStopCount as CKRecordValue
        record[FieldKeys.sessionCount] = aggregate.sessionCount as CKRecordValue?
        record[FieldKeys.turnCount] = aggregate.turnCount as CKRecordValue?
        record[FieldKeys.projectCounts] = Self.countsData(aggregate.projectCounts) as CKRecordValue
        record[FieldKeys.modelCounts] = Self.countsData(aggregate.modelCounts ?? [:]) as CKRecordValue
        record[FieldKeys.updatedAt] = Date() as CKRecordValue
    }

    func recordID(deviceId: String, date: String) -> CKRecord.ID {
        recordID(deviceId: deviceId, date: date, generation: nil)
    }

    func recordID(
        deviceId: String,
        date: String,
        generation: String?
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: recordName(deviceId: deviceId, date: date, generation: generation),
            zoneID: syncZoneID
        )
    }

    func recordName(
        deviceId: String,
        date: String,
        generation: String?
    ) -> String {
        let legacyName = WorkflowSyncedDailyRecord.legacyRecordName(
            deviceId: deviceId,
            date: date
        )
        return generation.map { "\(legacyName)_\($0)" } ?? legacyName
    }

    func cacheID(fromRecordName recordName: String) -> String? {
        recordName.isEmpty ? nil : recordName
    }

    func hash(for aggregate: WorkflowSyncedDailyAggregate) throws -> String {
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
                userInfo[WorkflowSyncNotificationKey.didSucceed] = didSucceed
            }
            if let failureMessage {
                userInfo[WorkflowSyncNotificationKey.failureMessage] = failureMessage
            }

            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: userInfo.isEmpty ? nil : userInfo
            )
        }
    }
}

extension WorkflowSyncService {
    /// 设置页读取最近上传时间, 与内部 loadState 使用同一 schema 校验口径
    nonisolated static func loadLastUploadAt() -> Date? {
        loadState(at: stateURL(in: WorkflowStorage.syncDirectoryURL())).lastUploadAt
    }
}

private extension WorkflowSyncService {
    func loadState() -> WorkflowSyncState {
        Self.loadState(at: stateURL)
    }

    func migrateStateIfNeeded(_ state: inout WorkflowSyncState) async throws {
        guard state.schema == WorkflowSyncState.previousSchema else {
            return
        }

        try await rebuildCacheFromRemote()

        var migratedState = state
        migratedState.schema = WorkflowSyncState.currentSchema
        try saveState(migratedState)
        state = migratedState
    }

    nonisolated static func loadState(at url: URL) -> WorkflowSyncState {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let state = try? JSONDecoder().decode(WorkflowSyncState.self, from: data) else {
            return WorkflowSyncState()
        }
        guard WorkflowSyncState.supports(state.schema) else {
            return WorkflowSyncState()
        }
        return state
    }

    func saveState(_ state: WorkflowSyncState) throws {
        try ensureSyncDirectoryExists()
        let data = try JSONLines.stableEncoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    func loadCachedRecords() -> [WorkflowSyncedDailyRecord] {
        guard let data = try? Data(contentsOf: cacheURL), !data.isEmpty else {
            return []
        }

        return JSONLines.decode(from: data)
    }

    func saveCachedRecords(_ records: [WorkflowSyncedDailyRecord]) throws {
        try ensureSyncDirectoryExists()

        let encoder = JSONLines.stableEncoder
        let data = try records
            .sorted { lhs, rhs in
                if lhs.deviceId == rhs.deviceId {
                    if lhs.date == rhs.date {
                        return lhs.id < rhs.id
                    }
                    return lhs.date < rhs.date
                }
                return lhs.deviceId < rhs.deviceId
            }
            .reduce(into: Data()) { result, record in
                try result.append(encoder.encode(record))
                result.append(0x0A)
            }
        try data.write(to: cacheURL, options: .atomic)
    }

    func loadCursor() throws -> CKServerChangeToken? {
        guard let data = try? Data(contentsOf: cursorURL), !data.isEmpty else {
            return nil
        }

        return try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    func saveCursor(_ token: CKServerChangeToken) throws {
        try ensureSyncDirectoryExists()
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
        try data.write(to: cursorURL, options: .atomic)
    }

    func removeCursorIfPresent() throws {
        guard fileManager.fileExists(atPath: cursorURL.path) else {
            return
        }
        try fileManager.removeItem(at: cursorURL)
    }

    func ensureSyncDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}

private extension WorkflowSyncService {
    static func remoteDailyRecords(
        from matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) throws -> [WorkflowSyncedDailyRecord] {
        try matchResults.compactMap { _, result in
            try remoteDailyRecord(from: result.get())
        }
    }

    static func remoteDailyRecord(from record: CKRecord) -> WorkflowSyncedDailyRecord? {
        guard record.recordType == RecordTypes.dailyAggregate,
              let deviceId = record[FieldKeys.deviceId] as? String,
              let date = record[FieldKeys.date] as? String,
              WorkflowStorage.isValidDateKey(date) else {
            return nil
        }

        let aggregate = WorkflowSyncedDailyAggregate(
            date: date,
            sourceGeneration: record[FieldKeys.sourceGeneration] as? String,
            eventCount: intValue(record[FieldKeys.eventCount]),
            sessionStartCount: intValue(record[FieldKeys.sessionStartCount]),
            stopCount: intValue(record[FieldKeys.stopCount]),
            preToolUseCount: intValue(record[FieldKeys.preToolUseCount]),
            postToolUseCount: intValue(record[FieldKeys.postToolUseCount]),
            permissionRequestCount: intValue(record[FieldKeys.permissionRequestCount]),
            preCompactCount: intValue(record[FieldKeys.preCompactCount]),
            postCompactCount: intValue(record[FieldKeys.postCompactCount]),
            subagentStartCount: intValue(record[FieldKeys.subagentStartCount]),
            subagentStopCount: intValue(record[FieldKeys.subagentStopCount]),
            sessionCount: optionalIntValue(record[FieldKeys.sessionCount]),
            turnCount: optionalIntValue(record[FieldKeys.turnCount]),
            projectCounts: counts(from: record[FieldKeys.projectCounts]),
            modelCounts: counts(from: record[FieldKeys.modelCounts])
        )

        return WorkflowSyncedDailyRecord(
            deviceId: deviceId,
            daily: aggregate,
            updatedAt: record[FieldKeys.updatedAt] as? Date ?? record.modificationDate,
            recordName: record.recordID.recordName
        )
    }

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
            throw WorkflowSyncError.missingRecordResult
        }
    }

    static func filteredRetained(
        records: [WorkflowSyncedDailyRecord]
    ) -> [WorkflowSyncedDailyRecord] {
        let cutoffKey = WorkflowStorage.dateKey(for: WorkflowStorage.retentionCutoffDate())
        return records.filter { $0.date >= cutoffKey }
    }

    static func recordsByID(
        records: [WorkflowSyncedDailyRecord]
    ) -> [String: WorkflowSyncedDailyRecord] {
        filteredRetained(records: records)
            .reduce(into: [String: WorkflowSyncedDailyRecord]()) { result, record in
                result[record.id] = record
            }
    }

    static func intValue(_ value: CKRecordValue?) -> Int {
        optionalIntValue(value) ?? 0
    }

    static func optionalIntValue(_ value: CKRecordValue?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    static func counts(from value: CKRecordValue?) -> [String: Int] {
        guard let data = value as? Data,
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return counts
    }

    static func countsData(_ counts: [String: Int]) -> Data {
        (try? JSONLines.stableEncoder.encode(counts)) ?? Data("{}".utf8)
    }

    static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: Metrics.saltByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw WorkflowSyncError.randomSaltFailed
        }
        return Data(bytes)
    }

    static func ioPlatformUUID() throws -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else {
            throw WorkflowSyncError.missingIOPlatformUUID
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
            throw WorkflowSyncError.missingIOPlatformUUID
        }

        return value
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// records 包含所有设备的脱敏聚合; currentDeviceId 用于展示时替换而不是叠加本机云端副本
nonisolated struct WorkflowSyncSnapshot: Equatable {
    let records: [WorkflowSyncedDailyRecord]
    let currentDeviceId: String?

    static let disabled = WorkflowSyncSnapshot(records: [], currentDeviceId: nil)
}

private nonisolated struct WorkflowSyncState: Codable, Equatable {
    static let currentSchema = 4
    static let previousSchema = 3

    static func supports(_ schema: Int) -> Bool {
        schema == currentSchema || schema == previousSchema
    }

    var schema: Int
    var deviceId: String?
    var hashByDate: [String: String]
    var replacementDates: [String]
    var lastUploadAt: Date?
    var lastPrunedDate: String?

    init(
        schema: Int = Self.currentSchema,
        deviceId: String? = nil,
        hashByDate: [String: String] = [:],
        replacementDates: [String] = [],
        lastUploadAt: Date? = nil,
        lastPrunedDate: String? = nil
    ) {
        self.schema = schema
        self.deviceId = deviceId
        self.hashByDate = hashByDate
        self.replacementDates = replacementDates
        self.lastUploadAt = lastUploadAt
        self.lastPrunedDate = lastPrunedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        hashByDate = try container.decodeIfPresent([String: String].self, forKey: .hashByDate)
            ?? [:]
        let decodedReplacementDates = try container.decodeIfPresent(
            [String].self,
            forKey: .replacementDates
        ) ?? []
        replacementDates = Set(
            decodedReplacementDates.filter(WorkflowStorage.isValidDateKey)
        ).sorted()
        lastUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastUploadAt)
        lastPrunedDate = try container.decodeIfPresent(String.self, forKey: .lastPrunedDate)
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case deviceId
        case hashByDate
        case replacementDates
        case lastUploadAt
        case lastPrunedDate
    }
}

private nonisolated enum WorkflowSyncError: Error {
    case missingAccountSalt
    case missingIOPlatformUUID
    case missingRecordResult
    case randomSaltFailed
}
