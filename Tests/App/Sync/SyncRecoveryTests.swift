import CloudKit
import Foundation
import Testing

struct SyncRecoveryTests {
    @Test func expiredTokenUsageCacheStaysBoundedWhenCloudDeletionFailsAndRetries() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let expiredAt = HistoryStorage.retentionCutoffDate().addingTimeInterval(-86400)
        var expiredIDs: [CKRecord.ID] = []
        for index in 1 ... 2 {
            let daily = TokenUsageSyncRecord(deviceID: "device", date: HistoryStorage.dateKey(for: expiredAt.addingTimeInterval(Double(-index) * 86400)), tokenUsage: .zero)
            let record = CKRecord(recordType: TokenUsageSync.recordType, recordID: TokenUsageSync.recordID(daily.id, zoneID: SyncTestFixtures.zone))
            try TokenUsageSync.apply(daily, to: record)
            await database.storeRecord(record)
            expiredIDs.append(record.recordID)
        }
        await database.failNextDeletion()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        }
        #expect(try Self.cachedDailyCount(in: directory.url) == 1)
        let reopened = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await reopened.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(try Self.cachedDailyCount(in: directory.url) == 1)
        let remaining = try await database.records(for: expiredIDs, desiredKeys: nil)
        for id in expiredIDs {
            #expect(throws: (any Error).self) { try remaining[id]?.get() }
        }
    }

    @Test(arguments: [false, true])
    func remoteActivityDataChangesAreRepairedWithoutRepeatedUploads(deleted: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let date = HistoryStorage.dateKey(for: Date())
        let local = TestFixtures.activityDataAggregate(date: date)
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(await service.hasPendingActivityDataUpdates(local: [local]) == false)
        let remote = try #require(await database.activityDataRecords().first)
        if deleted {
            await database.removeRecord(remote.recordID)
        } else {
            var changed = local
            changed.eventCount = 9
            try ActivityDataRecordCodec.apply(changed.syncedAggregate, deviceID: #require(remote["deviceID"] as? String), to: remote)
            await database.storeRecord(remote)
        }

        let restarted = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await restarted.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(await database.savedTypes.filter { $0 == "ActivityData" }.count == 2)
        #expect(try await SyncTestFixtures.activityDataEventCount(database.activityDataRecords().first) == 1)
        let cache = try ActivityDataSyncStore(directoryURL: directory.url).load()
        #expect(cache.sortedRecords.map(\.activityData) == [local.syncedAggregate])
        #expect(await restarted.hasPendingActivityDataUpdates(local: [local]) == false)
        let writes = await database.savedTypes.count
        let reads = await database.requestedIDs.filter { $0.recordName != "accountSalt" }.count
        _ = await restarted.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(await database.savedTypes.count == writes)
        #expect(await database.requestedIDs.filter { $0.recordName != "accountSalt" }.count == reads)
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().state.lastUploadAt == cache.state.lastUploadAt)
    }

    @Test func damagedActivityDataCursorRebuildsWithoutBlockingTokenUsage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [], trigger: .manual)
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("broken cursor".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let queriesBefore = await database.queryCount
        let changesBefore = await database.changesSinceNil.count
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [], localTokenUsageAggregates: [Self.turn(0)], trigger: .manual)
        #expect(await database.queryCount == queriesBefore)
        #expect(await database.changesSinceNil.count > changesBefore)
        #expect(await database.changesSinceNil[changesBefore])
        #expect(await database.savedTypes.contains(TokenUsageSync.recordType))
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().cursor == nil)
    }

    @Test(arguments: [false, true])
    func activityDataRebuildCommitsOnlyAfterAllPagesSucceed(failSecondPage: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [], trigger: .manual)
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        let date = HistoryStorage.dateKey(for: Date())
        let daily = TestFixtures.activityDataAggregate(date: date).syncedAggregate
        let stale = try ActivityDataSyncRecord(deviceID: "stale", activityData: daily, recordName: "activityData_stale_\(date)")
        try store.saveFetchedRecords([stale.id: stale], cursor: nil)
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        let original = try Data(contentsOf: url)
        let remote = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_remote_\(date)", zoneID: SyncTestFixtures.zone))
        try ActivityDataRecordCodec.apply(daily, deviceID: "remote", to: remote)
        remote["updatedAt"] = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) as CKRecordValue
        let deleted = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_deleted_\(date)", zoneID: SyncTestFixtures.zone))
        try ActivityDataRecordCodec.apply(daily, deviceID: "deleted", to: deleted)
        let expiredDate = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate().addingTimeInterval(-86400))
        let expiredDaily = TestFixtures.activityDataAggregate(date: expiredDate).syncedAggregate
        let expired = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_remote_\(expiredDate)", zoneID: SyncTestFixtures.zone))
        try ActivityDataRecordCodec.apply(expiredDaily, deviceID: "remote", to: expired)
        let metadata = CKRecord(recordType: "Metadata", recordID: CKRecord.ID(recordName: "ignored", zoneID: SyncTestFixtures.zone))
        let first = SyncChanges(
            records: [remote.recordID: .success(remote), deleted.recordID: .success(deleted), expired.recordID: .success(expired), metadata.recordID: .success(metadata)],
            deletions: [], token: nil, moreComing: true
        )
        let last = SyncChanges(records: [:], deletions: [(deleted.recordID, "ActivityData")], token: nil, moreComing: false)
        // 同步在上传前后各拉取一次, 两次都要独立得到完整结果
        await database.setChangesPages(failSecondPage
            ? [.success(first), .failure(CKError(.networkFailure))]
            : [.success(first), .success(last), .success(first), .success(last)])
        let queriesBefore = await database.queryCount
        let result = await service.synchronizeIfEnabled(localActivityDataAggregates: [], trigger: .manual)
        #expect(await database.queryCount == queriesBefore)
        #expect(await database.remainingChangesPages == 0)
        if failSecondPage {
            #expect(try Data(contentsOf: url) == original)
            #expect(result.activityData == [stale])
        } else {
            let expected = try #require(try ActivityDataRecordCodec.remoteDailyRecord(from: remote))
            #expect(result.activityData == [expected])
            #expect(try store.load().sortedRecords == [expected])
        }
    }

    @Test(arguments: [false, true]) func damagedTokenUsageCacheOrCursorRebuilds(cursorOnly: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let url = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        if cursorOnly {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["cursor"] = Data("broken cursor".utf8).base64EncodedString()
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        } else {
            try Data("broken cache".utf8).write(to: url)
        }
        let reopened = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await reopened.synchronize(local: [], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(try Self.cachedDailyCount(in: directory.url) == 1)
    }

    @Test func failedTokenUsageRebuildPreservesOriginalBytes() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data("broken cache".utf8)
        let url = try directory.write(original, to: "Sync/tokenUsage.json")
        let database = SyncDatabaseFixture(changesFail: true)
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(arguments: [false, true]) func activityDataFailureOnlyStopsTokenUsageForSharedErrors(shared: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture(nextChangesError: shared ? .networkFailure : .invalidArguments)
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [], localTokenUsageAggregates: [Self.turn(0)], trigger: .manual)
        #expect(await database.savedTypes.contains(TokenUsageSync.recordType) == !shared)
    }

    @Test(arguments: ["Metadata", "ActivityData", "TokenUsage"])
    func missingReadResultStopsAffectedUploadAndRetries(recordType: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let initial = await service.synchronizeIfEnabled(localActivityDataAggregates: [], trigger: .manual)
        let deviceID = try #require(initial.currentDeviceID)
        let tokenUsage = Self.turn(0)
        let activityData = TestFixtures.activityDataAggregate(date: tokenUsage.date)
        let missingName: String = switch recordType {
        case "ActivityData":
            ActivityDataSyncRecord.recordName(deviceID: deviceID, date: activityData.date)
        case "TokenUsage":
            TokenUsageSyncRecord(deviceID: deviceID, date: tokenUsage.date, tokenUsage: .zero).recordName
        default:
            try #require(await database.requestedIDs.first).recordName
        }
        await database.omitReadResult(named: missingName)

        _ = await service.synchronizeIfEnabled(
            localActivityDataAggregates: [activityData], localTokenUsageAggregates: [tokenUsage], trigger: .manual
        )
        let savedTypes = await database.savedTypes
        #expect(savedTypes.filter { $0 == "Metadata" }.count == 1)
        #expect(savedTypes.contains("ActivityData") == (recordType == "TokenUsage"))
        #expect(savedTypes.contains("TokenUsage") == (recordType == "ActivityData"))
        #expect(await service.hasPendingActivityDataUpdates(local: [activityData]) == (recordType != "TokenUsage"))
        #expect(await service.hasPendingTokenUsageUpdates(local: [tokenUsage]) == (recordType != "ActivityData"))

        await database.repair()
        _ = await service.synchronizeIfEnabled(
            localActivityDataAggregates: [activityData], localTokenUsageAggregates: [tokenUsage], trigger: .manual
        )
        let recoveredTypes = await database.savedTypes
        for type in ["Metadata", "ActivityData", "TokenUsage"] {
            #expect(recoveredTypes.filter { $0 == type }.count == 1)
        }
        #expect(await service.hasPendingActivityDataUpdates(local: [activityData]) == false)
        #expect(await service.hasPendingTokenUsageUpdates(local: [tokenUsage]) == false)
    }

    @Test(arguments: [false, true]) func partialTokenUsageBatchContinuesAndRetainsSuccesses(readFailure: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let aggregates = (0 ..< 30).map(Self.turn)
        let badID = "tokenUsage_device_" + aggregates[0].date
        let database = SyncDatabaseFixture(failingName: badID, readFailure: readFailure)
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: aggregates, accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        }
        #expect(await database.savedTypes.filter { $0 == TokenUsageSync.recordType }.count == 29)
        #expect(try Self.cachedDailyCount(in: directory.url) == 29)
        await database.repair()
        try await service.synchronize(local: aggregates, accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(await database.savedTypes.filter { $0 == TokenUsageSync.recordType }.count == 30)
    }

    @Test(arguments: [CKError.Code.constraintViolation, .serverRecordChanged])
    func partialActivityDataBatchConfirmsSuccessesAndContinuesLaterDates(code: CKError.Code) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let dates = (0 ..< 30).map { HistoryStorage.dateKey(for: Date().addingTimeInterval(Double(-$0) * 86400)) }
        let aggregates = dates.map { TestFixtures.activityDataAggregate(date: $0) }
        let database = SyncDatabaseFixture(failingDate: dates[0], uploadFailure: code)
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            isEnabled: { true }
        )
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: aggregates, localTokenUsageAggregates: [Self.turn(0)], trigger: .manual)
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().records.count == 29)
        #expect(await database.savedTypes.filter { $0 == "ActivityData" }.count == 29)
        #expect(await database.savedTypes.contains(TokenUsageSync.recordType))
        #expect(await service.hasPendingActivityDataUpdates(local: aggregates))
        await database.repair()
        let restarted = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await restarted.synchronizeIfEnabled(localActivityDataAggregates: aggregates, trigger: .manual)
        #expect(await database.savedTypes.filter { $0 == "ActivityData" }.count == 30)
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().records.count == 30)
        #expect(await restarted.hasPendingActivityDataUpdates(local: aggregates) == false)
    }

    @Test func confirmedActivityDataSurvivesPostUploadFetchFailureAndRestart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        await database.setChangesPages([
            .success(SyncChanges(records: [:], deletions: [], token: nil, moreComing: false)),
            .failure(CKError(.networkFailure))
        ])
        let local = TestFixtures.activityDataAggregate(date: HistoryStorage.dateKey(for: Date()))
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let snapshot = await service.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(!snapshot.isActivityDataComplete)
        let cache = try ActivityDataSyncStore(directoryURL: directory.url).load()
        let confirmed = try #require(cache.sortedRecords.first)
        #expect(confirmed.activityData == local.syncedAggregate)
        #expect(confirmed.updatedAt != nil)
        #expect(cache.state.lastUploadAt != nil)

        let restarted = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let restored = await restarted.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(restored.isActivityDataComplete)
        #expect(await database.savedTypes.filter { $0 == "ActivityData" }.count == 1)
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().state.lastUploadAt == cache.state.lastUploadAt)
    }

    @Test func failedRecordDuringFetchDoesNotCommitPartialCache() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let url = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        let original = try Data(contentsOf: url)
        await database.failChangesRecord()
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [Self.turn(1)], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func unsupportedTokenUsageVersionIsNotTreatedAsCorruption() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let url = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        let original = Data(#"{"schemaVersion":999,"futureField":"unsupported"}"#.utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func dailyActivityDataUploadDoesNotRequireLocalSourceMetadata() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            isEnabled: { true }
        )
        var local = ActivityDataAggregate(date: HistoryStorage.dateKey(for: Date()))
        local.eventCount = 5
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        let before = await database.activityDataRecords().map(\.recordID)
        local.eventCount = 3
        let result = await service.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(await database.deletedIDs.isEmpty)
        #expect(await database.activityDataRecords().map(\.recordID) == before)
        #expect(result.activityData.count == before.count)
        #expect(try await SyncTestFixtures.activityDataEventCount(database.activityDataRecords().first) == 3)
    }

    @Test func invalidRecordDuringCursorBaselineStopsActivityDataUpload() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let invalid = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "device_invalid"))
        invalid["deviceID"] = "device" as CKRecordValue
        invalid["date"] = HistoryStorage.dateKey(for: Date()) as CKRecordValue
        await database.injectChangesRecord(invalid)
        let service = SyncService(
            database: database,
            directoryURL: directory.url,
            isEnabled: { true }
        )
        var local = TestFixtures.activityDataAggregate(date: HistoryStorage.dateKey(for: Date()))
        local.eventCount = 1
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [local], trigger: .manual)
        #expect(await database.activityDataRecords().isEmpty)
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().cursor == nil)
        #expect(try ActivityDataSyncStore(directoryURL: directory.url).load().records.isEmpty)
    }

    @Test func unknownLocalSyncCacheFailsBeforeCloudMutation() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data("{\"schemaVersion\":999}".utf8)
        let url = try directory.write(original, to: "Sync/activityData.json")
        let database = SyncDatabaseFixture()
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let result = await service.synchronizeIfEnabled(localActivityDataAggregates: [], localTokenUsageAggregates: [Self.turn(0)], trigger: .manual)
        #expect(!result.isActivityDataComplete)
        #expect(await database.savedTypes.isEmpty)
        #expect(await database.deletedIDs.isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    private static func cachedDailyCount(in directory: URL) throws -> Int {
        let data = try Data(contentsOf: directory.appendingPathComponent("Sync/tokenUsage.json"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(json["records"] as? [[String: Any]]).count
    }

    private static func turn(_ index: Int) -> TokenUsageAggregate {
        let now = Date().addingTimeInterval(Double(-index) * 86400)
        return TestFixtures.tokenUsageAggregate(at: now, tokenUsage: .zero)
    }
}

