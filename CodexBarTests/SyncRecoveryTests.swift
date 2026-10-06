import CloudKit
import Foundation
import Testing

struct SyncRecoveryTests {
    private static let zone = CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)
    private static let salt = Data(repeating: 1, count: 32)

    @Test func damagedActivityCursorRebuildsWithoutBlockingTokens() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await service.synchronizeIfEnabled(localAggregates: [], trigger: .manual)
        let url = directory.url.appendingPathComponent("Activity/cache.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("broken cursor".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let queriesBefore = await database.queryCount
        _ = await service.synchronizeIfEnabled(localAggregates: [], localTokenTurns: [Self.turn(0)], trigger: .manual)
        #expect(await database.queryCount > queriesBefore)
        #expect(await database.savedTypes.contains(TokenSync.recordType))
        #expect(try ActivitySyncStore(directoryURL: directory.url).load().cursor == nil)
    }

    @Test(arguments: [false, true]) func damagedTokenCacheOrCursorRebuilds(cursorOnly: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        let url = directory.url.appendingPathComponent("cache.json")
        if cursorOnly {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["cursor"] = Data("broken cursor".utf8).base64EncodedString()
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        } else {
            try Data("broken cache".utf8).write(to: url)
        }
        let reopened = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await reopened.synchronize(local: [], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        #expect(try Self.cachedTurnCount(in: directory.url) == 1)
    }

    @Test func failedTokenRebuildPreservesOriginalBytes() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data("broken cache".utf8)
        let url = try directory.write(original, to: "cache.json")
        let database = SyncDatabaseFixture(changesFail: true)
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [false, true]) func activityFailureOnlyStopsTokensForSharedErrors(shared: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture(queryError: shared ? .networkFailure : .invalidArguments)
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await service.synchronizeIfEnabled(localAggregates: [], localTokenTurns: [Self.turn(0)], trigger: .manual)
        #expect(await database.savedTypes.contains(TokenSync.recordType) == !shared)
    }

    @Test(arguments: [false, true]) func partialTokenBatchContinuesAndRetainsSuccesses(readFailure: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let turns = (0 ..< 30).map(Self.turn)
        let badID = turns[0].pseudonymized(salt: Self.salt).id
        let database = SyncDatabaseFixture(failingName: badID, readFailure: readFailure)
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: turns, accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        }
        #expect(await database.savedTypes.filter { $0 == TokenSync.recordType }.count == 29)
        #expect(try Self.cachedTurnCount(in: directory.url) == 29)
        await database.repair()
        try await service.synchronize(local: turns, accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        #expect(await database.savedTypes.filter { $0 == TokenSync.recordType }.count == 30)
    }

    @Test func partialActivityBatchConfirmsSuccessesAndContinuesLaterDates() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let dates = (0 ..< 30).map { HistoryStorage.dateKey(for: Date().addingTimeInterval(Double(-$0) * 86400)) }
        let aggregates = dates.map { date in
            var value = ActivityAggregate(date: date, generationID: "source", generationStartedEmpty: true)
            value.eventCount = 1
            return value
        }
        let database = SyncDatabaseFixture(failingDate: dates[0])
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await service.synchronizeIfEnabled(localAggregates: aggregates, localTokenTurns: [Self.turn(0)], trigger: .manual)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState().hashByDate.count == 29)
        #expect(await database.savedTypes.filter { $0 == "Activity" }.count == 29)
        #expect(await database.savedTypes.contains(TokenSync.recordType))
    }

    @Test func failedRecordDuringFetchDoesNotCommitPartialCache() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        let url = directory.url.appendingPathComponent("cache.json")
        let original = try Data(contentsOf: url)
        await database.failChangesRecord()
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [Self.turn(1)], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func unsupportedTokenVersionIsNotTreatedAsCorruption() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        let url = directory.url.appendingPathComponent("cache.json")
        let original = Data(#"{"version":999,"futureField":"unsupported"}"#.utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func activityCacheCommitsRecordsAndCursorTogether() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivitySyncStore(directoryURL: directory.url)
        let state = SyncState(deviceID: "device", hashByDate: ["2026-10-05": "hash"])
        try store.saveState(state)
        let url = directory.url.appendingPathComponent("Activity/cache.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("previous cursor".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var updated = state
        updated.replacementDates = ["2026-10-05"]
        try store.saveState(updated)
        #expect(try store.load().cursor == Data("previous cursor".utf8))
        let daily = SyncedActivity(date: "2026-10-05", generationID: "source", eventCount: 2, projectCounts: [:], modelCounts: [:])
        let record = try ActivitySyncRecord(deviceID: "device", daily: daily, recordName: "device_2026-10-05_source")
        try store.saveFetchedRecords([record], cursor: nil)
        let reopened = try ActivitySyncStore(directoryURL: directory.url).load()
        #expect(reopened.state == updated)
        #expect(reopened.records == [record])
        #expect(reopened.cursor == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(Set(files) == ["cache.json", "store.lock"])
        try store.reset(state: SyncState())
        #expect(try store.load() == ActivitySyncCache())
    }

    @Test(arguments: ["missingFields", "missingGeneration", "mismatchedIdentity"])
    func damagedActivityRecordsInvalidateCursorAndUploadState(_ damage: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivitySyncStore(directoryURL: directory.url)
        try store.saveState(SyncState(deviceID: "device", hashByDate: ["2026-10-05": "hash"]))
        let url = directory.url.appendingPathComponent("Activity/cache.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("stale cursor".utf8).base64EncodedString()
        let daily: [String: Any] = damage == "missingGeneration"
            ? ["date": "2026-10-05"] : ["date": "2026-10-05", "generationID": "source"]
        json["records"] = damage == "missingFields" ? [["invalid": true]] : [[
            "deviceID": "device", "recordName": "device_2026-10-05_other", "daily": daily
        ]]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try store.load() == ActivitySyncCache())
        try store.saveState(SyncState(deviceID: "new"))
        #expect(try store.load().records.isEmpty)
        #expect(try store.load().cursor == nil)
        #expect(try store.load().state.deviceID == "new")
    }

    @Test func unsupportedActivityCacheIsNotOverwritten() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data(#"{"version":999,"futureField":"unsupported"}"#.utf8)
        let url = try directory.write(original, to: "Activity/cache.json")
        let store = ActivitySyncStore(directoryURL: directory.url)
        #expect(throws: SyncRecovery.Failure.self) { try store.saveState(SyncState()) }
        #expect(throws: SyncRecovery.Failure.self) { try store.reset(state: SyncState()) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func failedActivitySavePreservesCacheAndCursor() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivitySyncStore(directoryURL: directory.url)
        try store.saveState(SyncState(deviceID: "device"))
        let url = directory.url.appendingPathComponent("Activity/cache.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("previous cursor".utf8).base64EncodedString()
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: url)
        let daily = SyncedActivity(date: "2026-10-05", generationID: "source", eventCount: 2, projectCounts: [:], modelCounts: [:])
        let record = try ActivitySyncRecord(deviceID: "device", daily: daily, updatedAt: Date(timeIntervalSince1970: .infinity), recordName: "device_2026-10-05_source")
        #expect(throws: EncodingError.self) {
            try store.saveFetchedRecords([record], cursor: nil)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func activityUsesOneIdentityAndPreservesMoreCompleteRemoteCounts() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        var local = ActivityAggregate(date: HistoryStorage.dateKey(for: Date()), generationID: "source", generationStartedEmpty: true)
        local.eventCount = 5
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        let records = await database.activityRecords()
        let remote = try #require(records.first)
        let deviceID = try #require(remote["deviceID"] as? String)
        let identity = "\(deviceID)_\(local.date)_source"
        #expect(records.count == 1)
        #expect(remote.recordID.recordName == identity)
        #expect(await database.requestedIDs.filter { $0.recordName != "accountSalt" }.map(\.recordName) == [identity])

        local.eventCount = 2
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(await database.activityRecords().first?["eventCount"] as? Int == 5)
    }

    @Test func missingLocalGenerationFailsBeforeReplacingRemoteRecords() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        var local = ActivityAggregate(date: HistoryStorage.dateKey(for: Date()), generationID: "source", generationStartedEmpty: true)
        local.eventCount = 5
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        let before = await database.activityRecords().map(\.recordID)
        try await service.markReplacementNeeded(for: [local.date])
        local.generationID = nil
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(await database.deletedIDs.isEmpty)
        #expect(await database.activityRecords().map(\.recordID) == before)
        #expect(await service.hasPendingReplacement(for: [local.date]))
    }

    @Test func invalidGenerationDuringCursorBaselineStopsActivityUpload() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let invalid = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "device_invalid"))
        invalid["deviceID"] = "device" as CKRecordValue
        invalid["date"] = HistoryStorage.dateKey(for: Date()) as CKRecordValue
        await database.injectChangesRecord(invalid)
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        var local = ActivityAggregate(date: HistoryStorage.dateKey(for: Date()), generationID: "source", generationStartedEmpty: true)
        local.eventCount = 1
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(await database.activityRecords().isEmpty)
        #expect(try ActivitySyncStore(directoryURL: directory.url).load().cursor == nil)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState().hashByDate.isEmpty)
    }

    @Test func replacingHistoryDeletesEveryPreviousGeneration() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        var local = ActivityAggregate(date: HistoryStorage.dateKey(for: Date()), generationID: "first", generationStartedEmpty: true)
        local.eventCount = 1
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        local.generationID = "second"
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        let previous = await Set(database.activityRecords().map(\.recordID))
        #expect(previous.count == 2)
        local.generationID = "rebuilt"
        local.generationStartedEmpty = false
        try await service.markReplacementNeeded(for: [local.date])
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        let current = await database.activityRecords()
        #expect(current.count == 1)
        #expect(current.first?["generationID"] as? String == "rebuilt")
        #expect(await previous.isSubset(of: Set(database.deletedIDs)))
        #expect(await !service.hasPendingReplacement(for: [local.date]))
    }

    private static func cachedTurnCount(in directory: URL) throws -> Int {
        let data = try Data(contentsOf: directory.appendingPathComponent("cache.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["turns"] as? [String: Any]).count
    }

    private static func turn(_ index: Int) -> TokenTurn {
        let id = TokenTurn.identifier(thread: "test", turn: String(index))
        let now = Date().addingTimeInterval(Double(-index))
        return TokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now, usage: .zero)
    }
}

