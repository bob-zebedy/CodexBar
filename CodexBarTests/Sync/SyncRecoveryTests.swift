import CloudKit
import CryptoKit
import Foundation
import Testing

struct SyncRecoveryTests {
    @Test func conflictingTokenRootCannotOverwriteRemoteOrProduceCompleteTotals() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let local = Self.turn(0)
        var remote = local.pseudonymized(salt: Self.salt)
        remote.rootID = TokenTurn.identifier(thread: "other-root", turn: "other-turn")
        let record = CKRecord(recordType: TokenSync.recordType, recordID: TokenSync.recordID(remote.id, zoneID: Self.zone))
        TokenSync.apply(remote, to: record)
        await database.storeRecord(record)
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: TokenCacheError.self) {
            try await service.synchronize(local: [local], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        }
        #expect(await database.savedTypes.isEmpty)
        let records = try await database.records(for: [record.recordID], desiredKeys: nil)
        let saved = try #require(try records[record.recordID]?.get())
        #expect(try TokenSync.turn(from: saved)?.rootID == remote.rootID)
        await #expect(throws: TokenCacheError.self) { try await service.snapshot(local: [local], accountScopedDeviceID: "device") }
    }

    @Test func expiredTokenCacheStaysBoundedWhenCloudDeletionFailsAndRetries() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let expiredAt = HistoryStorage.retentionCutoffDate().addingTimeInterval(-86400)
        var expiredIDs: [CKRecord.ID] = []
        for index in 1 ... 2 {
            var turn = Self.turn(index).pseudonymized(salt: Self.salt)
            turn.updatedAt = expiredAt
            let record = CKRecord(recordType: TokenSync.recordType, recordID: TokenSync.recordID(turn.id, zoneID: Self.zone))
            TokenSync.apply(turn, to: record)
            await database.storeRecord(record)
            expiredIDs.append(record.recordID)
        }
        await database.failNextDeletion()
        let service = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        }
        #expect(try Self.cachedTurnCount(in: directory.url) == 1)
        let reopened = TokenSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await reopened.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        #expect(try Self.cachedTurnCount(in: directory.url) == 1)
        let remaining = try await database.records(for: expiredIDs, desiredKeys: nil)
        for id in expiredIDs {
            #expect(throws: (any Error).self) { try remaining[id]?.get() }
        }
    }

    @Test func previousEncodingHashConvergesWithoutRepeatedUploads() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let date = HistoryStorage.dateKey(for: Date())
        let local = try directory.activityAggregate(date: date)
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        let store = ActivitySyncStore(directoryURL: directory.url)
        var state = store.loadState()
        let currentHash = try #require(state.hashByDate[date])
        let previousBytes = Data(("""
        {"date":"\(date)","generationID":"source","eventCount":1,"threadCount":null,"turnCount":null,"projectCounts":{},"modelCounts":{}}
        """ + "\n").utf8)
        let previousHash = TokenTurn.hexString(SHA256.hash(data: previousBytes))
        #expect(previousHash != currentHash)
        state.hashByDate[date] = previousHash
        try store.saveState(state)

        let restarted = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
        _ = await restarted.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(store.loadState().hashByDate[date] == currentHash)
        #expect(await database.activityRecords().count == 1)
        #expect(await database.activityRecords().first?["eventCount"] as? Int == 1)
        #expect(await database.deletedIDs.isEmpty)
        let writes = await database.savedTypes.count
        let reads = await database.requestedIDs.filter { $0.recordName != "accountSalt" }.count
        _ = await restarted.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(await database.savedTypes.count == writes)
        #expect(await database.requestedIDs.filter { $0.recordName != "accountSalt" }.count == reads)
    }

    private static let zone = CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)
    private static let salt = Data(repeating: 1, count: 32)

    @Test func damagedActivityCursorRebuildsWithoutBlockingTokens() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localAggregates: [], trigger: .manual)
        let url = directory.url.appendingPathComponent("Activity/cache.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("broken cursor".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let queriesBefore = await database.queryCount
        let changesBefore = await database.changesSinceNil.count
        _ = await service.synchronizeIfEnabled(localAggregates: [], localTokenTurns: [Self.turn(0)], trigger: .manual)
        #expect(await database.queryCount == queriesBefore)
        #expect(await database.changesSinceNil.count > changesBefore)
        #expect(await database.changesSinceNil[changesBefore])
        #expect(await database.savedTypes.contains(TokenSync.recordType))
        #expect(try ActivitySyncStore(directoryURL: directory.url).load().cursor == nil)
    }

    @Test(arguments: [false, true])
    func activityRebuildCommitsOnlyAfterAllPagesSucceed(failSecondPage: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localAggregates: [], trigger: .manual)
        let store = ActivitySyncStore(directoryURL: directory.url)
        let date = HistoryStorage.dateKey(for: Date())
        let daily = try directory.activityAggregate(date: date).syncedAggregate
        let generation = try #require(daily.generationID)
        let stale = try ActivitySyncRecord(deviceID: "stale", daily: daily, recordName: "stale_\(date)_\(generation)")
        try store.saveFetchedRecords([stale], cursor: nil)
        let url = directory.url.appendingPathComponent("Activity/cache.json")
        let original = try Data(contentsOf: url)
        let remote = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "remote_\(date)_\(generation)", zoneID: Self.zone))
        ActivityRecordCodec.apply(daily, deviceID: "remote", to: remote)
        remote["updatedAt"] = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) as CKRecordValue
        let deleted = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "deleted_\(date)_\(generation)", zoneID: Self.zone))
        ActivityRecordCodec.apply(daily, deviceID: "deleted", to: deleted)
        let metadata = CKRecord(recordType: "Metadata", recordID: CKRecord.ID(recordName: "ignored", zoneID: Self.zone))
        let first = SyncChanges(
            records: [remote.recordID: .success(remote), deleted.recordID: .success(deleted), metadata.recordID: .success(metadata)],
            deletions: [], token: nil, moreComing: true
        )
        let last = SyncChanges(records: [:], deletions: [(deleted.recordID, "Activity")], token: nil, moreComing: false)
        // 同步在上传前后各拉取一次, 两次都要独立得到完整结果
        await database.setChangesPages(failSecondPage
            ? [.success(first), .failure(CKError(.networkFailure))]
            : [.success(first), .success(last), .success(first), .success(last)])
        let queriesBefore = await database.queryCount
        let result = await service.synchronizeIfEnabled(localAggregates: [], trigger: .manual)
        #expect(await database.queryCount == queriesBefore)
        #expect(await database.remainingChangesPages == 0)
        if failSecondPage {
            #expect(try Data(contentsOf: url) == original)
            #expect(result.records == [stale])
        } else {
            let expected = try #require(try ActivityRecordCodec.remoteDailyRecord(from: remote))
            #expect(result.records == [expected])
            #expect(try store.load().records == [expected])
        }
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
        let database = SyncDatabaseFixture(nextChangesError: shared ? .networkFailure : .invalidArguments)
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
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
        let aggregates = try dates.map { try directory.activityAggregate(date: $0) }
        let database = SyncDatabaseFixture(failingDate: dates[0])
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
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
        updated.lastPrunedDate = "2026-10-05"
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

    @Test func sameSourceRecalculationCanReduceCountsWithoutDeletingRecord() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let before = try #require(await fixture.database.activityRecords().first)
        let result = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let after = try #require(await fixture.database.activityRecords().first)
        #expect(before.recordID == after.recordID)
        #expect(before["eventCount"] as? Int == 9)
        #expect(after["eventCount"] as? Int == 1)
        #expect(!result.summary.isSyncPending)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func missingLocalGenerationFailsBeforeReplacingRemoteRecords() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
        var local = try directory.activityAggregate(date: HistoryStorage.dateKey(for: Date()))
        local.eventCount = 5
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        let before = await database.activityRecords().map(\.recordID)
        local.generationID = nil
        let result = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(await database.deletedIDs.isEmpty)
        #expect(await database.activityRecords().map(\.recordID) == before)
        #expect(result.records.count == before.count)
    }

    @Test func invalidGenerationDuringCursorBaselineStopsActivityUpload() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let invalid = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "device_invalid"))
        invalid["deviceID"] = "device" as CKRecordValue
        invalid["date"] = HistoryStorage.dateKey(for: Date()) as CKRecordValue
        await database.injectChangesRecord(invalid)
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            activityEventsDirectoryURL: directory.url.appendingPathComponent("Events"),
            isEnabled: { true }
        )
        var local = try directory.activityAggregate(date: HistoryStorage.dateKey(for: Date()))
        local.eventCount = 1
        _ = await service.synchronizeIfEnabled(localAggregates: [local], trigger: .manual)
        #expect(await database.activityRecords().isEmpty)
        #expect(try ActivitySyncStore(directoryURL: directory.url).load().cursor == nil)
        #expect(ActivitySyncStore(directoryURL: directory.url).loadState().hashByDate.isEmpty)
    }

    @Test func independentJournalSourcesAreNotDeletedByRebuild() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let previous = try #require(await fixture.database.activityRecords().first)
        let old = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "older-source", zoneID: Self.zone))
        var independent = fixture.local.syncedAggregate
        independent.generationID = "independent"
        try ActivityRecordCodec.apply(independent, deviceID: #require(previous["deviceID"] as? String), to: old)
        await fixture.database.storeRecord(old)
        _ = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        #expect(await fixture.database.activityRecords().count == 2)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func unknownCloudVersionPreservesCacheAndPreventsActivityUpload() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let cacheURL = HistoryStorage.syncDirectoryURL(in: fixture.directory.url).appendingPathComponent("Activity/cache.json")
        let before = try Data(contentsOf: cacheURL)
        let unsupported = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "future", zoneID: Self.zone))
        unsupported["version"] = 999 as CKRecordValue
        await fixture.database.injectChangesRecord(unsupported)
        let result = await fixture.history.loadSnapshot(synchronize: true)
        #expect(!result.isActivityComplete)
        #expect(try Data(contentsOf: cacheURL) == before)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func unknownLocalSyncCacheFailsBeforeCloudMutation() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data("{\"version\":999}".utf8)
        let url = try directory.write(original, to: "Activity/cache.json")
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let result = await service.synchronizeIfEnabled(localAggregates: [], localTokenTurns: [Self.turn(0)], trigger: .manual)
        #expect(!result.isActivityComplete)
        #expect(await database.savedTypes.isEmpty)
        #expect(await database.deletedIDs.isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    private static func cachedTurnCount(in directory: URL) throws -> Int {
        let data = try Data(contentsOf: directory.appendingPathComponent("cache.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["turns"] as? [String: Any]).count
    }

    private static func turn(_ index: Int) -> TokenTurn {
        let id = TokenTurn.identifier(thread: "test", turn: String(index))
        let now = Date().addingTimeInterval(Double(-index))
        return TestFixtures.tokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now, usage: .zero)
    }
}