extension SyncRecoveryTests {
    @Test func activityDataAndTokenUsageKeepSeparateDailyRecordsAndMergeOtherDevicesOnlyForDisplay() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let sync = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let date = HistoryStorage.dateKey(for: Date())
        var local = ActivityDataAggregate(date: date)
        local.turnCount = 2
        var turn = Self.turn(0)
        turn.tokenUsage = SyncTestFixtures.counts(100)
        let initial = await sync.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [turn], trigger: .manual)
        let deviceID = try #require(initial.currentDeviceID)
        let activityDataID = CKRecord.ID(recordName: ActivityDataSyncRecord.recordName(deviceID: deviceID, date: date), zoneID: SyncTestFixtures.zone)
        let tokenUsageID = TokenUsageSync.recordID("tokenUsage_\(deviceID)_\(date)", zoneID: SyncTestFixtures.zone)
        #expect(activityDataID != tokenUsageID)
        let own = try await database.records(for: [activityDataID, tokenUsageID], desiredKeys: nil)
        #expect(try own[activityDataID]?.get().recordType == "ActivityData")
        #expect(try own[tokenUsageID]?.get().recordType == "TokenUsage")

        var other = ActivityDataAggregate(date: date)
        other.turnCount = 3
        let otherActivityData = CKRecord(
            recordType: "ActivityData",
            recordID: CKRecord.ID(recordName: ActivityDataSyncRecord.recordName(deviceID: "other", date: date), zoneID: SyncTestFixtures.zone)
        )
        try ActivityDataRecordCodec.apply(other.syncedAggregate, deviceID: "other", to: otherActivityData)
        await database.storeRecord(otherActivityData)
        try await database.storeRecord(SyncTestFixtures.tokenUsageRecord(TokenUsageSyncRecord(deviceID: "other", date: date, tokenUsage: SyncTestFixtures.counts(900))))

        let combined = await sync.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [turn], trigger: .manual)
        let snapshot = HistorySnapshot(localActivityDataAggregates: [local], syncedActivityDataRecords: combined.activityData, currentDeviceID: combined.currentDeviceID)
        #expect(snapshot.activityData.first?.turnCount == 5)
        #expect(combined.tokenUsageByDate?[date] == SyncTestFixtures.counts(1000))
        #expect(await database.savedTypes.filter { $0 == "ActivityData" }.count == 1)
        #expect(await database.savedTypes.filter { $0 == "TokenUsage" }.count == 1)

        local.turnCount = 1
        turn.tokenUsage = SyncTestFixtures.counts(50)
        let reduced = await sync.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [turn], trigger: .manual)
        let updated = HistorySnapshot(localActivityDataAggregates: [local], syncedActivityDataRecords: reduced.activityData, currentDeviceID: reduced.currentDeviceID)
        #expect(updated.activityData.first?.turnCount == 4)
        #expect(reduced.tokenUsageByDate?[date] == SyncTestFixtures.counts(950))
        #expect(await database.activityDataRecords().count == 2)
        let saved = try #require(try await database.records(for: [activityDataID], desiredKeys: nil)[activityDataID]?.get())
        #expect(try ActivityDataRecordCodec.remoteDailyRecord(from: saved)?.activityData.turnCount == 1)
    }

    @Test func dailyTokenUsageReplaceOneDeviceDateIncludingDecreasesAndZero() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        var daily = Self.turn(0)
        daily.tokenUsage = SyncTestFixtures.counts(300)
        let recordID = TokenUsageSync.recordID("tokenUsage_device_\(daily.date)", zoneID: SyncTestFixtures.zone)
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(await database.savedTypes == ["TokenUsage"])
        #expect(try await service.snapshot(local: [daily], accountScopedDeviceID: "device")[daily.date] == SyncTestFixtures.counts(300))
        #expect(await service.hasPendingUpdates(local: [daily], accountScopedDeviceID: "device") == false)
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(await database.savedTypes == ["TokenUsage"])
        daily.tokenUsage = SyncTestFixtures.counts(250)
        #expect(await service.hasPendingUpdates(local: [daily], accountScopedDeviceID: "device"))
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == SyncTestFixtures.counts(250))
        #expect(try Self.cachedDailyCount(in: directory.url) == 1)
        daily.tokenUsage = .zero
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(try await service.snapshot(local: [daily], accountScopedDeviceID: "device")[daily.date] == .zero)
    }

    @Test(arguments: [100, 900] as [Int64])
    func deviceDailyContributionsStayIsolatedAndStableAcrossRestart(otherCount: Int64) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        var local = Self.turn(0)
        local.tokenUsage = SyncTestFixtures.counts(100)
        let date = local.date
        let other = TokenUsageSyncRecord(deviceID: "other", date: date, tokenUsage: SyncTestFixtures.counts(otherCount))
        let otherRecord = try SyncTestFixtures.tokenUsageRecord(other)
        await database.storeRecord(otherRecord)
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [local], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(try await service.snapshot(local: [local], accountScopedDeviceID: "device")[date] == SyncTestFixtures.counts(100 + otherCount))
        let localID = TokenUsageSync.recordID("tokenUsage_device_\(date)", zoneID: SyncTestFixtures.zone)
        let saved = try #require(try await database.records(for: [localID], desiredKeys: nil)[localID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == SyncTestFixtures.counts(100))
        let cacheURL = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        let cache = try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: Data(contentsOf: cacheURL))
        let before = try #require(cache.records[localID.recordName])
        #expect(before.updatedAt != nil)
        let restarted = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        #expect(await restarted.hasPendingUpdates(local: [local], accountScopedDeviceID: "device") == false)
        try await restarted.synchronize(local: [local], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let after = try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: Data(contentsOf: cacheURL))
        #expect(after.records[before.id] == before)
        #expect(await database.savedTypes == ["TokenUsage"])
        #expect(try await restarted.snapshot(local: [local], accountScopedDeviceID: "new-account")[date] == SyncTestFixtures.counts(100))
        #expect(try await restarted.snapshot(local: [], accountScopedDeviceID: "device")[date] == SyncTestFixtures.counts(100 + otherCount))
    }

    @Test func rebuiltLocalObservationsReplaceCloudDailyTotalsWithoutCloudTurnState() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let observation = TestFixtures.tokenUsageObservation(at: now, tokenUsage: SyncTestFixtures.counts(100))
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        var old = try #require(try await store.recordObservations([observation], now: now).first)
        old.tokenUsage = SyncTestFixtures.counts(120)
        try directory.seedTokenUsageAggregates([old])
        let database = SyncDatabaseFixture()
        let sync = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await sync.synchronize(local: [old], accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let date = HistoryStorage.dateKey(for: now)
        _ = try await store.rebuild(for: [date])
        let aggregates = try await store.persistedAggregates(now: now)
        try await sync.synchronize(local: aggregates, accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        let recordID = TokenUsageSync.recordID("tokenUsage_device_\(date)", zoneID: SyncTestFixtures.zone)
        let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == SyncTestFixtures.counts(100))
        #expect(await sync.hasPendingUpdates(local: aggregates, accountScopedDeviceID: "device") == false)
        try HistoryDatabase(directoryURL: directory.url).execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        let recovered = try await TokenUsageHistoryStore(directoryURL: directory.url).refresh(now: now)
        try await sync.synchronize(local: recovered, accountScopedDeviceID: "device", zoneID: SyncTestFixtures.zone)
        #expect(await database.savedTypes == ["TokenUsage", "TokenUsage"])
    }

    @Test func bothSyncCachesPersistTheSameCloudRecordEnvelope() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let date = HistoryStorage.dateKey(for: Date())
        let local = TestFixtures.activityDataAggregate(date: date)
        let service = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        _ = await service.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [Self.turn(0)], trigger: .manual)

        var deviceIDs: [String] = []
        for kind in ["activityData", "tokenUsage"] {
            let data = try Data(contentsOf: directory.url.appendingPathComponent("Sync/\(kind).json"))
            let cache = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(cache.keys) == ["schemaVersion", "state", "cursor", "records"])
            let state = try #require(cache["state"] as? [String: Any])
            #expect(state["containerIdentifier"] as? String == SyncCloudKit.containerIdentifier)
            try deviceIDs.append(#require(state["deviceID"] as? String))
            let records = try #require(cache["records"] as? [[String: Any]])
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(Set(record.keys) == ["schemaVersion", "aggregationVersion", "deviceID", "date", "recordName", "updatedAt", kind])
            #expect(record["date"] as? String == date)
            let recordName = try #require(record["recordName"] as? String)
            let id = CKRecord.ID(recordName: recordName, zoneID: SyncTestFixtures.zone)
            let remote = try #require(try await database.records(for: [id], desiredKeys: nil)[id]?.get())
            let remoteUpdatedAt = try #require(remote["updatedAt"] as? Date)
            let cachedUpdatedAt = try #require(record["updatedAt"] as? Double)
            #expect(abs(cachedUpdatedAt / 1000 - remoteUpdatedAt.timeIntervalSince1970) < 0.001)
            let remotePayload = try #require(remote[kind] as? Data)
            let remoteCounts = try #require(JSONSerialization.jsonObject(with: remotePayload) as? NSDictionary)
            let cachedCounts = try #require(record[kind] as? NSDictionary)
            #expect(cachedCounts == remoteCounts)
        }
        #expect(deviceIDs[0] == deviceIDs[1])
    }
}
