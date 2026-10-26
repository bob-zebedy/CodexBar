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
            let record = CKRecord(recordType: TokenUsageSync.recordType, recordID: TokenUsageSync.recordID(daily.id, zoneID: Self.zone))
            try TokenUsageSync.apply(daily, to: record)
            await database.storeRecord(record)
            expiredIDs.append(record.recordID)
        }
        await database.failNextDeletion()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: Self.zone)
        }
        #expect(try Self.cachedDailyCount(in: directory.url) == 1)
        let reopened = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await reopened.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: Self.zone)
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
        #expect(try await Self.activityDataEventCount(database.activityDataRecords().first) == 1)
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

    private static let zone = CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)

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
        let remote = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_remote_\(date)", zoneID: Self.zone))
        try ActivityDataRecordCodec.apply(daily, deviceID: "remote", to: remote)
        remote["updatedAt"] = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) as CKRecordValue
        let deleted = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_deleted_\(date)", zoneID: Self.zone))
        try ActivityDataRecordCodec.apply(daily, deviceID: "deleted", to: deleted)
        let expiredDate = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate().addingTimeInterval(-86400))
        let expiredDaily = TestFixtures.activityDataAggregate(date: expiredDate).syncedAggregate
        let expired = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_remote_\(expiredDate)", zoneID: Self.zone))
        try ActivityDataRecordCodec.apply(expiredDaily, deviceID: "remote", to: expired)
        let metadata = CKRecord(recordType: "Metadata", recordID: CKRecord.ID(recordName: "ignored", zoneID: Self.zone))
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
        try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: Self.zone)
        let url = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        if cursorOnly {
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            json["cursor"] = Data("broken cursor".utf8).base64EncodedString()
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        } else {
            try Data("broken cache".utf8).write(to: url)
        }
        let reopened = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await reopened.synchronize(local: [], accountScopedDeviceID: "device", zoneID: Self.zone)
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
            try await service.synchronize(local: [], accountScopedDeviceID: "device", zoneID: Self.zone)
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
            try await service.synchronize(local: aggregates, accountScopedDeviceID: "device", zoneID: Self.zone)
        }
        #expect(await database.savedTypes.filter { $0 == TokenUsageSync.recordType }.count == 29)
        #expect(try Self.cachedDailyCount(in: directory.url) == 29)
        await database.repair()
        try await service.synchronize(local: aggregates, accountScopedDeviceID: "device", zoneID: Self.zone)
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
        try await service.synchronize(local: [Self.turn(0)], accountScopedDeviceID: "device", zoneID: Self.zone)
        let url = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        let original = try Data(contentsOf: url)
        await database.failChangesRecord()
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [Self.turn(1)], accountScopedDeviceID: "device", zoneID: Self.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func unsupportedTokenUsageVersionIsNotTreatedAsCorruption() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [], accountScopedDeviceID: "device", zoneID: Self.zone)
        let url = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        let original = Data(#"{"schemaVersion":999,"futureField":"unsupported"}"#.utf8)
        try original.write(to: url)
        await #expect(throws: (any Error).self) {
            try await service.synchronize(local: [], accountScopedDeviceID: "device", zoneID: Self.zone)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func activityDataCacheCommitsRecordsAndCursorTogether() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        let state = ActivityDataSyncState(deviceID: "device")
        try store.saveState(state)
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("previous cursor".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var updated = state
        updated.lastPrunedDate = "2026-10-05"
        try store.saveState(updated)
        #expect(try store.load().cursor == Data("previous cursor".utf8))
        let daily = SyncedActivityData(date: "2026-10-05", eventCount: 2, projectCounts: [:], modelCounts: [:])
        let record = try ActivityDataSyncRecord(deviceID: "device", activityData: daily, recordName: "activityData_device_2026-10-05")
        let uploadedAt = JSONLines.storageDate(Date())
        try store.saveConfirmedRecords([record], lastUploadAt: uploadedAt)
        let confirmed = try store.load()
        #expect(confirmed.cursor == Data("previous cursor".utf8))
        #expect(confirmed.sortedRecords == [record])
        #expect(confirmed.state.lastUploadAt == uploadedAt)
        updated.lastUploadAt = uploadedAt
        try store.saveFetchedRecords([record.id: record], cursor: nil)
        let reopened = try ActivityDataSyncStore(directoryURL: directory.url).load()
        #expect(reopened.state == updated)
        #expect(reopened.sortedRecords == [record])
        #expect(reopened.cursor == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(Set(files) == ["activityData.json"])
        try store.reset(state: ActivityDataSyncState())
        #expect(try store.load() == ActivityDataSyncCache(state: ActivityDataSyncState()))
    }

    @Test(arguments: ["missingFields", "missingDate", "mismatchedIdentity"])
    func damagedActivityDataRecordsInvalidateCursorAndUploadState(_ damage: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        try store.saveState(ActivityDataSyncState(deviceID: "device"))
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("stale cursor".utf8).base64EncodedString()
        var record: [String: Any] = [
            "schemaVersion": 1, "aggregationVersion": 1, "date": "2026-10-05",
            "deviceID": "device", "recordName": "activityData_device_2026-10-05", "activityData": [:]
        ]
        switch damage {
        case "missingFields": record = ["invalid": true]
        case "missingDate": record.removeValue(forKey: "date")
        default: record["recordName"] = "activityData_device_2026-10-05_other"
        }
        json["records"] = [record]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try store.load() == ActivityDataSyncCache(state: ActivityDataSyncState()))
        try store.saveState(ActivityDataSyncState(deviceID: "new"))
        #expect(try store.load().sortedRecords.isEmpty)
        #expect(try store.load().cursor == nil)
        #expect(try store.load().state.deviceID == "new")
    }

    @Test func unsupportedActivityDataCacheIsNotOverwritten() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data(#"{"schemaVersion":999,"futureField":"unsupported"}"#.utf8)
        let url = try directory.write(original, to: "Sync/activityData.json")
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        #expect(throws: SyncRecovery.Failure.self) { try store.saveState(ActivityDataSyncState()) }
        #expect(throws: SyncRecovery.Failure.self) { try store.reset(state: ActivityDataSyncState()) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func failedActivityDataSavePreservesCacheAndCursor() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        try store.saveState(ActivityDataSyncState(deviceID: "device"))
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("previous cursor".utf8).base64EncodedString()
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: url)
        let daily = SyncedActivityData(date: "2026-10-05", eventCount: 2, projectCounts: [:], modelCounts: [:])
        let record = try ActivityDataSyncRecord(
            deviceID: "device", activityData: daily, updatedAt: Date(timeIntervalSince1970: .infinity),
            recordName: "activityData_device_2026-10-05"
        )
        #expect(throws: EncodingError.self) {
            try store.saveFetchedRecords([record.id: record], cursor: nil)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func sameSourceRecalculationCanReduceCountsWithoutDeletingRecord() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let before = try #require(await fixture.database.activityDataRecords().first)
        let result = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let after = try #require(await fixture.database.activityDataRecords().first)
        #expect(before.recordID == after.recordID)
        #expect(try Self.activityDataEventCount(before) == 9)
        #expect(try Self.activityDataEventCount(after) == 1)
        #expect(!result.summary.isSyncPending)
        #expect(await fixture.database.deletedIDs.isEmpty)
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
        #expect(try await Self.activityDataEventCount(database.activityDataRecords().first) == 3)
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

    @Test func recreatedJournalReplacesSameDeviceDateInsteadOfAddingAnotherBatch() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let previous = try #require(await fixture.database.activityDataRecords().first)
        let event = TestFixtures.event(.toolStarted, at: Date(), turn: "different")
        try fixture.directory.replaceHistory(
            AppServerEventRecord(activityData: event).jsonLineData(),
            date: fixture.date
        )
        _ = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let updated = try #require(await fixture.database.activityDataRecords().first)
        #expect(updated.recordID == previous.recordID)
        let counts = try #require(try ActivityDataRecordCodec.remoteDailyRecord(from: updated)?.activityData)
        #expect(counts.eventCount == 1)
        #expect(counts.turnStartedCount == 0)
        #expect(counts.toolStartedCount == 1)
        #expect(await fixture.database.activityDataRecords().count == 1)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func unknownCloudVersionPreservesCacheAndPreventsActivityDataUpload() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let cacheURL = fixture.directory.url.appendingPathComponent("Sync/activityData.json")
        let before = try Data(contentsOf: cacheURL)
        let unsupported = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "future", zoneID: Self.zone))
        unsupported["schemaVersion"] = 999 as CKRecordValue
        await fixture.database.injectChangesRecord(unsupported)
        let result = await fixture.history.loadSnapshot(synchronize: true)
        #expect(!result.isActivityDataComplete)
        #expect(try Data(contentsOf: cacheURL) == before)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
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

    private static func activityDataEventCount(_ record: CKRecord?) throws -> Int? {
        guard let record else { return nil }
        return try ActivityDataRecordCodec.remoteDailyRecord(from: record)?.activityData.eventCount
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

private actor SyncDatabaseFixture: SyncDatabase {
    private var stored: [CKRecord.ID: CKRecord] = [:]
    private var nextChangesError: CKError.Code?
    private let changesFail: Bool
    private var changesRecordFails = false
    private var changesPages: [Result<SyncChanges, Error>] = []

    private var failingName: String?
    private var failingDate: String?
    private var omittedReadName: String?
    private let readFailure: Bool
    private let uploadFailure: CKError.Code
    private(set) var queryCount = 0
    private(set) var changesSinceNil: [Bool] = []
    private(set) var savedTypes: [String] = []
    private(set) var requestedIDs: [CKRecord.ID] = []
    private(set) var deletedIDs: [CKRecord.ID] = []
    private var changesRecord: CKRecord?
    private var deletionFails = false

    var remainingChangesPages: Int {
        changesPages.count
    }

    func setChangesPages(_ pages: [Result<SyncChanges, Error>]) {
        changesPages = pages
    }

    func failNextDeletion() {
        deletionFails = true
    }

    func failActivityDataUpload(on date: String) {
        failingDate = date
    }

    func activityDataRecords() -> [CKRecord] {
        stored.values.filter { $0.recordType == "ActivityData" }.map(Self.copy)
    }

    func removeRecord(_ id: CKRecord.ID) {
        stored[id] = nil
    }

    func storeRecord(_ record: CKRecord) {
        stored[record.recordID] = Self.copy(record)
    }

    func injectChangesRecord(_ record: CKRecord) {
        changesRecord = Self.copy(record)
    }

    init(nextChangesError: CKError.Code? = nil, changesFail: Bool = false, failingName: String? = nil, failingDate: String? = nil, readFailure: Bool = false, uploadFailure: CKError.Code = .constraintViolation) {
        self.nextChangesError = nextChangesError
        self.changesFail = changesFail
        self.failingName = failingName
        self.failingDate = failingDate
        self.readFailure = readFailure
        self.uploadFailure = uploadFailure
    }

    private nonisolated static func copy(_ record: CKRecord) -> CKRecord {
        record.copy() as? CKRecord ?? record
    }

    func failChangesRecord() {
        changesRecordFails = true
    }

    func omitReadResult(named name: String) {
        omittedReadName = name
    }

    func repair() {
        failingName = nil
        failingDate = nil
        omittedReadName = nil
    }

    func records(for ids: [CKRecord.ID], desiredKeys _: [CKRecord.FieldKey]?) async throws -> Records {
        requestedIDs.append(contentsOf: ids)
        return Dictionary(uniqueKeysWithValues: ids.filter { $0.recordName != omittedReadName }.map { id in
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
            if record.recordID.recordName == failingName || (record.recordType == "ActivityData" && failingDate != nil && record["date"] as? String == failingDate) {
                saved[record.recordID] = .failure(CKError(uploadFailure))
            } else {
                stored[record.recordID] = record.copy() as? CKRecord
                saved[record.recordID] = .success(record)
                savedTypes.append(record.recordType)
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
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let outcome = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        #expect(outcome.summary.isSyncPending)
        await fixture.database.failActivityDataUpload(on: fixture.date)
        _ = await fixture.history.loadSnapshot(synchronize: true)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
        await fixture.database.repair()
        let restarted = HistoryService(directoryURL: fixture.directory.url, syncService: fixture.sync)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 1)
        #expect(await fixture.database.activityDataRecords().count == 1)
    }

    @Test func repeatedRebuildKeepsSourceAndNeedsNoSeparateAcknowledgement() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let initial = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        #expect(initial.summary.failedTokenUsageDateKeys.isEmpty)
        #expect(!initial.summary.didFailTokenUsageRebuild)
        _ = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let state = try HistoryDatabase(directoryURL: fixture.directory.url)
        #expect(try state.activityDataAggregates().first == fixture.local)
        #expect(try state.pendingActivityDataDates().isEmpty)
        #expect(await fixture.database.activityDataRecords().count == 1)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func unavailableSourceCannotOverwriteRemoteAndRecoversAfterRepair() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let local = try HistoryDatabase(directoryURL: fixture.directory.url)
        let original = try local.exportJSONLines(date: fixture.date)
        try local.execute("UPDATE events SET payload = ?", [.data(Data("broken".utf8))])
        try local.execute("UPDATE aggregates SET activityData = CAST(json_set(CAST(activityData AS TEXT), '$.aggregationVersion', 0) AS BLOB)")
        await #expect(throws: (any Error).self) {
            try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        }
        let restarted = HistoryService(directoryURL: fixture.directory.url, syncService: fixture.sync)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
        try fixture.directory.replaceHistory(original, date: fixture.date)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 1)
    }

    @Test func requestSaveFailureDoesNotModifyAggregateOrCloud() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let local = try HistoryDatabase(directoryURL: fixture.directory.url)
        let original = try local.activityDataAggregates()
        try local.execute("CREATE TRIGGER reject_aggregate BEFORE UPDATE ON aggregates BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        await #expect(throws: (any Error).self) {
            try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        }
        #expect(try local.activityDataAggregates() == original)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func disabledSyncKeepsUpdatedAggregateForNextEnabledRun() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let disabled = SyncService(database: fixture.database, directoryURL: fixture.directory.url, isEnabled: { false })
        let history = HistoryService(directoryURL: fixture.directory.url, syncService: disabled)
        _ = try await history.rebuildData(for: [fixture.date], synchronize: true)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        _ = await fixture.history.loadSnapshot(synchronize: true)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 1)
    }

    @Test func appendedEventsUpdateSameDeviceDailyCounts() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let activityDataRecorder = ActivityDataRecorder(directoryURL: fixture.directory.url)
        let event = ActivityDataRecord(
            timestamp: Date(),
            name: ActivityDataEventKind.toolStarted.rawValue,
            origin: .main,
            cwd: nil,
            toolName: "exec_command",
            model: nil,
            effort: nil,
            threadID: "thread-a",
            turnID: "turn-a",
            agentThreadID: nil,
            id: "appended-tool"
        )
        try await activityDataRecorder.record(event: event)
        _ = await fixture.history.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        let remote = try #require(await fixture.database.activityDataRecords().first)
        #expect(try Self.activityDataEventCount(remote) == 2)
        #expect(remote["sourceCheckpoint"] == nil)
        #expect(await fixture.database.activityDataRecords().count == 1)
    }

    @Test func unavailableTokenUsageHistoryMarksAllRequestedDatesFailed() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let brokenDirectory = try TestDirectory()
        defer { try? brokenDirectory.remove() }
        _ = try brokenDirectory.write(Data("broken".utf8), to: "event.db")
        let history = HistoryService(
            directoryURL: fixture.directory.url, syncService: fixture.sync,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: brokenDirectory.url)
        )
        let date = try #require(CodexDateFormat.dayDate(from: fixture.date))
        let dates = [fixture.date, HistoryStorage.dateKey(for: date.addingTimeInterval(-86400))]
        let result = try await history.rebuildData(for: dates, synchronize: false)
        #expect(result.summary.failedTokenUsageDateKeys == dates.sorted())
        #expect(result.summary.didFailTokenUsageRebuild)
        #expect(result.summary.rebuiltDateCount == 0)
        #expect(result.summary.eventCount == 1)
        #expect(result.summary.tokenUsageEventCount == 0)
        #expect(result.summary.failedDateKeys.isEmpty)
        #expect(try await Self.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
    }

    @Test func partialTokenUsageFailureIsReportedWithoutClaimingWholeDaySuccess() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let now = Date()
        let good = TestFixtures.tokenUsageObservation(id: "good", at: now, tokenUsage: .zero)
        let bad = TokenUsageObservation(id: "bad", observedAt: now, previous: Self.counts(10), current: TokenUsageUpdate(total: .zero, last: .zero))
        let local = try HistoryDatabase(directoryURL: fixture.directory.url)
        try local.append(AppServerEventRecord(tokenUsage: good, recordedAt: now))
        try local.append(AppServerEventRecord(tokenUsage: bad, recordedAt: now))
        let result = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        #expect(result.summary.rebuiltDateCount == 0)
        #expect(result.summary.eventCount == 1)
        #expect(result.summary.tokenUsageEventCount == 0)
        #expect(result.summary.failedTokenUsageDateKeys == [fixture.date])
        #expect(result.summary.didFailTokenUsageRebuild)
        #expect(result.summary.failedDateKeys.isEmpty)
    }
}

