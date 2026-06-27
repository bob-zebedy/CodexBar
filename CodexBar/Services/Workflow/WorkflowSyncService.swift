import CloudKit
import CryptoKit
import Foundation
import IOKit
import Security

/// 将本机 daily.jsonl 的脱敏聚合行同步到 CloudKit private database
actor WorkflowSyncService {
    private let database: CKDatabase
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        container: CKContainer = .default(),
        fileManager: FileManager = .default,
        directoryURL: URL = WorkflowStorage.syncDirectoryURL()
    ) {
        database = container.privateCloudDatabase
        self.fileManager = fileManager
        self.directoryURL = directoryURL
    }

    func snapshotFromCacheIfEnabled() -> WorkflowSyncSnapshot {
        guard WorkflowSyncSettings.isEnabled() else {
            return .disabled
        }

        let state = loadState()
        return snapshot(from: state)
    }

    func synchronizeIfEnabled(
        localAggregates: [WorkflowDailyAggregate],
        changedDates: Set<String>
    ) async -> WorkflowSyncSnapshot {
        guard WorkflowSyncSettings.isEnabled() else {
            return .disabled
        }

        var didSucceed = false
        var failureMessage: String?
        Self.postSyncDidStart()
        defer {
            Self.postSyncDidFinish(
                didSucceed: didSucceed,
                failureMessage: failureMessage
            )
        }

        var state = loadState()

        do {
            try await ensureSyncZoneExists()
            let deviceId = try await resolveCurrentDeviceId()
            resetStateIfDeviceChanged(deviceId, state: &state)

            let localByDate = Self.syncedAggregatesByDate(localAggregates)
            let forceBackfill = WorkflowSyncSettings.needsBackfill()
            try await uploadChangedAggregates(
                localByDate: localByDate,
                changedDates: changedDates,
                forceBackfill: forceBackfill,
                state: &state
            )

            if forceBackfill, backfillCompleted(localByDate: localByDate, state: state) {
                WorkflowSyncSettings.clearBackfillRequest()
            }

            try await refreshCacheFromRemote(currentDeviceId: deviceId)
            try await pruneCurrentDeviceRecordsIfNeeded(deviceId: deviceId, state: &state)
            try saveState(state)
            didSucceed = true
        } catch {
            failureMessage = WorkflowSyncFailureReason.classify(error).message
            try? saveState(state)
        }

        let latestState = loadState()
        return snapshot(from: latestState)
    }

    private func resetStateIfDeviceChanged(
        _ deviceId: String,
        state: inout WorkflowSyncState
    ) {
        guard state.deviceId != deviceId else {
            return
        }

        state = WorkflowSyncState(deviceId: deviceId)
        try? saveCachedRecords([])
        try? fileManager.removeItem(at: cursorURL)
    }

    private static func syncedAggregatesByDate(
        _ aggregates: [WorkflowDailyAggregate]
    ) -> [String: WorkflowSyncedDailyAggregate] {
        aggregates.reduce(into: [String: WorkflowSyncedDailyAggregate]()) { result, aggregate in
            result[aggregate.date] = aggregate.syncedAggregate
        }
    }

    private func backfillCompleted(
        localByDate: [String: WorkflowSyncedDailyAggregate],
        state: WorkflowSyncState
    ) -> Bool {
        localByDate.allSatisfy { date, aggregate in
            (try? hash(for: aggregate)) == state.hashByDate[date]
        }
    }

    private func snapshot(from state: WorkflowSyncState) -> WorkflowSyncSnapshot {
        WorkflowSyncSnapshot(
            currentDeviceId: state.deviceId,
            records: state.deviceId == nil
                ? []
                : Self.filteredRetained(records: loadCachedRecords(), excluding: state.deviceId)
        )
    }
}

private extension WorkflowSyncService {
    typealias PendingUpload = (date: String, aggregate: WorkflowSyncedDailyAggregate, hash: String)
    typealias PendingRecord = (upload: PendingUpload, recordID: CKRecord.ID)
    typealias UploadedHash = (date: String, hash: String)

    enum Metrics {
        static let syncSchemaVersion = 1
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
        static let updatedAt = "updatedAt"
    }

    static let accountSaltRecordName = "accountSalt"

