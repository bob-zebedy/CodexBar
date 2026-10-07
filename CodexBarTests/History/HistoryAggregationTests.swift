import CloudKit
import Foundation
import Testing

struct HistoryAggregationTests {
    @Test func aggregateJSONLinesPreserveSlashesAndStableBytes() throws {
        var first = TestFixtures.aggregate()
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
        #expect(try JSONLines.decoder.decode(ActivityAggregate.self, from: local) == first)
        #expect(try JSONLines.decoder.decode(SyncedActivity.self, from: synced) == first.syncedAggregate)
    }

    @Test func syncStateIsIsolatedByApplicationRoot() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let debugRoot = directory.url.appendingPathComponent("CodexBar Data Debug", isDirectory: true)
        let releaseRoot = directory.url.appendingPathComponent("CodexBar Data", isDirectory: true)
        let debugStore = ActivitySyncStore(directoryURL: HistoryStorage.syncDirectoryURL(in: debugRoot))
        let releaseStore = ActivitySyncStore(directoryURL: HistoryStorage.syncDirectoryURL(in: releaseRoot))
        try releaseStore.saveState(SyncState(hashByDate: ["2026-09-15": "release"]))
        #expect(debugStore.loadState().hashByDate.isEmpty)
        try debugStore.saveState(SyncState(hashByDate: ["2026-10-05": "debug"]))
        #expect(releaseStore.loadState().hashByDate["2026-10-05"] == nil)
        let restored = ActivitySyncStore(directoryURL: HistoryStorage.syncDirectoryURL(in: debugRoot))
        #expect(restored.loadState().hashByDate["2026-10-05"] == "debug")
        #expect(SyncCloudKit.zoneName == "CodexBarAppZone")
        let root = AppStorage.directoryURL()
        #if DEBUG
            #expect(root.lastPathComponent == "CodexBar Data Debug")
        #else
            #expect(root.lastPathComponent == "CodexBar Data")
        #endif
        #expect(HistoryStorage.directoryURL() == root)
        #expect(HistoryStorage.syncDirectoryURL() == root.appendingPathComponent("Sync", isDirectory: true))
        #expect(AppServerLogStore.defaultDirectory == root.appendingPathComponent("Logs", isDirectory: true))
    }

    @Test func identifierFieldsUseModelPropertyNames() throws {
        let aggregate = try TestFixtures.decode(ActivityAggregate.self, #"{"date":"2026-09-15","sessionIDs":["session-a"],"turnIDs":["turn-a"]}"#)
        #expect(aggregate.sessionIDs == ["session-a"])
        #expect(aggregate.turnIDs == ["turn-a"])
        let encoded = try JSONEncoder().encode(aggregate)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["sessionIDs"] as? [String] == ["session-a"])
        #expect(fields["turnIDs"] as? [String] == ["turn-a"])
        #expect(fields["sessionIds"] == nil)
        #expect(fields["turnIds"] == nil)

        let record = try TestFixtures.decode(ActivitySyncRecord.self, """
        {"deviceID":"device-a","recordName":"device-a_2026-09-15_source","daily":{"date":"2026-09-15","generationID":"source"}}
        """)
        #expect(record.deviceID == "device-a")
        let recordData = try JSONEncoder().encode(record)
        let recordFields = try #require(JSONSerialization.jsonObject(with: recordData) as? [String: Any])
        #expect(recordFields["deviceID"] as? String == "device-a")
        #expect(recordFields["deviceIdentifier"] == nil)
    }

    @Test func missingEventCountsRemainUnavailableThroughBothStorageFormats() throws {
        let aggregate = try TestFixtures.decode(ActivityAggregate.self, #"{"date":"2026-09-15","turnCompletedCount":0}"#)
        #expect(aggregate.eventCount == nil)
        #expect(aggregate.turnAbortedCount == nil)
        #expect(aggregate.turnCompletedCount == 0)
        let local = try JSONDecoder().decode(ActivityAggregate.self, from: aggregate.jsonLineData())
        let synced = try JSONDecoder().decode(SyncedActivity.self, from: aggregate.syncedAggregate.jsonLineData())
        #expect(local == aggregate)
        #expect(synced.turnAbortedCount == nil)
        #expect(synced.turnCompletedCount == 0)
    }

    @Test func eventPairsAndIdentifiersAreCountedWithoutDoubleCounting() {
        var accumulator = makeAccumulator()
        for name in [ActivityEventKind.sessionStarted, .turnStarted, .toolStarted, .toolCompleted, .compactionStarted, .compactionCompleted, .subagentStarted, .subagentEnded] {
            accumulator.record(TestFixtures.event(name))
        }
        accumulator.record(TestFixtures.event(.turnCompleted, session: "terminal-only", turn: "terminal-only"))
        accumulator.record(TestFixtures.event(.turnAborted, session: "interrupt-only", turn: "interrupt-only"))
        let retained = accumulator.finalized(identifierStorage: .retained)
        let compacted = accumulator.finalized(identifierStorage: .compacted)
        #expect(retained.eventCount == 10)
        #expect(retained.sessionIDs == ["interrupt-only", "session-a", "terminal-only"])
        #expect(retained.turnIDs == ["turn-a"])
        #expect(retained.metrics.toolCallCount == 1)
        #expect(retained.metrics.contextCompactionCount == 1)
        #expect(retained.metrics.subagentCount == 1)
        #expect(retained.metrics.turnAbortedCount == 1)
        #expect(retained.metrics == compacted.metrics)
        #expect(compacted.sessionIDs == nil)
        #expect(compacted.turnIDs == nil)
        #expect(!compacted.supportsIncrementalAggregation)
    }

    @Test func incrementalAggregationMatchesFullReplay() {
        let firstEvents = [TestFixtures.event(.sessionStarted), TestFixtures.event()]
        let laterEvents = [TestFixtures.event(.toolStarted), TestFixtures.event(turn: "turn-b")]
        var full = makeAccumulator()
        (firstEvents + laterEvents).forEach { full.record($0) }
        var initial = makeAccumulator()
        firstEvents.forEach { initial.record($0) }
        var incremental = ActivityAccumulator(
            appending: initial.finalized(identifierStorage: .retained), generationID: "source", generationStartedEmpty: true
        )
        laterEvents.forEach { incremental.record($0) }
        #expect(incremental.finalized(identifierStorage: .retained) == full.finalized(identifierStorage: .retained))
    }

    @Test func historicalAggregationIncludesAutoReviewEvents() {
        var accumulator = makeAccumulator()
        accumulator.record(TestFixtures.event(origin: .autoReview))
        #expect(accumulator.finalized(identifierStorage: .compacted).metrics.turnCount == 1)
    }

    @Test func sessionEndAloneDoesNotCreateAnActiveSession() {
        var accumulator = makeAccumulator()
        accumulator.record(TestFixtures.event(.sessionEnded, turn: nil))
        let aggregate = accumulator.finalized(identifierStorage: .compacted)
        #expect(aggregate.sessionEndedCount == 1)
        #expect(aggregate.metrics.sessionCount == 0)
        #expect(aggregate.metrics.turnCount == 0)
    }

    @Test func unavailableInterruptCountPropagatesAcrossDeviceMetrics() {
        var known = TestFixtures.aggregate()
        known.turnAbortedCount = 3
        var unknown = TestFixtures.aggregate()
        unknown.turnAbortedCount = nil
        #expect(known.metrics.adding(unknown.metrics).turnAbortedCount == nil)
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
        var aggregate = try TestFixtures.decode(ActivityAggregate.self, """
        {"date":"2026-09-15","sessionCount":0,"sessionIDs":["a","a","b"],"turnIDs":["x","x"],"turnCompletedCount":9}
        """)
        aggregate.normalizeIdentifierStorage(retainsIdentifiers: false)
        #expect(aggregate.sessionCount == 2)
        #expect(aggregate.turnCount == 1)
        #expect(aggregate.sessionIDs == nil)
    }

    @Test func syncExportContainsCountsWithoutRawTaskIdentifiers() throws {
        var accumulator = makeAccumulator()
        accumulator.record(TestFixtures.event())
        let data = try accumulator.finalized(identifierStorage: .retained).syncedAggregate.jsonLineData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sessionIDs"] == nil)
        #expect(object["turnIDs"] == nil)
        #expect(object["sessionCount"] as? Int == 1)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("session-a"))
    }

    @Test func cloudDailyCountsRoundTripWithEventNames() throws {
        let counts = [
            "sessionStartedCount": 1, "sessionEndedCount": 2, "turnStartedCount": 3,
            "turnCompletedCount": 4, "turnAbortedCount": 5, "toolStartedCount": 6,
            "toolCompletedCount": 7, "approvalRequestedCount": 8, "compactionStartedCount": 9,
            "compactionCompletedCount": 10, "subagentStartedCount": 11, "subagentEndedCount": 12
        ]
        var fields: [String: Any] = counts
        fields["date"] = "2026-09-15"
        fields["generationID"] = "source"
        let aggregate = try JSONDecoder().decode(
            SyncedActivity.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        let record = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "device-a_2026-09-15_source"))
        ActivityRecordCodec.apply(aggregate, deviceID: "device-a", to: record)
        #expect(Set(record.allKeys()) == Set(counts.keys).union([
            "version", "deviceID", "date", "generationID", "projectCounts", "modelCounts", "updatedAt"
        ]))
        for (name, count) in counts {
            #expect((record[name] as? NSNumber)?.intValue == count)
        }
        let restored = try #require(try ActivityRecordCodec.remoteDailyRecord(from: record))
        #expect(restored.deviceID == "device-a")
        #expect(restored.daily == aggregate)

        record["turnAbortedCount"] = nil
        record["toolStartedCount"] = 0 as CKRecordValue
        let missing = try #require(try ActivityRecordCodec.remoteDailyRecord(from: record))
        #expect(missing.daily.turnAbortedCount == nil)
        #expect(missing.daily.toolStartedCount == 0)
    }

    @Test(arguments: [nil, "", "   "]) func cloudActivityRejectsMissingGeneration(generation: String?) {
        let record = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "device_2026-09-15_source"))
        record["deviceID"] = "device" as CKRecordValue
        record["date"] = "2026-09-15" as CKRecordValue
        record["generationID"] = generation as CKRecordValue?
        #expect(throws: ActivitySyncError.self) { try ActivityRecordCodec.remoteDailyRecord(from: record) }
    }

    @Test func cloudAndCachedActivityRejectMismatchedIdentity() throws {
        let daily = SyncedActivity(date: "2026-09-15", generationID: "source", projectCounts: [:], modelCounts: [:])
        let record = CKRecord(recordType: "Activity", recordID: CKRecord.ID(recordName: "device_2026-09-15"))
        ActivityRecordCodec.apply(daily, deviceID: "device", to: record)
        #expect(throws: ActivitySyncError.self) { try ActivityRecordCodec.remoteDailyRecord(from: record) }
        #expect(throws: DecodingError.self) {
            try TestFixtures.decode(ActivitySyncRecord.self, #"{"deviceID":"device","recordName":"device_2026-09-15","daily":{"date":"2026-09-15","generationID":"source"}}"#)
        }
    }

    private func makeAccumulator() -> ActivityAccumulator {
        ActivityAccumulator(rebuilding: "2026-09-15", generationID: "source", generationStartedEmpty: true, eventCountAvailability: .all)
    }
}

