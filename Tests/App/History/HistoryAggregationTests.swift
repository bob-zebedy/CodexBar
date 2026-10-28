import Foundation
import Testing

struct HistoryAggregationTests {
    @Test(arguments: [(nil as [String]?, 1), ([], 1), (["unknown"], 1), (["read"], 1), (["search", "read", "read"], 3)])
    func toolCountExpandsCommandActions(actions: [String]?, expected: Int) {
        var accumulator = makeAccumulator()
        accumulator.record(commandEvent(.toolStarted, actions: actions))
        let started = accumulator.finalized(identifierStorage: .retained)
        #expect(started.eventCount == 1)
        #expect(started.toolStartedCount == expected)
        #expect(started.metrics.toolCallCount == expected)

        accumulator.record(commandEvent(.toolCompleted, actions: actions))
        let completed = accumulator.finalized(identifierStorage: .retained)
        #expect(completed.eventCount == 2)
        #expect(completed.toolStartedCount == expected)
        #expect(completed.toolCompletedCount == expected)
        #expect(completed.metrics.toolCallCount == expected)
        #expect(completed.syncedAggregate.metrics.toolCallCount == expected)
    }

    @Test(arguments: [false, true])
    func incrementalAggregationMatchesFullReplay(withCommandActions: Bool) {
        let firstEvents = withCommandActions ? [
            commandEvent(.toolStarted, actions: ["search", "read", "read"]),
            commandEvent(.toolCompleted, actions: ["search", "read", "read"]),
            TestFixtures.event(.toolStarted)
        ] : [TestFixtures.event(), TestFixtures.event(.toolCompleted)]
        let laterEvents = withCommandActions
            ? [TestFixtures.event(.toolCompleted)]
            : [TestFixtures.event(.toolStarted), TestFixtures.event(turn: "turn-b")]
        var full = makeAccumulator()
        (firstEvents + laterEvents).forEach { full.record($0) }
        var initial = makeAccumulator()
        firstEvents.forEach { initial.record($0) }
        var incremental = ActivityDataAccumulator(appending: initial.finalized(identifierStorage: .retained))
        laterEvents.forEach { incremental.record($0) }
        let aggregate = full.finalized(identifierStorage: .retained)
        #expect(aggregate.metrics.toolCallCount == (withCommandActions ? 4 : 1))
        #expect(aggregate.eventCount == 4)
        #expect(aggregate.turnIDs == (withCommandActions ? ["turn-a"] : ["turn-a", "turn-b"]))
        #expect(incremental.finalized(identifierStorage: .retained) == aggregate)
        #expect(full.finalized(identifierStorage: .compacted).metrics.toolCallCount == (withCommandActions ? 4 : 1))
    }

    @Test func aggregateJSONLinesPreserveSlashesAndStableBytes() throws {
        var first = TestFixtures.aggregate()
        first.position = 42
        first.projectCounts = ["/projects/a": 1, "/projects/z": 2]
        first.modelCounts = ["model/name": 3]
        var second = first
        second.projectCounts = Dictionary(uniqueKeysWithValues: first.projectCounts.sorted { $0.key > $1.key })
        let local = try first.jsonLineData()
        let synced = try first.syncedAggregate.jsonLineData()
        #expect(try local == (second.jsonLineData()))
        #expect(try synced == (second.syncedAggregate.jsonLineData()))
        for data in [local, synced] {
            let text = try #require(String(bytes: data, encoding: .utf8))
            #expect(text.contains("/projects/a"))
            #expect(text.contains("model/name"))
            #expect(!text.contains(#"\/"#))
            #expect(data.last == JSONLines.newlineByte)
            #expect(data.filter { $0 == JSONLines.newlineByte }.count == 1)
        }
        #expect(try JSONLines.decoder.decode(ActivityDataAggregate.self, from: local) == first)
        #expect(try JSONLines.decoder.decode(SyncedActivityData.self, from: synced) == first.syncedAggregate)
        let syncedFields = try #require(JSONSerialization.jsonObject(with: synced) as? [String: Any])
        #expect(syncedFields["position"] == nil)
    }

