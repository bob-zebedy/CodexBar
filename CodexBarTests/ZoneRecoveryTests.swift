import CloudKit
import Foundation
import Synchronization
import Testing

struct ZoneRecoveryTests {
    private static let zone = CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)

    @Test(arguments: [CKError.Code.zoneNotFound, .userDeletedZone, .unknownItem], [false, true])
    func absentZoneIsCreatedAndLocalDataIsUploaded(code: CKError.Code, wrapped: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        await database.removeZone(code: code, wrapped: wrapped)
        _ = try directory.write("invalid activity cache", to: "Activity/cache.json")
        _ = try directory.write("invalid token cache", to: "Tokens/cache.json")
        let service = service(database, directory)
        let snapshot = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(snapshot.currentDeviceID != nil)
        #expect(await database.creations == 1)
        #expect(await database.recordCount("Activity") == 1)
        #expect(await database.recordCount("Tokens") == 1)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState().hashByDate.count == 1)
    }

    @Test(arguments: [ZoneDatabase.Point.metadata, .query, .changes, .activityUpload, .tokenUpload], [false, true])
    private func deletionDuringSyncResetsBothPipelinesAndRetries(point: ZoneDatabase.Point, wrapped: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        let service = service(database, directory)
        _ = await service.synchronizeIfEnabled(localAggregates: [aggregate(0), aggregate(1)], localTokenTurns: [turn(0), turn(1)], trigger: .manual)
        let previousID = ActivitySyncStore(directoryURL: directory.url).loadState().deviceID
        // 保留 salt 可以验证恢复不依赖设备 ID 碰巧变化
        await database.failOnce(at: point, wrapped: wrapped, preservingSalt: true)
        let snapshot = await service.synchronizeIfEnabled(localAggregates: [aggregate(0, events: 3)], localTokenTurns: [turn(0, tokens: 3)], trigger: .manual)
        #expect(snapshot.currentDeviceID == previousID)
        #expect(await database.creations == 1)
        #expect(await database.recordCount("Activity") == 1)
        #expect(await database.recordCount("Tokens") == 1)
        #expect(snapshot.records.count == 1)
        #expect(try cachedTokenCount(directory) == 1)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState().hashByDate.count == 1)
    }

    @Test func peerRecreatingSameZoneInvalidatesCachedIdentityAndUploadHashes() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        let service = service(database, directory)
        let first = await service.synchronizeIfEnabled(localAggregates: [aggregate(0), aggregate(1)], localTokenTurns: [turn(0), turn(1)], trigger: .manual)
        await database.recreateByPeer()
        let second = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(first.currentDeviceID != second.currentDeviceID)
        #expect(second.currentDeviceID != nil)
        #expect(await database.creations == 0)
        #expect(await database.recordCount("Activity") == 1)
        #expect(await database.recordCount("Tokens") == 1)
        #expect(second.records.count == 1)
        #expect(try cachedTokenCount(directory) == 1)
    }

    @Test(arguments: [nil, "iCloud.app.zabrian.codexbar"] as [String?])
    func switchingContainerDiscardsOldSyncState(containerIdentifier: String?) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        let first = service(database, directory)
        _ = await first.synchronizeIfEnabled(localAggregates: [aggregate(0), aggregate(1)], localTokenTurns: [turn(0), turn(1)], trigger: .manual)
        let store = ActivitySyncStore(directoryURL: directory.url)
        var state = store.loadState()
        state.containerIdentifier = containerIdentifier
        try store.saveState(state)

        // 新容器已有 zone 时也必须重新上传并移除旧容器缓存
        let nextDatabase = ZoneDatabase()
        let next = service(nextDatabase, directory)
        let snapshot = await next.snapshotFromCacheIfEnabled()
        #expect(snapshot.currentDeviceID == nil)
        #expect(snapshot.records.isEmpty)
        #expect(await next.tokenRecoveryBaselineIfEnabled() == nil)
        #expect(store.loadState().hashByDate.isEmpty)
        let synced = await next.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(synced.currentDeviceID != nil)
        #expect(synced.records.count == 1)
        #expect(try cachedTokenCount(directory) == 1)
        #expect(await nextDatabase.recordCount("Activity") == 1)
        #expect(await nextDatabase.recordCount("Tokens") == 1)
        #expect(store.loadState().containerIdentifier == SyncCloudKit.containerIdentifier)
    }

    @Test func repeatedDeletionHasBoundedRecoveryAndCanRecoverOnNextRun() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        await database.failOnce(at: .query, repeats: true)
        let service = service(database, directory)
        let failed = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(await database.queryCount == 2)
        #expect(await database.creations == 1)
        #expect(failed.currentDeviceID == nil)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState().hashByDate.isEmpty)
        await database.repair()
        let recovered = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(recovered.currentDeviceID != nil)
        #expect(await database.creations == 2)
        #expect(await database.recordCount("Activity") == 1)
        #expect(await database.recordCount("Tokens") == 1)
    }

    @Test(arguments: [CKError.Code.networkFailure, .notAuthenticated, .permissionFailure, .quotaExceeded])
    func unrelatedFailuresDoNotResetZoneOrSyncedState(code: CKError.Code) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        let service = service(database, directory)
        _ = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        let before = ActivitySyncStore(directoryURL: directory.url).loadState()
        let tokens = try Data(contentsOf: directory.url.appendingPathComponent("Tokens/cache.json"))
        await database.rejectQueries(code)
        _ = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(await database.creations == 0)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState() == before)
        #expect(try Data(contentsOf: directory.url.appendingPathComponent("Tokens/cache.json")) == tokens)
    }

    @Test func switchingSyncOffDuringFailurePreventsZoneCreation() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let enabled = Mutex(true)
        let database = ZoneDatabase(onFailure: { enabled.withLock { $0 = false } })
        await database.removeZone()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { enabled.withLock { $0 } })
        _ = await service.synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(await database.creations == 0)
        #expect(await database.recordCount("Metadata") == 0)
    }

    @Test func interruptedCacheResetRemainsRecoverableAfterRestart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = ZoneDatabase()
        await database.removeZone()
        let store = ActivitySyncStore(directoryURL: directory.url)
        try store.saveState(SyncState(deviceID: "stale", hashByDate: [aggregate(0).date: "stale"]))
        let blocked = directory.url.appendingPathComponent("Tokens/store.lock")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        _ = await service(database, directory).synchronizeIfEnabled(localAggregates: [aggregate(0)], trigger: .manual)
        #expect(store.loadState().deviceID == nil)
        #expect(store.loadState().hashByDate.isEmpty)
        #expect(await database.creations == 0)
        try FileManager.default.removeItem(at: blocked)
        let snapshot = await service(database, directory).synchronizeIfEnabled(localAggregates: [aggregate(0)], localTokenTurns: [turn(0)], trigger: .manual)
        #expect(snapshot.currentDeviceID != nil)
        #expect(await database.creations == 1)
        #expect(await database.recordCount("Activity") == 1)
    }

    @Test func zoneClassificationKeepsRecordAndZoneErrorsSeparate() {
        let item = CKRecord.ID(recordName: "missing", zoneID: Self.zone)
        let other = CKRecordZone.ID(zoneName: "another")
        func partial(_ key: AnyHashable, _ code: CKError.Code) -> CKError {
            CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [key: CKError(code)]])
        }
        #expect(!SyncRecovery.isMissingZone(CKError(.unknownItem), zoneID: Self.zone))
        #expect(SyncRecovery.isMissingZone(CKError(.unknownItem), zoneID: Self.zone, queryingZone: true))
        #expect(!SyncRecovery.isMissingZone(partial(item, .unknownItem), zoneID: Self.zone, queryingZone: true))
        #expect(!SyncRecovery.isMissingZone(partial(other, .userDeletedZone), zoneID: Self.zone))
        #expect(SyncRecovery.isMissingZone(partial(item, .userDeletedZone), zoneID: Self.zone))
        #expect(!SyncRecovery.isMissingZone(CKError(.changeTokenExpired), zoneID: Self.zone))
    }

    private func service(_ database: ZoneDatabase, _ directory: TestDirectory) -> SyncService {
        SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
    }

    private func aggregate(_ index: Int, events: Int = 1) -> ActivityAggregate {
        var value = ActivityAggregate(date: HistoryStorage.dateKey(for: Date().addingTimeInterval(Double(-index) * 86400)), generationID: "source", generationStartedEmpty: true)
        value.eventCount = events
        return value
    }

    private func turn(_ index: Int, tokens: Int = 1) -> TokenTurn {
        let id = TokenTurn.identifier(thread: "test", turn: String(index))
        let now = Date().addingTimeInterval(Double(-index) * 86400)
        let usage = TokenUsage(
            inputTokens: Int64(tokens), cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: Int64(tokens)
        )
        return TokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now, usage: usage)
    }

    private func cachedTokenCount(_ directory: TestDirectory) throws -> Int {
        let data = try Data(contentsOf: directory.url.appendingPathComponent("Tokens/cache.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["turns"] as? [String: Any]).count
    }
}

private actor ZoneDatabase: SyncDatabase {
    enum Point: Sendable { case metadata, query, changes, activityUpload, tokenUpload }
    private var exists = true
    private var stored: [CKRecord.ID: CKRecord] = [:]
    private var missingCode = CKError.Code.userDeletedZone
    private var wrapped = false
    private var failurePoint: Point?
    private var repeats = false
    private var savedMetadata: CKRecord?
    private var preservesSalt = false
    private var queryError: CKError.Code?
    private let onFailure: @Sendable () -> Void
    private(set) var creations = 0
    private(set) var queryCount = 0

    init(onFailure: @escaping @Sendable () -> Void = {}) {
        self.onFailure = onFailure
    }

    func recordCount(_ type: String) -> Int {
        stored.values.filter { $0.recordType == type }.count
    }

    func removeZone(code: CKError.Code = .userDeletedZone, wrapped: Bool = false) {
        exists = false
        stored = [:]
        missingCode = code
        self.wrapped = wrapped
    }

    func failOnce(at point: Point, wrapped: Bool = false, preservingSalt: Bool = false, repeats: Bool = false) {
        failurePoint = point
        self.wrapped = wrapped
        preservesSalt = preservingSalt
        self.repeats = repeats
    }

    func repair() {
        failurePoint = nil
    }

    func rejectQueries(_ code: CKError.Code) {
        queryError = code
    }

    func recreateByPeer() {
        let metadata = stored.values.first { $0.recordType == "Metadata" }?.copy() as? CKRecord
        stored = [:]
        metadata?["salt"] = Data(repeating: 7, count: 32) as CKRecordValue
        if let metadata {
            stored[metadata.recordID] = metadata
        }
    }

    private func check(_ point: Point?, zone: CKRecordZone.ID, record: CKRecord.ID? = nil) throws {
        if let point, failurePoint == point {
            savedMetadata = preservesSalt ? stored.values.first { $0.recordType == "Metadata" } : nil
            stored = [:]
            exists = false
            if !repeats {
                failurePoint = nil
            }
        }
        guard !exists else { return }
        onFailure()
        let error = CKError(missingCode)
        if wrapped {
            let key: AnyHashable = record.map(AnyHashable.init) ?? AnyHashable(zone)
            throw CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [key: error]])
        }
        throw error
    }

    func recordZone(for id: CKRecordZone.ID) async throws -> CKRecordZone {
        try check(nil, zone: id)
        return CKRecordZone(zoneID: id)
    }

    func modifyRecordZones(saving zones: [CKRecordZone], deleting _: [CKRecordZone.ID]) async throws -> ZoneModification {
        creations += 1
        exists = true
        if let savedMetadata {
            stored[savedMetadata.recordID] = savedMetadata
        }
        return (Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, .success($0)) }), [:])
    }

    func records(for ids: [CKRecord.ID], desiredKeys _: [CKRecord.FieldKey]?) async throws -> Records {
        if let id = ids.first {
            try check(id.recordName == "accountSalt" ? .metadata : nil, zone: id.zoneID, record: id)
        }
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, stored[id].map { .success(copy($0)) } ?? .failure(CKError(.unknownItem)))
        })
    }

    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID], savePolicy _: CKModifyRecordsOperation.RecordSavePolicy, atomically _: Bool) async throws -> Modification {
        if let record = records.first {
            let point: Point? = record.recordType == "Activity" ? .activityUpload : record.recordType == "Tokens" ? .tokenUpload : nil
            try check(point, zone: record.recordID.zoneID, record: record.recordID)
        }
        for record in records {
            stored[record.recordID] = copy(record)
        }
        for id in ids {
            try check(nil, zone: id.zoneID, record: id)
            stored[id] = nil
        }
        return (Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success(copy($0))) }), Dictionary(uniqueKeysWithValues: ids.map { ($0, .success(())) }))
    }

    func records(matching query: CKQuery, inZoneWith zone: CKRecordZone.ID?, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        queryCount += 1
        if let queryError {
            throw CKError(queryError)
        }
        try check(.query, zone: zone ?? CKRecordZone.default().zoneID)
        return (stored.values.filter { $0.recordType == query.recordType }.map { ($0.recordID, .success(copy($0))) }, nil)
    }

    func records(continuingMatchFrom _: CKQueryOperation.Cursor, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        ([], nil)
    }

    func fetchChanges(inZoneWith zone: CKRecordZone.ID, since _: CKServerChangeToken?, resultsLimit _: Int) async throws -> SyncChanges {
        try check(.changes, zone: zone)
        return SyncChanges(records: stored.mapValues { .success(copy($0)) }, deletions: [], token: nil, moreComing: false)
    }

    private func copy(_ record: CKRecord) -> CKRecord {
        record.copy() as? CKRecord ?? record
    }
}