private actor SyncDatabaseFixture: SyncDatabase {
    private var stored: [CKRecord.ID: CKRecord] = [:]
    private var nextChangesError: CKError.Code?
    private let changesFail: Bool
    private var changesRecordFails = false
    private var changesPages: [Result<SyncChanges, Error>] = []

    private var failingName: String?
    private var failingDate: String?
    private let readFailure: Bool
    private(set) var queryCount = 0
    private(set) var changesSinceNil: [Bool] = []
    private(set) var savedTypes: [String] = []
    private(set) var requestedIDs: [CKRecord.ID] = []
    private(set) var deletedIDs: [CKRecord.ID] = []
    private var changesRecord: CKRecord?
    private var deletionFails = false
    private var activitySaveCallback: (@Sendable () -> Void)?

    var remainingChangesPages: Int {
        changesPages.count
    }

    func setChangesPages(_ pages: [Result<SyncChanges, Error>]) {
        changesPages = pages
    }

    func failNextDeletion() {
        deletionFails = true
    }

    func failActivityUpload(on date: String) {
        failingDate = date
    }

    func afterActivitySave(_ callback: @escaping @Sendable () -> Void) {
        activitySaveCallback = callback
    }

    func activityRecords() -> [CKRecord] {
        stored.values.filter { $0.recordType == "Activity" }.map(Self.copy)
    }

    func storeRecord(_ record: CKRecord) {
        stored[record.recordID] = Self.copy(record)
    }

    func injectChangesRecord(_ record: CKRecord) {
        changesRecord = Self.copy(record)
    }

    init(nextChangesError: CKError.Code? = nil, changesFail: Bool = false, failingName: String? = nil, failingDate: String? = nil, readFailure: Bool = false) {
        self.nextChangesError = nextChangesError
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
        failingDate = nil
        activitySaveCallback = nil
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

    func modifyRecords(
        saving records: [CKRecord],
        deleting ids: [CKRecord.ID],
        savePolicy _: CKModifyRecordsOperation.RecordSavePolicy,
        atomically _: Bool
    ) async throws -> Modification {
        var saved: Records = [:]
        for record in records {
            if record.recordID.recordName == failingName || (failingDate != nil && record["date"] as? String == failingDate) {
                saved[record.recordID] = .failure(CKError(.constraintViolation))
            } else {
                stored[record.recordID] = record.copy() as? CKRecord
                saved[record.recordID] = .success(record)
                savedTypes.append(record.recordType)
                if record.recordType == "Activity" {
                    activitySaveCallback?()
                }
            }
        }
        deletedIDs.append(contentsOf: ids)
        for id in ids {
            stored[id] = nil
            if deletionFails {
                deletionFails = false
                throw CKError(.networkFailure)
            }
        }
        return (saved, Dictionary(uniqueKeysWithValues: ids.map { ($0, .success(())) }))
    }

    func records(matching query: CKQuery, inZoneWith _: CKRecordZone.ID?, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        queryCount += 1
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

    func fetchChanges(inZoneWith _: CKRecordZone.ID, since token: CKServerChangeToken?, resultsLimit _: Int) async throws -> SyncChanges {
        changesSinceNil.append(token == nil)
        if !changesPages.isEmpty {
            return try changesPages.removeFirst().get()
        }
        if let error = nextChangesError {
            nextChangesError = nil
            throw CKError(error)
        }
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

extension SyncRecoveryTests {
    @Test func failedUploadPreservesRemoteAndRetriesAfterRestart() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let outcome = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        #expect(outcome.summary.isSyncPending)
        await fixture.database.failActivityUpload(on: fixture.date)
        _ = await fixture.history.loadSnapshot(synchronize: true)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
        await fixture.database.repair()
        let restarted = HistoryService(directoryURL: fixture.directory.url, syncService: fixture.sync)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 1)
        #expect(await fixture.database.activityRecords().count == 1)
    }

    @Test func repeatedRebuildKeepsSourceAndNeedsNoSeparateAcknowledgement() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        _ = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        _ = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let state = try HistoryStorage.loadMaintenanceState(in: fixture.directory.url)
        #expect(state.days[fixture.date]?.generationID == fixture.local.generationID)
        #expect(state.dirty.isEmpty)
        #expect(await fixture.database.activityRecords().count == 1)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func unavailableSourceCannotOverwriteRemoteAndRecoversAfterRepair() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let original = try Data(contentsOf: fixture.eventURL)
        try Data("broken journal\n".utf8).write(to: fixture.eventURL)
        await #expect(throws: (any Error).self) {
            try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        }
        let restarted = HistoryService(directoryURL: fixture.directory.url, syncService: fixture.sync)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
        try original.write(to: fixture.eventURL)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 1)
    }

    @Test func rewrittenPrefixCannotOverwriteRemoteEvenWithMoreEvents() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let event = TestFixtures.event(.toolStarted, at: Date(), turn: "different")
        try fixture.directory.writeJournal(AppServerEventRecord(activity: event).jsonLineData(), to: "Events/\(fixture.date).jsonl")
        _ = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func requestSaveFailureDoesNotModifyAggregateOrCloud() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let aggregateURL = HistoryStorage.dailyURL(in: fixture.directory.url)
        let original = try Data(contentsOf: aggregateURL)
        let stateDirectory = HistoryStorage.maintenanceURL(in: fixture.directory.url).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stateDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path) }
        await #expect(throws: (any Error).self) {
            try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        }
        #expect(try Data(contentsOf: aggregateURL) == original)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func disabledSyncKeepsUpdatedAggregateForNextEnabledRun() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let disabled = SyncService(database: fixture.database, directoryURL: HistoryStorage.syncDirectoryURL(in: fixture.directory.url), isEnabled: { false })
        let history = HistoryService(directoryURL: fixture.directory.url, syncService: disabled)
        _ = try await history.rebuildData(for: [fixture.date], synchronize: true)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 9)
        _ = await fixture.history.loadSnapshot(synchronize: true)
        #expect(await fixture.database.activityRecords().first?["eventCount"] as? Int == 1)
    }

    @Test func appendedEventsKeepGenerationAndExtendCheckpoint() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let recorder = ActivityRecorder(directoryURL: fixture.directory.url)
        let event = ActivityRecord(
            timestamp: Date(),
            name: ActivityEventKind.toolStarted.rawValue,
            origin: .main,
            cwd: nil,
            toolName: "exec_command",
            model: nil,
            effort: nil,
            threadID: "thread-a",
            turnID: "turn-a",
            agentID: nil,
            id: "appended-tool"
        )
        try await recorder.record(event: event)
        _ = await fixture.history.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        let remote = try #require(await fixture.database.activityRecords().first)
        #expect(remote["eventCount"] as? Int == 2)
        #expect(remote["generationID"] as? String == fixture.local.generationID)
        let updated = try #require(try ActivityRecordCodec.remoteDailyRecord(from: remote))
        #expect(try #require(updated.daily.sourceCheckpoint).byteCount > #require(fixture.local.sourceCheckpoint).byteCount)
    }

    @Test func partialTokenFailureIsReportedWithoutClaimingWholeDaySuccess() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        let now = Date()
        let goodID = TokenTurn.identifier(thread: "good", turn: "summary")
        let badID = TokenTurn.identifier(thread: "bad", turn: "summary")
        let good = TokenObservation(
            turn: TokenTurn(id: goodID, rootID: goodID, startedAt: now, updatedAt: now), rootStartedAt: now,
            streamID: "good", sequence: 1, previous: .zero, current: .zero
        )
        let bad = TokenObservation(
            turn: TokenTurn(id: badID, rootID: badID, startedAt: now, updatedAt: now), rootStartedAt: now,
            streamID: "bad", sequence: 2, previous: .zero, current: .zero
        )
        let handle = try FileHandle(forWritingTo: fixture.eventURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: AppServerEventRecord(observation: good, recordedAt: now).jsonLineData())
        try handle.write(contentsOf: AppServerEventRecord(observation: bad, recordedAt: now).jsonLineData())
        try handle.close()
        let result = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        #expect(result.summary.rebuiltDateCount == 0)
        #expect(result.summary.eventCount == 1)
        #expect(result.summary.tokenTurnCount == 1)
        #expect(result.summary.failedTokenDateKeys == [fixture.date])
        #expect(result.summary.didFailTokenRebuild)
        #expect(result.summary.failedDateKeys.isEmpty)
        #expect(result.summary.failedRequestDateKeys.isEmpty)
    }
}