struct HistoryMergeTests {
    @Test func sameGenerationUsesOneMostCompleteContribution() throws {
        let local = TestFixtures.aggregate(events: 2, turns: 1)
        let remote = try record(TestFixtures.aggregate(events: 4, turns: 2))
        #expect(snapshot(local, [remote]).dailyMetrics.first?.turnCount == 2)
        #expect(snapshot(TestFixtures.aggregate(events: 6, turns: 3), [remote]).dailyMetrics.first?.turnCount == 3)
    }

    @Test func freshIndependentGenerationAddsToPreviousContribution() throws {
        let local = TestFixtures.aggregate(generation: "new", fresh: true, turns: 2)
        #expect(try snapshot(local, [record(TestFixtures.aggregate(turns: 3))]).dailyMetrics.first?.turnCount == 5)
    }

    @Test func unverifiedLocalGenerationDoesNotDoubleCountRemoteHistory() throws {
        let local = TestFixtures.aggregate(generation: "unknown", fresh: false, turns: 2)
        #expect(try snapshot(local, [record(TestFixtures.aggregate(turns: 3))]).dailyMetrics.first?.turnCount == 3)
    }

    @Test func sameGenerationDeduplicatesAndOtherDevicesStillAdd() throws {
        let local = TestFixtures.aggregate()
        let remote = try record(TestFixtures.aggregate())
        let otherDevice = try record(TestFixtures.aggregate(turns: 4), device: "other")
        #expect(snapshot(local, [remote, otherDevice]).dailyMetrics.first?.turnCount == 5)
    }

    @Test func remoteOnlyDaysRemainVisible() throws {
        let result = try HistorySnapshot(localAggregates: [], syncedRecords: [record(TestFixtures.aggregate(turns: 4))], currentDeviceID: "device")
        #expect(result.dailyMetrics.first?.turnCount == 4)
    }

    private func record(_ aggregate: ActivityAggregate, device: String = "device") throws -> ActivitySyncRecord {
        let generation = try aggregate.syncedAggregate.requiredGenerationID()
        return try ActivitySyncRecord(
            deviceID: device, daily: aggregate.syncedAggregate,
            recordName: ActivitySyncRecord.recordName(deviceID: device, date: aggregate.date, generation: generation)
        )
    }

    private func snapshot(_ local: ActivityAggregate, _ remote: [ActivitySyncRecord]) -> HistorySnapshot {
        HistorySnapshot(localAggregates: [local], syncedRecords: remote, currentDeviceID: "device")
    }
}