    var syncZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Metrics.syncZoneName, ownerName: CKCurrentUserDefaultName)
    }

    var accountSaltRecordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.accountSaltRecordName, zoneID: syncZoneID)
    }

    var stateURL: URL {
        directoryURL.appendingPathComponent("state.json", isDirectory: false)
    }

    var cacheURL: URL {
        directoryURL.appendingPathComponent("cache.jsonl", isDirectory: false)
    }

    var cursorURL: URL {
        directoryURL.appendingPathComponent("cursor.data", isDirectory: false)
    }

    func uploadChangedAggregates(
        localByDate: [String: WorkflowSyncedDailyAggregate],
        changedDates: Set<String>,
        forceBackfill: Bool,
        state: inout WorkflowSyncState
    ) async throws {
        guard let deviceId = state.deviceId else {
            return
        }

        let pendingUploads = try makePendingUploads(
            for: uploadCandidateDates(
                localByDate: localByDate,
                changedDates: changedDates,
                forceBackfill: forceBackfill,
                state: state
            ),
            localByDate: localByDate,
            state: state
        )
        guard !pendingUploads.isEmpty else {
            return
        }

        let deadline = Date().addingTimeInterval(Metrics.uploadTimeBudget)

        for batchStart in stride(from: 0, to: pendingUploads.count, by: Metrics.uploadBatchSize) {
            guard !Task.isCancelled, Date() < deadline else {
                break
            }

            let batchEnd = min(batchStart + Metrics.uploadBatchSize, pendingUploads.count)
            let batch = Array(pendingUploads[batchStart ..< batchEnd])
            let uploadedBatch = try await uploadAggregateBatch(batch, deviceId: deviceId)

            try applyUploadedHashes(uploadedBatch, to: &state)
        }
    }

    func uploadCandidateDates(
        localByDate: [String: WorkflowSyncedDailyAggregate],
        changedDates: Set<String>,
        forceBackfill: Bool,
        state: WorkflowSyncState
    ) -> Set<String> {
        var candidateDates = Set(changedDates)
        candidateDates.formUnion(localByDate.keys.filter { state.hashByDate[$0] == nil })

        if forceBackfill {
            candidateDates.formUnion(localByDate.keys)
        }

        return candidateDates
    }

    func applyUploadedHashes(
        _ uploadedBatch: [UploadedHash],
        to state: inout WorkflowSyncState
    ) throws {
        guard !uploadedBatch.isEmpty else {
            return
        }

        for uploaded in uploadedBatch {
            state.hashByDate[uploaded.date] = uploaded.hash
        }

        state.lastUploadAt = Date()
        try saveState(state)
    }

    func makePendingUploads(
        for candidateDates: Set<String>,
        localByDate: [String: WorkflowSyncedDailyAggregate],
        state: WorkflowSyncState
    ) throws -> [PendingUpload] {
        try candidateDates.compactMap { date in
            guard let aggregate = localByDate[date] else {
                return nil
            }

            let hash = try hash(for: aggregate)
            guard state.hashByDate[date] != hash else {
                return nil
            }

            return (date: date, aggregate: aggregate, hash: hash)
        }
        .sorted { $0.date < $1.date }
    }

    func uploadAggregateBatch(
        _ pendingUploads: [PendingUpload],
        deviceId: String
    ) async throws -> [UploadedHash] {
        let pendingRecords: [PendingRecord] = pendingUploads.map {
            (upload: $0, recordID: recordID(deviceId: deviceId, date: $0.date))
        }
        let recordIDs = pendingRecords.map(\.recordID)
        let existingRecords = try await database.records(for: recordIDs)
        let records = pendingRecords.map { pendingRecord in
            let (_, aggregate, _) = pendingRecord.upload
            let existingRecord: CKRecord? = if case let .success(record) = existingRecords[pendingRecord.recordID] {
                record
            } else {
                nil
            }

            let record = existingRecord ?? CKRecord(
                recordType: RecordTypes.dailyAggregate,
                recordID: pendingRecord.recordID
            )
            apply(aggregate, deviceId: deviceId, to: record)
            return record
        }

        let result = try await database.modifyRecords(
            saving: records,
            deleting: [],
            savePolicy: .changedKeys,
            atomically: false
        )

        return pendingRecords.compactMap { pendingRecord in
            let (date, _, hash) = pendingRecord.upload
            if case .success = result.saveResults[pendingRecord.recordID] {
                return (date: date, hash: hash)
            }
            return nil
        }
    }

    func refreshCacheFromRemote(currentDeviceId: String) async throws {
        guard let token = try loadCursor() else {
            try await rebuildCacheFromRemote(currentDeviceId: currentDeviceId)
            return
        }

        do {
            try await applyZoneChangesToCache(
                since: token,
                cachedRecords: loadCachedRecords(),
                currentDeviceId: currentDeviceId
            )
        } catch {
            try await rebuildCacheFromRemote(currentDeviceId: currentDeviceId)
        }
    }

    func applyZoneChangesToCache(
        since initialToken: CKServerChangeToken?,
        cachedRecords: [WorkflowSyncedDailyRecord],
        currentDeviceId: String
    ) async throws {
        var cacheByID = Self.recordsByID(
            records: cachedRecords,
            excluding: currentDeviceId
        )
        var token: CKServerChangeToken? = initialToken
        var latestToken: CKServerChangeToken?
        var moreComing = true

        while moreComing {
            let result = try await database.recordZoneChanges(
                inZoneWith: syncZoneID,
                since: token,
                desiredKeys: nil,
                resultsLimit: Metrics.recordFetchLimit
            )

            mergeChangedRecords(
                result.modificationResultsByID.values,
                currentDeviceId: currentDeviceId,
                into: &cacheByID
            )
            removeDeletedRecords(result.deletions, from: &cacheByID)

            token = result.changeToken
            latestToken = result.changeToken
            moreComing = result.moreComing
        }

        try saveCachedRecords(
            Self.filteredRetained(
                records: Array(cacheByID.values),
                excluding: currentDeviceId
            )
        )
        if let latestToken {
            try saveCursor(latestToken)
        }
    }

    func rebuildCacheFromRemote(currentDeviceId: String) async throws {
        let syncedRecords = try await fetchAllRemoteDailyRecords()
        let retainedRecords = Self.filteredRetained(records: syncedRecords, excluding: currentDeviceId)
        try saveCachedRecords(retainedRecords)
        await establishCursorBaseline(cachedRecords: retainedRecords, currentDeviceId: currentDeviceId)
    }

    func fetchAllRemoteDailyRecords() async throws -> [WorkflowSyncedDailyRecord] {
        var records = [WorkflowSyncedDailyRecord]()
        var queryCursor: CKQueryOperation.Cursor?

        let query = CKQuery(
            recordType: RecordTypes.dailyAggregate,
            predicate: NSPredicate(format: "TRUEPREDICATE")
        )
        query.sortDescriptors = [
            NSSortDescriptor(key: FieldKeys.deviceId, ascending: true),
            NSSortDescriptor(key: FieldKeys.date, ascending: true)
        ]

        let firstPage = try await database.records(
            matching: query,
            inZoneWith: syncZoneID,
            desiredKeys: nil,
            resultsLimit: Metrics.queryFetchLimit
        )
        records.append(contentsOf: Self.remoteDailyRecords(from: firstPage.matchResults))
        queryCursor = firstPage.queryCursor

        while let cursor = queryCursor {
            let page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: nil,
                resultsLimit: Metrics.queryFetchLimit
            )
            records.append(contentsOf: Self.remoteDailyRecords(from: page.matchResults))
            queryCursor = page.queryCursor
        }

        return records
    }

    func establishCursorBaseline(
        cachedRecords: [WorkflowSyncedDailyRecord],
        currentDeviceId: String
    ) async {
        do {
            try await applyZoneChangesToCache(
                since: nil,
                cachedRecords: cachedRecords,
                currentDeviceId: currentDeviceId
            )
        } catch {
            try? fileManager.removeItem(at: cursorURL)
        }
    }

    func mergeChangedRecords(
        _ modificationResults: Dictionary<CKRecord.ID, Result<CKDatabase.RecordZoneChange.Modification, Error>>.Values,
        currentDeviceId: String,
        into cacheByID: inout [String: WorkflowSyncedDailyRecord]
    ) {
        for modificationResult in modificationResults {
            guard case let .success(modification) = modificationResult,
                  let record = Self.remoteDailyRecord(from: modification.record) else {
                continue
            }

            guard record.deviceId != currentDeviceId else {
                cacheByID.removeValue(forKey: record.id)
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
            if let cacheID = cacheID(fromRecordName: deletion.recordID.recordName) {
                cacheByID.removeValue(forKey: cacheID)
            }
        }
    }

    func pruneCurrentDeviceRecordsIfNeeded(
        deviceId: String,
        state: inout WorkflowSyncState
    ) async throws {
        let today = WorkflowStorage.dateKey(for: Date())
        guard state.lastPrunedDate != today else {
            return
        }

        let cutoffKey = WorkflowStorage.dateKey(for: WorkflowStorage.retentionCutoffDate())
        let expiredDates = state.hashByDate.keys
            .filter { $0 < cutoffKey }
            .sorted()

        guard !expiredDates.isEmpty else {
            state.lastPrunedDate = today
            return
        }

        let result = try await database.modifyRecords(
            saving: [],
            deleting: expiredDates.map { recordID(deviceId: deviceId, date: $0) },
            savePolicy: .changedKeys,
            atomically: false
        )

        let allDeleted = expiredDates.allSatisfy { date in
            let recordID = recordID(deviceId: deviceId, date: date)
            return Self.isSuccessfulDeleteResult(result.deleteResults[recordID])
        }

        if allDeleted {
            for date in expiredDates {
                state.hashByDate.removeValue(forKey: date)
            }
            state.lastPrunedDate = today
        }
    }

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
        let recordID = accountSaltRecordID
        if let salt = try await fetchAccountSalt(recordID) {
            return salt
        }

        return try await createAccountSalt(recordID)
    }

    func fetchAccountSalt(_ recordID: CKRecord.ID) async throws -> Data? {
        let result = try await database.records(for: [recordID])
        return Self.accountSalt(from: result[recordID])
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
            if case .success = saveResult.saveResults[recordID] {
                return salt
            }
        } catch let error as CKError where error.code == .serverRecordChanged || error.code == .constraintViolation {
            if let salt = try await fetchAccountSalt(recordID) {
                return salt
            }
        }

        throw WorkflowSyncError.missingAccountSalt
    }

    func ensureSyncZoneExists() async throws {
        guard try await syncZoneExists() == false else {
            return
        }

        let zone = CKRecordZone(zoneID: syncZoneID)
        let result = try await database.modifyRecordZones(saving: [zone], deleting: [])

        if case let .failure(error) = result.saveResults[syncZoneID] {
            throw error
        }
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
        record[FieldKeys.projectCounts] = Self.projectCountsData(aggregate.projectCounts) as CKRecordValue
        record[FieldKeys.updatedAt] = Date() as CKRecordValue
    }

    func recordID(deviceId: String, date: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(deviceId: deviceId, date: date), zoneID: syncZoneID)
    }

    func recordName(deviceId: String, date: String) -> String {
        "\(deviceId)_\(date)"
    }

    func cacheID(fromRecordName recordName: String) -> String? {
        guard let separatorIndex = recordName.lastIndex(of: "_") else {
            return nil
        }

        let deviceId = String(recordName[..<separatorIndex])
        let date = String(recordName[recordName.index(after: separatorIndex)...])
        guard WorkflowStorage.isValidDateKey(date), !deviceId.isEmpty else {
            return nil
        }

        return WorkflowSyncedDailyRecord.id(deviceId: deviceId, date: date)
    }

    func hash(for aggregate: WorkflowSyncedDailyAggregate) throws -> String {
        let digest = try SHA256.hash(data: aggregate.jsonLineData())
        return Self.hexString(Data(digest))
    }

    nonisolated static func postSyncDidStart() {
        postSyncNotification(.workflowSyncDidStart)
    }

    nonisolated static func postSyncDidFinish(
        didSucceed: Bool,
        failureMessage: String?
    ) {
        postSyncNotification(.workflowSyncDidFinish) {
            finishNotificationUserInfo(
                didSucceed: didSucceed,
                failureMessage: failureMessage
            )
        }
    }

    @MainActor
    static func finishNotificationUserInfo(
        didSucceed: Bool,
        failureMessage: String?
    ) -> [String: Any] {
        var userInfo: [String: Any] = [
            WorkflowSyncNotificationKey.didSucceed: didSucceed
        ]
        if let failureMessage {
            userInfo[WorkflowSyncNotificationKey.failureMessage] = failureMessage
        }
        return userInfo
    }

    nonisolated static func postSyncNotification(
        _ name: Notification.Name,
        userInfo: @escaping @MainActor () -> [String: Any]? = { nil }
    ) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: name,
                object: nil,
                userInfo: userInfo()
            )
        }
    }
}