private struct HistoryRebuildFixture {
    let directory: TestDirectory
    let database: SyncDatabaseFixture
    let sync: SyncService
    let history: HistoryService
    let date: String
    let local: ActivityDataAggregate

    init() async throws {
        directory = try TestDirectory()
        database = SyncDatabaseFixture()
        sync = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        history = HistoryService(directoryURL: directory.url, syncService: sync)
        let now = Date()
        date = HistoryStorage.dateKey(for: now)
        try directory.replaceHistory(AppServerEventRecord(activityData: TestFixtures.event(at: now), recordedAt: now).jsonLineData(), date: date)
        _ = await history.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        local = try #require(HistoryDatabase(directoryURL: directory.url).activityDataAggregates().first)
        var remote = local
        remote.eventCount = 9
        _ = await sync.synchronizeIfEnabled(localActivityDataAggregates: [remote], trigger: .manual)
        #expect(await database.activityDataRecords().count == 1)
    }
}

extension SyncRecoveryTests {
    @Test func rebuildUploadsAlgorithmVersionEvenWhenCountsAreUnchanged() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        var previous = fixture.local
        previous.aggregationVersion = 1
        try HistoryDatabase(directoryURL: fixture.directory.url).execute(
            "UPDATE aggregates SET activityData = ? WHERE date = ?",
            [.data(JSONLines.stableEncoder.encode(previous)), .text(fixture.date)]
        )
        let remote = try #require(await fixture.database.activityDataRecords().first)
        try ActivityDataRecordCodec.apply(previous.syncedAggregate, deviceID: #require(remote["deviceID"] as? String), to: remote)
        _ = try await fixture.database.modifyRecords(saving: [remote], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
        _ = await fixture.sync.synchronizeIfEnabled(localActivityDataAggregates: [previous], trigger: .manual)
        let outcome = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let updated = try #require(await fixture.database.activityDataRecords().first)
        #expect(try Self.activityDataEventCount(updated) == previous.eventCount)
        #expect(updated["aggregationVersion"] as? Int == AggregationVersion.activityData)
        #expect(!outcome.summary.isSyncPending)
        #expect(await fixture.database.activityDataRecords().count == 1)
    }
}

extension SyncRecoveryTests {
    @Test func remoteDateDoesNotHideMissingLocalContribution() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        var remote = ActivityDataAggregate(date: date)
        remote.turnCount = 8
        let record = try ActivityDataSyncRecord(
            deviceID: "other", activityData: remote.syncedAggregate,
            recordName: ActivityDataSyncRecord.recordName(deviceID: "other", date: date)
        )
        let root = directory.url
        let store = ActivityDataSyncStore(directoryURL: root)
        try store.saveState(ActivityDataSyncState(deviceID: "local"))
        try store.saveFetchedRecords([record.id: record], cursor: nil)
        try HistoryDatabase(directoryURL: directory.url).append(AppServerEventRecord(activityData: TestFixtures.event(at: now)))
        let sync = SyncService(database: SyncDatabaseFixture(), directoryURL: root, isEnabled: { true })
        let history = HistoryService(directoryURL: directory.url, syncService: sync)
        let snapshot = await history.loadSnapshot()
        let day = UsageHeatmapDay.grid(usage: nil, history: snapshot, columnCount: 1, today: now).compactMap(\.self).first { $0.startDate == date }
        #expect(snapshot.unavailableActivityDataDates.contains(date))
        #expect(day?.activityData.turnCount == nil)
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
        turn.tokenUsage = Self.counts(100)
        let initial = await sync.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [turn], trigger: .manual)
        let deviceID = try #require(initial.currentDeviceID)
        let activityDataID = CKRecord.ID(recordName: ActivityDataSyncRecord.recordName(deviceID: deviceID, date: date), zoneID: Self.zone)
        let tokenUsageID = TokenUsageSync.recordID("tokenUsage_\(deviceID)_\(date)", zoneID: Self.zone)
        #expect(activityDataID != tokenUsageID)
        let own = try await database.records(for: [activityDataID, tokenUsageID], desiredKeys: nil)
        #expect(try own[activityDataID]?.get().recordType == "ActivityData")
        #expect(try own[tokenUsageID]?.get().recordType == "TokenUsage")