private struct HistoryRebuildFixture {
    let directory: TestDirectory
    let database: SyncDatabaseFixture
    let sync: SyncService
    let history: HistoryService
    let date: String
    let eventURL: URL
    let local: ActivityAggregate

    init() async throws {
        directory = try TestDirectory()
        database = SyncDatabaseFixture()
        sync = SyncService(database: database, directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { true })
        history = HistoryService(directoryURL: directory.url, syncService: sync)
        let now = Date()
        date = HistoryStorage.dateKey(for: now)
        eventURL = try directory.writeJournal(AppServerEventRecord(activity: TestFixtures.event(at: now), recordedAt: now).jsonLineData(), to: "Events/\(date).jsonl")
        _ = await history.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        local = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))).first)
        var remote = local
        remote.eventCount = 9
        _ = await sync.synchronizeIfEnabled(localAggregates: [remote], trigger: .manual)
        #expect(await database.activityRecords().count == 1)
    }
}

extension SyncRecoveryTests {
    @Test func rebuildUploadsAlgorithmVersionEvenWhenCountsAreUnchanged() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { try? fixture.directory.remove() }
        var previous = fixture.local
        previous.aggregationVersion = 1
        let boundary = try #require(previous.sourceCheckpoint?.byteCount)
        previous.sourceCheckpoint?.aggregationRanges = [.init(version: 1, end: boundary)]
        try previous.jsonLineData().write(to: HistoryStorage.dailyURL(in: fixture.directory.url))
        let remote = try #require(await fixture.database.activityRecords().first)
        try ActivityRecordCodec.apply(previous.syncedAggregate, deviceID: #require(remote["deviceID"] as? String), to: remote)
        _ = try await fixture.database.modifyRecords(saving: [remote], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        _ = await fixture.sync.synchronizeIfEnabled(localAggregates: [previous], trigger: .manual)
        let outcome = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let updated = try #require(await fixture.database.activityRecords().first)
        #expect(updated["eventCount"] as? Int == previous.eventCount)
        #expect(updated["aggregationVersion"] as? Int == AggregationVersion.activity)
        #expect(!outcome.summary.isSyncPending)
        #expect(await fixture.database.activityRecords().count == 1)
    }
}

extension SyncRecoveryTests {
    @Test(arguments: [true, false])
    func recoveredTokensUseFreshCloudBaselineBeforeUploading(coversRemote: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let id = TokenTurn.identifier(thread: "thread", turn: "turn")
        let usage = TokenUsage(inputTokens: 10, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 10)
        let observation = TokenObservation(
            turn: TokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now),
            rootStartedAt: now, streamID: "stream", sequence: 1, previous: .zero, current: usage
        )
        let store = TokenHistoryStore(directoryURL: directory.url)
        var old = try #require(try await store.recordObservations([observation], now: now).first)
        old.usage = TokenUsage(inputTokens: 12, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 12)
        old.aggregationVersion = 1
        if !coversRemote {
            old.checkpoint = ["missing-stream": TokenObservationCheckpoint(sequence: 1, usage: usage)]
        }
        let salt = Data("account".utf8)
        let remote = old.pseudonymized(salt: salt)
        let record = CKRecord(recordType: TokenSync.recordType, recordID: CKRecord.ID(recordName: remote.id, zoneID: Self.zone))
        TokenSync.apply(remote, to: record)
        let database = SyncDatabaseFixture()
        await database.storeRecord(record)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        let recovered = try await store.refresh(now: now)
        let sync = TokenSync(database: database, directoryURL: directory.url.appendingPathComponent("Sync/Tokens"), isEnabled: { true })
        try await sync.synchronize(local: recovered, recoveredIDs: store.pendingRecoveryIDs(), accountScopedDeviceID: "device", salt: salt, zoneID: Self.zone)
        let saved = try #require(try await database.records(for: [record.recordID], desiredKeys: nil)[record.recordID]?.get())
        let updated = try #require(try TokenSync.turn(from: saved))
        if !coversRemote {
            #expect(updated == remote)
            #expect(await store.pendingRecoveryIDs().contains(id))
            return
        }
        #expect(updated.usage == usage)
        #expect(!updated.hasConflict)
        #expect(updated.aggregationVersion == AggregationVersion.tokens)
        #expect(updated.ancestorIDs.contains(old.generationID))
        let more = TokenUsage(inputTokens: 15, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 15)
        let next = TokenObservation(
            turn: observation.turn.emptyTurn, rootStartedAt: now, streamID: "stream", sequence: 2,
            previous: usage, current: more
        )
        _ = try await store.recordObservations([next], now: now)
        let cloudBaseline = TokenHistoryBaseline(salt: salt, turns: [updated.id: updated])
        let reconciled = try #require(try await store.refresh(now: now, baseline: cloudBaseline).first)
        #expect(reconciled.usage == more)
        #expect(!reconciled.hasConflict)
        #expect(reconciled.ancestorIDs.contains(updated.generationID))
        #expect(await store.pendingRecoveryIDs().isEmpty)
        #expect(try await store.refresh(now: now, baseline: cloudBaseline).first?.generationID == reconciled.generationID)
    }