private extension WorkflowSyncService {
    func loadState() -> WorkflowSyncState {
        guard let data = try? Data(contentsOf: stateURL), !data.isEmpty,
              let state = try? JSONDecoder().decode(WorkflowSyncState.self, from: data) else {
            return WorkflowSyncState()
        }
        guard state.schema == WorkflowSyncState.currentSchema else {
            return WorkflowSyncState()
        }
        return state
    }

    func saveState(_ state: WorkflowSyncState) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    func loadCachedRecords() -> [WorkflowSyncedDailyRecord] {
        guard let data = try? Data(contentsOf: cacheURL), !data.isEmpty else {
            return []
        }

        return JSONLines.decode(from: data)
    }

    func saveCachedRecords(_ records: [WorkflowSyncedDailyRecord]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try records
            .sorted { lhs, rhs in
                if lhs.deviceId == rhs.deviceId {
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
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
        try data.write(to: cursorURL, options: .atomic)
    }
}

private extension WorkflowSyncService {
    static func remoteDailyRecords(
        from matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
    ) -> [WorkflowSyncedDailyRecord] {
        matchResults.compactMap { _, result in
            guard case let .success(record) = result else {
                return nil
            }

            return remoteDailyRecord(from: record)
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
            projectCounts: projectCounts(from: record[FieldKeys.projectCounts])
        )

        return WorkflowSyncedDailyRecord(
            deviceId: deviceId,
            daily: aggregate,
            updatedAt: record[FieldKeys.updatedAt] as? Date ?? record.modificationDate
        )
    }

    static func accountSalt(from result: Result<CKRecord, Error>?) -> Data? {
        guard case let .success(record) = result,
              let salt = record[FieldKeys.salt] as? Data,
              salt.count == Metrics.saltByteCount else {
            return nil
        }

        return salt
    }

    static func filteredRetained(
        records: [WorkflowSyncedDailyRecord],
        excluding currentDeviceId: String? = nil
    ) -> [WorkflowSyncedDailyRecord] {
        let cutoffKey = WorkflowStorage.dateKey(for: WorkflowStorage.retentionCutoffDate())
        return records.filter { record in
            guard record.date >= cutoffKey else {
                return false
            }

            return currentDeviceId.map { record.deviceId != $0 } ?? true
        }
    }

    static func recordsByID(
        records: [WorkflowSyncedDailyRecord],
        excluding currentDeviceId: String? = nil
    ) -> [String: WorkflowSyncedDailyRecord] {
        filteredRetained(records: records, excluding: currentDeviceId)
            .reduce(into: [String: WorkflowSyncedDailyRecord]()) { result, record in
                result[record.id] = record
            }
    }

    static func isSuccessfulDeleteResult(_ result: Result<Void, Error>?) -> Bool {
        switch result {
        case .success:
            true
        case let .failure(error as CKError) where error.code == .unknownItem:
            true
        case .failure, .none:
            false
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

    static func projectCounts(from value: CKRecordValue?) -> [String: Int] {
        guard let data = value as? Data,
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return counts
    }

    static func projectCountsData(_ counts: [String: Int]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(counts)) ?? Data("{}".utf8)
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

nonisolated struct WorkflowSyncSnapshot: Equatable {
    let currentDeviceId: String?
    let records: [WorkflowSyncedDailyRecord]

    static let disabled = WorkflowSyncSnapshot(currentDeviceId: nil, records: [])
}

private nonisolated struct WorkflowSyncState: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int
    var deviceId: String?
    var hashByDate: [String: String]
    var lastUploadAt: Date?
    var lastPrunedDate: String?

    init(
        schema: Int = Self.currentSchema,
        deviceId: String? = nil,
        hashByDate: [String: String] = [:],
        lastUploadAt: Date? = nil,
        lastPrunedDate: String? = nil
    ) {
        self.schema = schema
        self.deviceId = deviceId
        self.hashByDate = hashByDate
        self.lastUploadAt = lastUploadAt
        self.lastPrunedDate = lastPrunedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        hashByDate = try container.decodeIfPresent([String: String].self, forKey: .hashByDate)
            ?? [:]
        lastUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastUploadAt)
        lastPrunedDate = try container.decodeIfPresent(String.self, forKey: .lastPrunedDate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encodeIfPresent(deviceId, forKey: .deviceId)
        try container.encode(hashByDate, forKey: .hashByDate)
        try container.encodeIfPresent(lastUploadAt, forKey: .lastUploadAt)
        try container.encodeIfPresent(lastPrunedDate, forKey: .lastPrunedDate)
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case deviceId
        case hashByDate
        case lastUploadAt
        case lastPrunedDate
    }
}

private nonisolated enum WorkflowSyncError: Error {
    case missingAccountSalt
    case missingIOPlatformUUID
    case randomSaltFailed
}