        var other = ActivityDataAggregate(date: date)
        other.turnCount = 3
        let otherActivityData = CKRecord(
            recordType: "ActivityData",
            recordID: CKRecord.ID(recordName: ActivityDataSyncRecord.recordName(deviceID: "other", date: date), zoneID: Self.zone)
        )
        try ActivityDataRecordCodec.apply(other.syncedAggregate, deviceID: "other", to: otherActivityData)
        await database.storeRecord(otherActivityData)
        try await database.storeRecord(Self.tokenUsageRecord(TokenUsageSyncRecord(deviceID: "other", date: date, tokenUsage: Self.counts(900))))

        let combined = await sync.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [turn], trigger: .manual)
        let snapshot = HistorySnapshot(localActivityDataAggregates: [local], syncedActivityDataRecords: combined.activityData, currentDeviceID: combined.currentDeviceID)
        #expect(snapshot.activityData.first?.turnCount == 5)
        #expect(combined.tokenUsageByDate?[date] == Self.counts(1000))
        #expect(await database.savedTypes.filter { $0 == "ActivityData" }.count == 1)
        #expect(await database.savedTypes.filter { $0 == "TokenUsage" }.count == 1)

        local.turnCount = 1
        turn.tokenUsage = Self.counts(50)
        let reduced = await sync.synchronizeIfEnabled(localActivityDataAggregates: [local], localTokenUsageAggregates: [turn], trigger: .manual)
        let updated = HistorySnapshot(localActivityDataAggregates: [local], syncedActivityDataRecords: reduced.activityData, currentDeviceID: reduced.currentDeviceID)
        #expect(updated.activityData.first?.turnCount == 4)
        #expect(reduced.tokenUsageByDate?[date] == Self.counts(950))
        #expect(await database.activityDataRecords().count == 2)
        let saved = try #require(try await database.records(for: [activityDataID], desiredKeys: nil)[activityDataID]?.get())
        #expect(try ActivityDataRecordCodec.remoteDailyRecord(from: saved)?.activityData.turnCount == 1)
    }

    private static func counts(_ input: Int64) -> TokenUsage {
        TokenUsage(inputTokens: input, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: input)
    }

    private static func tokenUsageRecord(_ daily: TokenUsageSyncRecord) throws -> CKRecord {
        let record = CKRecord(recordType: TokenUsageSync.recordType, recordID: TokenUsageSync.recordID(daily.id, zoneID: zone))
        try TokenUsageSync.apply(daily, to: record)
        return record
    }

    @Test(arguments: [nil, TokenUsage.zero, TokenUsage(
        inputTokens: 100, cachedInputTokens: 20, cacheWriteInputTokens: 5,
        outputTokens: 10, reasoningOutputTokens: 2, totalTokens: 110
    )])
    func cloudDailyTokenUsageAlwaysEncodeAllQuantityKeys(tokenUsage: TokenUsage?) throws {
        let daily = TokenUsageSyncRecord(deviceID: "device", date: "2026-10-12", tokenUsage: tokenUsage)
        let record = try Self.tokenUsageRecord(daily)
        #expect(record.recordID.recordName == "tokenUsage_device_2026-10-12")
        #expect(Set(record.allKeys()) == ["schemaVersion", "aggregationVersion", "deviceID", "date", "tokenUsage", "updatedAt"])
        let data = try #require(record["tokenUsage"] as? Data)
        let counts = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(counts.keys) == ["inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens"])
        if let tokenUsage {
            #expect(try JSONDecoder().decode(TokenUsage.self, from: data) == tokenUsage)
        } else {
            #expect(counts.values.allSatisfy { $0 is NSNull })
        }
        let restored = try #require(try TokenUsageSync.dailyRecord(from: record))
        #expect(restored.hasSameData(as: daily))
        #expect(restored.updatedAt == record["updatedAt"] as? Date)
        record["deviceID"] = "other" as CKRecordValue
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSync.dailyRecord(from: record) }
    }

    @Test func cloudDailyTokenUsageRejectIncompleteKeysAndInvalidQuantities() throws {
        let daily = TokenUsageSyncRecord(deviceID: "device", date: "2026-10-12", tokenUsage: .zero)
        let record = try Self.tokenUsageRecord(daily)
        let data = try #require(record["tokenUsage"] as? Data)
        var counts = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        counts.removeValue(forKey: "outputTokens")
        record["tokenUsage"] = try JSONSerialization.data(withJSONObject: counts) as CKRecordValue
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSync.dailyRecord(from: record) }
        counts["outputTokens"] = -1
        record["tokenUsage"] = try JSONSerialization.data(withJSONObject: counts) as CKRecordValue
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSync.dailyRecord(from: record) }
        counts["outputTokens"] = NSNull()
        record["tokenUsage"] = try JSONSerialization.data(withJSONObject: counts) as CKRecordValue
        #expect(try TokenUsageSync.dailyRecord(from: record)?.tokenUsage == nil)
    }

    @Test func dailyTokenUsageReplaceOneDeviceDateIncludingDecreasesAndZero() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        var daily = Self.turn(0)
        daily.tokenUsage = Self.counts(300)
        let recordID = TokenUsageSync.recordID("tokenUsage_device_\(daily.date)", zoneID: Self.zone)
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: Self.zone)
        #expect(await database.savedTypes == ["TokenUsage"])
        #expect(try await service.snapshot(local: [daily], accountScopedDeviceID: "device")[daily.date] == Self.counts(300))
        #expect(await service.hasPendingUpdates(local: [daily], accountScopedDeviceID: "device") == false)
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: Self.zone)
        #expect(await database.savedTypes == ["TokenUsage"])
        daily.tokenUsage = Self.counts(250)
        #expect(await service.hasPendingUpdates(local: [daily], accountScopedDeviceID: "device"))
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: Self.zone)
        let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == Self.counts(250))
        #expect(try Self.cachedDailyCount(in: directory.url) == 1)
        daily.tokenUsage = .zero
        try await service.synchronize(local: [daily], accountScopedDeviceID: "device", zoneID: Self.zone)
        #expect(try await service.snapshot(local: [daily], accountScopedDeviceID: "device")[daily.date] == .zero)
    }

    @Test(arguments: [100, 900] as [Int64])
    func deviceDailyContributionsStayIsolatedAndStableAcrossRestart(otherCount: Int64) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        var local = Self.turn(0)
        local.tokenUsage = Self.counts(100)
        let date = local.date
        let other = TokenUsageSyncRecord(deviceID: "other", date: date, tokenUsage: Self.counts(otherCount))
        let otherRecord = try Self.tokenUsageRecord(other)
        await database.storeRecord(otherRecord)
        let service = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await service.synchronize(local: [local], accountScopedDeviceID: "device", zoneID: Self.zone)
        #expect(try await service.snapshot(local: [local], accountScopedDeviceID: "device")[date] == Self.counts(100 + otherCount))
        let localID = TokenUsageSync.recordID("tokenUsage_device_\(date)", zoneID: Self.zone)
        let saved = try #require(try await database.records(for: [localID], desiredKeys: nil)[localID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == Self.counts(100))
        let cacheURL = directory.url.appendingPathComponent("Sync/tokenUsage.json")
        let cache = try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: Data(contentsOf: cacheURL))
        let before = try #require(cache.records[localID.recordName])
        #expect(before.updatedAt != nil)
        let restarted = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        #expect(await restarted.hasPendingUpdates(local: [local], accountScopedDeviceID: "device") == false)
        try await restarted.synchronize(local: [local], accountScopedDeviceID: "device", zoneID: Self.zone)
        let after = try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: Data(contentsOf: cacheURL))
        #expect(after.records[before.id] == before)
        #expect(await database.savedTypes == ["TokenUsage"])
        #expect(try await restarted.snapshot(local: [local], accountScopedDeviceID: "new-account")[date] == Self.counts(100))
        #expect(try await restarted.snapshot(local: [], accountScopedDeviceID: "device")[date] == Self.counts(100 + otherCount))
    }

    @Test func rebuiltLocalObservationsReplaceCloudDailyTotalsWithoutCloudTurnState() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let observation = TestFixtures.tokenUsageObservation(at: now, tokenUsage: Self.counts(100))
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        var old = try #require(try await store.recordObservations([observation], now: now).first)
        old.tokenUsage = Self.counts(120)
        try directory.seedTokenUsageAggregates([old])
        let database = SyncDatabaseFixture()
        let sync = TokenUsageSync(database: database, directoryURL: directory.url, isEnabled: { true })
        try await sync.synchronize(local: [old], accountScopedDeviceID: "device", zoneID: Self.zone)
        let date = HistoryStorage.dateKey(for: now)
        _ = try await store.rebuild(for: [date])
        let aggregates = try await store.persistedAggregates(now: now)
        try await sync.synchronize(local: aggregates, accountScopedDeviceID: "device", zoneID: Self.zone)
        let recordID = TokenUsageSync.recordID("tokenUsage_device_\(date)", zoneID: Self.zone)
        let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == Self.counts(100))
        #expect(await sync.hasPendingUpdates(local: aggregates, accountScopedDeviceID: "device") == false)
        try HistoryDatabase(directoryURL: directory.url).execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        let recovered = try await TokenUsageHistoryStore(directoryURL: directory.url).refresh(now: now)
        try await sync.synchronize(local: recovered, accountScopedDeviceID: "device", zoneID: Self.zone)
        #expect(await database.savedTypes == ["TokenUsage", "TokenUsage"])
    }

    @Test func incompleteLocalHistoryPreservesCloudDailyUsageUntilSourceIsRepaired() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let sync = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let history = HistoryService(directoryURL: directory.url, syncService: sync)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        func entry(_ name: String, count: Int64) throws -> Data {
            let observation = TestFixtures.tokenUsageObservation(id: name, at: now, tokenUsage: Self.counts(count))
            return try AppServerEventRecord(tokenUsage: observation, recordedAt: now).jsonLineData()
        }
        try directory.replaceHistory(entry("first", count: 100) + entry("second", count: 200), date: date)
        let initial = await history.loadSnapshot(synchronize: true)
        #expect(initial.tokenUsageByDate[date] == Self.counts(300))
        let deviceID = try #require(ActivityDataSyncStore(directoryURL: directory.url).loadState().deviceID)
        let recordID = TokenUsageSync.recordID("tokenUsage_\(deviceID)_\(date)", zoneID: Self.zone)
        try HistoryDatabase(directoryURL: directory.url).execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        try directory.replaceHistory(entry("first", count: 80) + entry("second", count: 200), date: date)
        try HistoryDatabase(directoryURL: directory.url).execute("UPDATE events SET payload = ? WHERE identity = 'tokenUsage:second'", [.data(Data("broken".utf8))])

        for _ in 0 ..< 2 {
            let partial = await history.loadSnapshot(synchronize: true)
            #expect(partial.tokenUsageByDate[date] == Self.counts(300))
            let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
            #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == Self.counts(300))
        }
        #expect(await database.savedTypes.filter { $0 == "TokenUsage" }.count == 1)

        try HistoryDatabase(directoryURL: directory.url).execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        try directory.replaceHistory(entry("first", count: 80) + entry("second", count: 200), date: date)
        let repaired = await history.loadSnapshot(synchronize: true)
        #expect(repaired.tokenUsageByDate[date] == Self.counts(280))
        let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == Self.counts(280))
        #expect(await database.savedTypes.filter { $0 == "TokenUsage" }.count == 2)
    }
}

extension SyncRecoveryTests {
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
            let id = CKRecord.ID(recordName: recordName, zoneID: Self.zone)
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