    @Test func syncStateIsIsolatedByApplicationRoot() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let debugRoot = directory.url.appendingPathComponent("CodexBar Data Debug", isDirectory: true)
        let releaseRoot = directory.url.appendingPathComponent("CodexBar Data", isDirectory: true)
        let debugStore = ActivityDataSyncStore(directoryURL: debugRoot)
        let releaseStore = ActivityDataSyncStore(directoryURL: releaseRoot)
        try releaseStore.saveState(ActivityDataSyncState(deviceID: "release"))
        #expect(debugStore.loadState().deviceID == nil)
        try debugStore.saveState(ActivityDataSyncState(deviceID: "debug"))
        #expect(releaseStore.loadState().deviceID == "release")
        let restored = ActivityDataSyncStore(directoryURL: debugRoot)
        #expect(restored.loadState().deviceID == "debug")
        #expect(SyncCloudKit.zoneName == "CodexBarAppZone")
        let root = AppStorage.directoryURL()
        #if DEBUG
            #expect(root.lastPathComponent == "CodexBar Data Debug")
        #else
            #expect(root.lastPathComponent == "CodexBar Data")
        #endif
        #expect(AppServerLogStore.defaultDirectory == root.appendingPathComponent("Logs", isDirectory: true))
    }

    @Test func identifierFieldsUseModelPropertyNames() throws {
        let aggregate = try TestFixtures.decode(
            ActivityDataAggregate.self,
            #"{"schemaVersion":1,"aggregationVersion":1,"position":0,"date":"2026-09-15","threadIDs":["thread-a"],"turnIDs":["turn-a"]}"#
        )
        #expect(aggregate.threadIDs == ["thread-a"])
        #expect(aggregate.turnIDs == ["turn-a"])
        let encoded = try JSONEncoder().encode(aggregate)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["threadIDs"] as? [String] == ["thread-a"])
        #expect(fields["turnIDs"] as? [String] == ["turn-a"])
        #expect(fields["threadIds"] == nil)
        #expect(fields["turnIds"] == nil)

        let record = try TestFixtures.decode(ActivityDataSyncRecord.self, """
        {"deviceID":"device-a","recordName":"activityData_device-a_2026-09-15","schemaVersion":1,"aggregationVersion":1,"date":"2026-09-15","activityData":{}}
        """)
        #expect(record.deviceID == "device-a")
        let recordData = try JSONEncoder().encode(record)
        let recordFields = try #require(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        #expect(recordFields["deviceID"] as? String == "device-a")
        #expect(recordFields["deviceIdentifier"] == nil)
    }

    @Test func missingEventCountsRemainUnavailableThroughBothStorageFormats() throws {
        let aggregate = try TestFixtures.decode(ActivityDataAggregate.self, #"{"schemaVersion":1,"aggregationVersion":1,"position":0,"date":"2026-09-15","turnCompletedCount":0}"#)
        #expect(aggregate.eventCount == nil)
        #expect(aggregate.turnAbortedCount == nil)
        #expect(aggregate.turnCompletedCount == 0)
        let local = try JSONDecoder().decode(ActivityDataAggregate.self, from: aggregate.jsonLineData())
        let synced = try JSONDecoder().decode(SyncedActivityData.self, from: aggregate.syncedAggregate.jsonLineData())
        #expect(local == aggregate)
        #expect(synced.turnAbortedCount == nil)
        #expect(synced.turnCompletedCount == 0)
    }

    @Test func completionEventsCannotStandInForUniqueTurnCounts() throws {
        var aggregate = try TestFixtures.decode(ActivityDataAggregate.self, #"{"schemaVersion":1,"aggregationVersion":1,"position":0,"date":"2026-09-15","turnCompletedCount":9}"#)
        aggregate.normalizeIdentifierStorage(retainsIdentifiers: false)
        #expect(aggregate.turnCount == nil)
        #expect(aggregate.metrics.turnCount == nil)
        let synced = try JSONDecoder().decode(SyncedActivityData.self, from: aggregate.syncedAggregate.jsonLineData())
        #expect(synced.turnCount == nil)
        #expect(synced.metrics.turnCount == nil)
    }

    @Test func eventPairsAndIdentifiersAreCountedWithoutDoubleCounting() {
        var accumulator = makeAccumulator()
        for name in [ActivityDataEventKind.turnStarted, .toolStarted, .toolCompleted, .compactionStarted, .compactionCompleted, .subagentStarted, .subagentEnded] {
            accumulator.record(TestFixtures.event(name))
        }
        accumulator.record(TestFixtures.event(.turnCompleted, thread: "terminal-only", turn: "terminal-only"))
        accumulator.record(TestFixtures.event(.turnAborted, thread: "interrupt-only", turn: "interrupt-only"))
        let retained = accumulator.finalized(identifierStorage: .retained)
        let compacted = accumulator.finalized(identifierStorage: .compacted)
        #expect(retained.eventCount == 9)
        #expect(retained.threadIDs == ["interrupt-only", "terminal-only", "thread-a"])
        #expect(retained.turnIDs == ["turn-a"])
        #expect(retained.metrics.toolCallCount == 1)
        #expect(retained.metrics.contextCompactionCount == 1)
        #expect(retained.metrics.subagentCount == 1)
        #expect(retained.metrics.turnAbortedCount == 1)
        #expect(retained.metrics == compacted.metrics)
        #expect(compacted.threadIDs == nil)
        #expect(compacted.turnIDs == nil)
        #expect(!compacted.supportsIncrementalAggregation)
    }

    @Test func historicalAggregationIncludesAutoReviewEvents() {
        var accumulator = makeAccumulator()
        accumulator.record(TestFixtures.event(origin: .autoReview))
        #expect(accumulator.finalized(identifierStorage: .compacted).metrics.turnCount == 1)
    }

    @Test func permissionRequestsCountEachRequest() {
        var accumulator = makeAccumulator()
        for turn in ["a", "b", "c", "d"] {
            accumulator.record(TestFixtures.event(.approvalRequested, turn: turn))
        }
        let aggregate = accumulator.finalized(identifierStorage: .retained)
        #expect(aggregate.approvalRequestedCount == 4)
        #expect(aggregate.eventCount == 4)
    }

    @Test func missingHistoricalMetricContributesZeroToDisplay() {
        var known = TestFixtures.aggregate()
        known.turnAbortedCount = 3
        var unknown = TestFixtures.aggregate()
        unknown.turnAbortedCount = nil
        #expect(known.metrics.adding(unknown.metrics).turnAbortedCount == 3)
        #expect(known.metrics.adding(known.metrics).turnAbortedCount == 6)
    }

    @Test func modelRankingHasDeterministicTiesAndIgnoresZeroCounts() {
        var aggregate = TestFixtures.aggregate()
        aggregate.modelCounts = ["z-model": 3, "a-model": 3, "unused": 0]
        #expect(aggregate.metrics.mostUsedModel == "a-model")
        aggregate.modelCounts = ["unused": 0]
        #expect(aggregate.metrics.mostUsedModel == nil)
    }

    @Test func compactingLegacyIdentifiersPreservesUniqueCounts() throws {
        var aggregate = try TestFixtures.decode(ActivityDataAggregate.self, """
        {"schemaVersion":1,"aggregationVersion":1,"position":0,"date":"2026-09-15","threadCount":0,"threadIDs":["a","a","b"],"turnIDs":["x","x"],"turnCompletedCount":9}
        """)
        aggregate.normalizeIdentifierStorage(retainsIdentifiers: false)
        #expect(aggregate.threadCount == 2)
        #expect(aggregate.turnCount == 1)
        #expect(aggregate.threadIDs == nil)
    }

    @Test func syncExportContainsCountsWithoutRawTaskIdentifiers() throws {
        var accumulator = makeAccumulator()
        accumulator.record(TestFixtures.event())
        let data = try accumulator.finalized(identifierStorage: .retained).syncedAggregate.jsonLineData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["threadIDs"] == nil)
        #expect(object["sourceCheckpoint"] == nil)
        #expect(object["turnIDs"] == nil)
        #expect(object["threadCount"] as? Int == 1)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("thread-a"))
    }

    private func makeAccumulator() -> ActivityDataAccumulator {
        ActivityDataAccumulator(rebuilding: "2026-09-15")
    }

    private func commandEvent(_ kind: ActivityDataEventKind, actions: [String]?) -> ActivityDataRecord {
        ActivityDataRecord(
            timestamp: TestFixtures.now, name: kind.rawValue, origin: .main, cwd: "/projects/example",
            toolName: nil, commandActionTypes: actions, model: "gpt-5", effort: "high",
            threadID: "thread-a", turnID: "turn-a", agentThreadID: nil
        )
    }
}