private actor SyncDatabaseFixture: SyncDatabase {
    private var stored: [CKRecord.ID: CKRecord] = [:]
    private let queryError: CKError.Code?
    private let changesFail: Bool
    private var changesRecordFails = false
    private var failingName: String?
    private let failingDate: String?
    private let readFailure: Bool
    private(set) var queryCount = 0
    private(set) var savedTypes: [String] = []
    private(set) var requestedIDs: [CKRecord.ID] = []
    private(set) var deletedIDs: [CKRecord.ID] = []
    private var changesRecord: CKRecord?

    func activityRecords() -> [CKRecord] {
        stored.values.filter { $0.recordType == "Activity" }.map(Self.copy)
    }

    func injectChangesRecord(_ record: CKRecord) {
        changesRecord = Self.copy(record)
    }

    init(queryError: CKError.Code? = nil, changesFail: Bool = false, failingName: String? = nil, failingDate: String? = nil, readFailure: Bool = false) {
        self.queryError = queryError
        self.changesFail = changesFail
        self.failingName = failingName
        self.failingDate = failingDate
        self.readFailure = readFailure
    }

    private nonisolated static func copy(_ record: CKRecord) -> CKRecord {
        record.copy() as? CKRecord ?? record
    }

    func failChangesRecord() {
        changesRecordFails = true
    }

    func repair() {
        failingName = nil
    }

    func records(for ids: [CKRecord.ID], desiredKeys _: [CKRecord.FieldKey]?) async throws -> Records {
        requestedIDs.append(contentsOf: ids)
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            if readFailure, id.recordName == failingName {
                return (id, .failure(CKError(.constraintViolation)))
            }
            return (id, stored[id].map { .success(Self.copy($0)) } ?? .failure(CKError(.unknownItem)))
        })
    }

    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID], savePolicy _: CKModifyRecordsOperation.RecordSavePolicy, atomically _: Bool) async throws -> Modification {
        var saved: Records = [:]
        for record in records {
            if record.recordID.recordName == failingName || (failingDate != nil && record["date"] as? String == failingDate) {
                saved[record.recordID] = .failure(CKError(.constraintViolation))
            } else {
                stored[record.recordID] = record.copy() as? CKRecord
                saved[record.recordID] = .success(record)
                savedTypes.append(record.recordType)
            }
        }
        deletedIDs.append(contentsOf: ids)
        for id in ids {
            stored[id] = nil
        }
        return (saved, Dictionary(uniqueKeysWithValues: ids.map { ($0, .success(())) }))
    }

    func records(matching query: CKQuery, inZoneWith _: CKRecordZone.ID?, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        queryCount += 1
        if let queryError {
            throw CKError(queryError)
        }
        return (stored.values.filter { $0.recordType == query.recordType }.map { ($0.recordID, .success(Self.copy($0))) }, nil)
    }

    func records(continuingMatchFrom _: CKQueryOperation.Cursor, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        ([], nil)
    }

    func recordZone(for id: CKRecordZone.ID) async throws -> CKRecordZone {
        CKRecordZone(zoneID: id)
    }

    func modifyRecordZones(saving zones: [CKRecordZone], deleting _: [CKRecordZone.ID]) async throws -> ZoneModification {
        (Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, .success($0)) }), [:])
    }

    func fetchChanges(inZoneWith _: CKRecordZone.ID, since _: CKServerChangeToken?, resultsLimit _: Int) async throws -> SyncChanges {
        if changesFail {
            throw CKError(.networkFailure)
        }
        var records = stored.mapValues { Result<CKRecord, Error>.success(Self.copy($0)) }
        if let changesRecord {
            records[changesRecord.recordID] = .success(Self.copy(changesRecord))
        }
        if changesRecordFails {
            records[CKRecord.ID(recordName: "failed-record")] = .failure(CKError(.constraintViolation))
        }
        return SyncChanges(records: records, deletions: [], token: nil, moreComing: false)
    }
}
