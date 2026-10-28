import CloudKit
import Foundation
import Testing

struct HistoryServiceTests {
    @Test func sameSourceRecalculationCanReduceCountsWithoutDeletingRecord() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let before = try #require(await fixture.database.activityDataRecords().first)
        let result = try await fixture.history.rebuildData(for: [fixture.date], synchronize: true)
        let after = try #require(await fixture.database.activityDataRecords().first)
        #expect(before.recordID == after.recordID)
        #expect(try SyncTestFixtures.activityDataEventCount(before) == 9)
        #expect(try SyncTestFixtures.activityDataEventCount(after) == 1)
        #expect(!result.summary.isSyncPending)
        #expect(await fixture.database.deletedIDs.isEmpty)
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
        let unsupported = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "future", zoneID: SyncTestFixtures.zone))
        unsupported["schemaVersion"] = 999 as CKRecordValue
        await fixture.database.injectChangesRecord(unsupported)
        let result = await fixture.history.loadSnapshot(synchronize: true)
        #expect(!result.isActivityDataComplete)
        #expect(try Data(contentsOf: cacheURL) == before)
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
    }

    @Test func failedUploadPreservesRemoteAndRetriesAfterRestart() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let outcome = try await fixture.history.rebuildData(for: [fixture.date], synchronize: false)
        #expect(outcome.summary.isSyncPending)
        await fixture.database.failActivityDataUpload(on: fixture.date)
        _ = await fixture.history.loadSnapshot(synchronize: true)
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
        await fixture.database.repair()
        let restarted = HistoryService(directoryURL: fixture.directory.url, syncService: fixture.sync)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 1)
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
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        #expect(await fixture.database.deletedIDs.isEmpty)
        try fixture.directory.replaceHistory(original, date: fixture.date)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: true, trigger: .auto)
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 1)
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
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
        _ = await fixture.history.loadSnapshot(synchronize: true)
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 1)
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
        #expect(try SyncTestFixtures.activityDataEventCount(remote) == 2)
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
        #expect(try await SyncTestFixtures.activityDataEventCount(fixture.database.activityDataRecords().first) == 9)
    }

    @Test func partialTokenUsageFailureIsReportedWithoutClaimingWholeDaySuccess() async throws {
        let fixture = try await HistoryRebuildFixture()
        defer { await #expect(throws: Never.self) { try await fixture.directory.removeAfterClosingHistory() } }
        let now = Date()
        let good = TestFixtures.tokenUsageObservation(id: "good", at: now, tokenUsage: .zero)
        let bad = TokenUsageObservation(id: "bad", observedAt: now, previous: SyncTestFixtures.counts(10), current: TokenUsageUpdate(total: .zero, last: .zero))
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
        #expect(try SyncTestFixtures.activityDataEventCount(updated) == previous.eventCount)
        #expect(updated["aggregationVersion"] as? Int == AggregationVersion.activityData)
        #expect(!outcome.summary.isSyncPending)
        #expect(await fixture.database.activityDataRecords().count == 1)
    }

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

    @Test func incompleteLocalHistoryPreservesCloudDailyUsageUntilSourceIsRepaired() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = SyncDatabaseFixture()
        let sync = SyncService(database: database, directoryURL: directory.url, isEnabled: { true })
        let history = HistoryService(directoryURL: directory.url, syncService: sync)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        func entry(_ name: String, count: Int64) throws -> Data {
            let observation = TestFixtures.tokenUsageObservation(id: name, at: now, tokenUsage: SyncTestFixtures.counts(count))
            return try AppServerEventRecord(tokenUsage: observation, recordedAt: now).jsonLineData()
        }
        try directory.replaceHistory(entry("first", count: 100) + entry("second", count: 200), date: date)
        let initial = await history.loadSnapshot(synchronize: true)
        #expect(initial.tokenUsageByDate[date] == SyncTestFixtures.counts(300))
        let deviceID = try #require(ActivityDataSyncStore(directoryURL: directory.url).loadState().deviceID)
        let recordID = TokenUsageSync.recordID("tokenUsage_\(deviceID)_\(date)", zoneID: SyncTestFixtures.zone)
        try HistoryDatabase(directoryURL: directory.url).execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        try directory.replaceHistory(entry("first", count: 80) + entry("second", count: 200), date: date)
        try HistoryDatabase(directoryURL: directory.url).execute("UPDATE events SET payload = ? WHERE identity = 'tokenUsage:second'", [.data(Data("broken".utf8))])

        for _ in 0 ..< 2 {
            let partial = await history.loadSnapshot(synchronize: true)
            #expect(partial.tokenUsageByDate[date] == SyncTestFixtures.counts(300))
            let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
            #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == SyncTestFixtures.counts(300))
        }
        #expect(await database.savedTypes.filter { $0 == "TokenUsage" }.count == 1)

        try HistoryDatabase(directoryURL: directory.url).execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        try directory.replaceHistory(entry("first", count: 80) + entry("second", count: 200), date: date)
        let repaired = await history.loadSnapshot(synchronize: true)
        #expect(repaired.tokenUsageByDate[date] == SyncTestFixtures.counts(280))
        let saved = try #require(try await database.records(for: [recordID], desiredKeys: nil)[recordID]?.get())
        #expect(try TokenUsageSync.dailyRecord(from: saved)?.tokenUsage == SyncTestFixtures.counts(280))
        #expect(await database.savedTypes.filter { $0 == "TokenUsage" }.count == 2)
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