struct HistoryMergeTests {
    @Test func localDailyCountsReplaceCachedCountsEvenWhenLower() throws {
        let local = TestFixtures.aggregate(events: 2, turns: 1)
        let remote = try record(TestFixtures.aggregate(events: 4, turns: 2))
        #expect(snapshot(local, [remote]).activityData.first?.turnCount == 1)
        #expect(snapshot(TestFixtures.aggregate(events: 6, turns: 3), [remote]).activityData.first?.turnCount == 3)
    }

    @Test func localAndCachedDeviceCountOnceWhileOtherDevicesAdd() throws {
        let local = TestFixtures.aggregate()
        let remote = try record(TestFixtures.aggregate())
        let otherDevice = try record(TestFixtures.aggregate(turns: 4), device: "other")
        #expect(snapshot(local, [remote, otherDevice]).activityData.first?.turnCount == 5)
    }

    @Test func remoteOnlyDaysRemainVisible() throws {
        let result = try HistorySnapshot(localActivityDataAggregates: [], syncedActivityDataRecords: [record(TestFixtures.aggregate(turns: 4))], currentDeviceID: "device")
        #expect(result.activityData.first?.turnCount == 4)
    }

    private func record(_ aggregate: ActivityDataAggregate, device: String = "device") throws -> ActivityDataSyncRecord {
        try ActivityDataSyncRecord(
            deviceID: device, activityData: aggregate.syncedAggregate,
            recordName: ActivityDataSyncRecord.recordName(deviceID: device, date: aggregate.date)
        )
    }

    private func snapshot(_ local: ActivityDataAggregate, _ remote: [ActivityDataSyncRecord]) -> HistorySnapshot {
        HistorySnapshot(localActivityDataAggregates: [local], syncedActivityDataRecords: remote, currentDeviceID: "device")
    }
}