    @Test func remoteDateDoesNotHideMissingLocalContribution() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        var remote = ActivityAggregate(date: date, generationID: "other-source")
        remote.turnCount = 8
        let record = try ActivitySyncRecord(
            deviceID: "other", daily: remote.syncedAggregate,
            recordName: ActivitySyncRecord.recordName(deviceID: "other", date: date, generation: "other-source")
        )
        let root = HistoryStorage.syncDirectoryURL(in: directory.url)
        try ActivitySyncStore(directoryURL: root).saveCachedRecords([record], state: SyncState(deviceID: "local"))
        var journal = AppServerEventJournal()
        try journal.append(AppServerEventRecord(activity: TestFixtures.event(at: now)), in: directory.url)
        let sync = SyncService(database: SyncDatabaseFixture(), directoryURL: root, isEnabled: { true })
        let history = HistoryService(directoryURL: directory.url, syncService: sync)
        let snapshot = await history.loadSnapshot()
        let day = UsageHeatmapDay.grid(usage: nil, history: snapshot, columnCount: 1, today: now).compactMap(\.self).first { $0.startDate == date }
        #expect(snapshot.unavailableActivityDates.contains(date))
        #expect(day?.history.turnCount == nil)
    }
}

extension SyncRecoveryTests {
    @Test(arguments: [true, false])
    func recoveringOneTaskDoesNotReplaceUnrecoverableCloudTask(hasLocalSnapshot: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        func counts(_ value: Int64) -> TokenUsage {
            TokenUsage(inputTokens: value, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: value)
        }
        func observation(_ name: String, sequence: Int64 = 1, previous: Int64 = 0, current: Int64) -> TokenObservation {
            let id = TokenTurn.identifier(thread: name, turn: "turn")
            return TokenObservation(
                turn: TokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now), rootStartedAt: now,
                streamID: name, sequence: sequence, previous: counts(previous), current: counts(current)
            )
        }
        let a = observation("a", current: 100)
        let b = observation("b", current: 200)
        var oldA = try a.applying(to: nil)
        oldA.usage = counts(120)
        let oldB = try b.applying(to: nil)
        let remoteA = oldA.pseudonymized(salt: Self.salt)
        let remoteB = oldB.pseudonymized(salt: Self.salt)
        let database = SyncDatabaseFixture()
        let aID = TokenSync.recordID(remoteA.id, zoneID: Self.zone)
        let bID = TokenSync.recordID(remoteB.id, zoneID: Self.zone)
        for turn in [remoteA, remoteB] {
            let record = CKRecord(recordType: TokenSync.recordType, recordID: TokenSync.recordID(turn.id, zoneID: Self.zone))
            TokenSync.apply(turn, to: record)
            await database.storeRecord(record)
        }
        let brokenB = observation("b", sequence: 3, previous: 250, current: 300)
        var data = try AppServerEventRecord(observation: a, recordedAt: now).jsonLineData()
            + AppServerEventRecord(observation: brokenB, recordedAt: now).jsonLineData()
        if hasLocalSnapshot {
            for turn in [oldA, oldB] {
                try data.append(AppServerEventRecord(token: turn, recordedAt: now).jsonLineData())
            }
        }
        try directory.writeJournal(data, to: "Events/\(HistoryStorage.dateKey(for: now)).jsonl")
        try directory.write("broken cache", to: "Aggregates/tokens.json")
        let store = TokenHistoryStore(directoryURL: directory.url)
        let recovered = try await store.refresh(now: now)
        #expect(recovered.first { $0.id == a.turn.id }?.usage == counts(100))
        #expect(recovered.first { $0.id == b.turn.id } == (hasLocalSnapshot ? oldB : nil))
        #expect(await store.pendingRecoveryIDs() == [a.turn.id])
        let sync = TokenSync(database: database, directoryURL: directory.url.appendingPathComponent("Sync/Tokens"), isEnabled: { true })
        try await sync.synchronize(local: recovered, recoveredIDs: store.pendingRecoveryIDs(), accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        let saved = try await database.records(for: [aID, bID], desiredKeys: nil)
        let aRecord = try #require(try saved[aID]?.get())
        let bRecord = try #require(try saved[bID]?.get())
        let savedA = try #require(try TokenSync.turn(from: aRecord))
        let savedB = try #require(try TokenSync.turn(from: bRecord))
        #expect(savedA.usage == counts(100))
        #expect(!savedA.hasConflict)
        #expect(savedA.aggregationVersion == AggregationVersion.tokens)
        #expect(savedA.ancestorIDs.contains(oldA.generationID))
        #expect(savedB == remoteB)
        #expect(await database.savedTypes == [TokenSync.recordType])
        #expect(await database.deletedIDs.isEmpty)
        let baseline = try #require(await sync.recoveryBaseline(accountScopedDeviceID: "device"))
        let reopened = TokenHistoryStore(directoryURL: directory.url)
        let reconciled = try await reopened.refresh(now: now, baseline: baseline)
        try await sync.synchronize(local: reconciled, recoveredIDs: reopened.pendingRecoveryIDs(), accountScopedDeviceID: "device", salt: Self.salt, zoneID: Self.zone)
        #expect(await database.savedTypes == [TokenSync.recordType])
        #expect(await database.deletedIDs.isEmpty)
        let total = try await sync.snapshot(local: reconciled, accountScopedDeviceID: "device")
        #expect(total[HistoryStorage.dateKey(for: now)] == counts(300))
    }
}
