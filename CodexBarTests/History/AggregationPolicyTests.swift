import CloudKit
import Foundation
import Testing

struct AggregationPolicyTests {
    @Test func refreshPreservesExistingResultsUntilExplicitRebuild() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        let service = history(in: directory)
        let recorder = ActivityRecorder(directoryURL: directory.url)
        try await recorder.record(event: event(at: now))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let url = HistoryStorage.dailyURL(in: directory.url)
        var old = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: url)).first)
        old.aggregationVersion = 1
        let oldBoundary = try #require(old.sourceCheckpoint?.byteCount)
        old.sourceCheckpoint?.aggregationRanges = [.init(version: 1, end: oldBoundary)]
        old.turnStartedCount = 50
        try old.jsonLineData().write(to: url)
        let unchanged = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .auto)
        #expect(unchanged.counts == nil)
        #expect(try JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: url)).first?.turnStartedCount == 50)

        try await recorder.record(event: event(at: now.addingTimeInterval(1), turn: "second"))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .auto)
        let appended = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: url)).first)
        #expect(appended.turnStartedCount == 51)
        #expect(appended.metrics.turnCount == 2)
        #expect(appended.sourceCheckpoint?.aggregationRanges.first?.version == 1)
        #expect(appended.sourceCheckpoint?.aggregationRanges.last?.version == AggregationVersion.activity)

        _ = try await service.rebuildData(for: [date], synchronize: false)
        let rebuilt = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: url)).first)
        #expect(rebuilt.turnStartedCount == 2)
        #expect(rebuilt.aggregationVersion == AggregationVersion.activity)
        #expect(try rebuilt.sourceCheckpoint?.aggregationRanges == [.init(version: AggregationVersion.activity, end: #require(rebuilt.sourceCheckpoint?.byteCount))])
    }

    @Test func damagedActivityFileRecoversOnlyMissingDates() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let service = history(in: directory)
        let recorder = ActivityRecorder(directoryURL: directory.url)
        try await recorder.record(event: event(at: now))
        try await recorder.record(event: event(at: yesterday))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let url = HistoryStorage.dailyURL(in: directory.url)
        var preserved = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: url)).first { $0.date == HistoryStorage.dateKey(for: yesterday) })
        preserved.turnStartedCount = 40
        try (preserved.jsonLineData() + Data("broken\n".utf8)).write(to: url)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .auto)
        let results = try JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: url))
        #expect(results.first { $0.date == preserved.date }?.turnStartedCount == 40)
        #expect(results.first { $0.date == HistoryStorage.dateKey(for: now) }?.turnStartedCount == 1)
    }

    @Test func expiredInvalidFileDoesNotBlockHealthyDate() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let expired = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400))
        let bad = try directory.write("broken header\n", to: "Events/\(expired).jsonl")
        var state = HistoryMaintenanceState(dirty: [expired])
        state.markPending(expired)
        try HistoryStorage.saveMaintenanceState(state, in: directory.url)
        let recorder = ActivityRecorder(directoryURL: directory.url)
        try await recorder.record(event: event(at: now))
        let service = history(in: directory)
        let result = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(result.counts?.written == 1)
        #expect(result.snapshot.dailyMetrics.first?.turnCount == 1)
        #expect(try String(contentsOf: bad, encoding: .utf8) == "broken header\n")
        #expect(try HistoryStorage.loadMaintenanceState(in: directory.url).dirty.contains(expired))
    }

    @Test func pendingTodayKeepsYesterdaysMetricsVisible() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let recorder = ActivityRecorder(directoryURL: directory.url)
        let service = history(in: directory)
        try await recorder.record(event: event(at: yesterday))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        try await recorder.record(event: event(at: now))
        let snapshot = await service.loadSnapshot()
        let days = UsageHeatmapDay.grid(usage: nil, history: snapshot, columnCount: 2, today: now).compactMap(\.self)
        #expect(days.first { $0.startDate == HistoryStorage.dateKey(for: yesterday) }?.history.turnCount == 1)
        #expect(days.first { $0.startDate == HistoryStorage.dateKey(for: now) }?.history.turnCount == nil)
    }

    @Test func tokenIdentityAndCloudEncodingPreserveAlgorithmVersions() throws {
        let now = Date()
        let id = TokenTurn.identifier(thread: "thread", turn: "turn")
        var turn = TestFixtures.tokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now, usage: .zero)
        turn.aggregationVersion = 1
        let exported = turn.pseudonymized(salt: Data("salt".utf8))
        #expect(exported.aggregationVersion == 1)
        let record = CKRecord(recordType: TokenSync.recordType, recordID: CKRecord.ID(recordName: exported.id))
        TokenSync.apply(exported, to: record)
        #expect(try TokenSync.turn(from: record)?.aggregationVersion == 1)
        let baseline = TokenHistoryBaseline(salt: Data("salt".utf8), turns: [exported.id: exported])
        #expect(baseline.replacement(for: turn) == nil)
        let observation = TokenObservation(turn: turn, rootStartedAt: now, streamID: "stream", sequence: 1, previous: .zero, current: .zero)
        let encoded = try JSONLines.stableEncoder.encode(observation)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let identity = try #require(object["turn"] as? [String: Any])
        #expect(identity["aggregationVersion"] == nil)
        #expect(identity["usage"] == nil)
    }

    @Test func algorithmCompatibilityAcceptsPastAndRejectsFuture() throws {
        try AggregationVersion.require(1, current: 2, name: "test")
        #expect(throws: StorageCompatibilityError.self) { try AggregationVersion.require(3, current: 2, name: "test") }
        #expect(throws: StorageCompatibilityError.self) { try AggregationVersion.require(0, current: 2, name: "test") }
    }

    private func event(at date: Date, turn: String = "first") -> ActivityRecord {
        ActivityRecord(
            timestamp: date, name: ActivityEventKind.turnStarted.rawValue, origin: .main,
            cwd: nil, toolName: nil, model: nil, effort: nil,
            threadID: "thread", turnID: turn, agentID: nil, id: "event-\(date.timeIntervalSince1970)-\(turn)"
        )
    }

    private func history(in directory: TestDirectory) -> HistoryService {
        HistoryService(directoryURL: directory.url, syncService: SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false }))
    }
}

extension AggregationPolicyTests {
    @Test func recoveredTokenResultsReplaceCoveredCloudBaseline() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let id = TokenTurn.identifier(thread: "thread", turn: "turn")
        let observed = TokenUsage(inputTokens: 10, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 10)
        let observation = TokenObservation(
            turn: TokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now),
            rootStartedAt: now, streamID: "stream", sequence: 1, previous: .zero, current: observed
        )
        let store = TokenHistoryStore(directoryURL: directory.url)
        let recorded = try await store.recordObservations([observation], now: now)
        var previous = try #require(recorded.first)
        previous.aggregationVersion = 1
        previous.usage = TokenUsage(inputTokens: 12, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 12)
        let salt = Data("account".utf8)
        let remote = previous.pseudonymized(salt: salt)
        let baseline = TokenHistoryBaseline(salt: salt, turns: [remote.id: remote])
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        // 离线恢复后重新启动, 仍须保留与云端旧结果建立替换关系的能力
        _ = try await store.refresh(now: now)
        let reopened = TokenHistoryStore(directoryURL: directory.url)
        let records = try await reopened.refresh(now: now, baseline: baseline)
        let recovered = try #require(records.first)
        #expect(recovered.usage == observed)
        #expect(!recovered.hasConflict)
        #expect(recovered.aggregationVersion == AggregationVersion.tokens)
        #expect(recovered.ancestorIDs.contains(previous.generationID))
        let merged = try remote.merging(recovered.pseudonymized(salt: salt))
        #expect(merged.usage == observed)
        #expect(merged.aggregationVersion == AggregationVersion.tokens)
        #expect(try await reopened.refresh(now: now, baseline: baseline).first?.generationID == recovered.generationID)
    }

    @Test func partialSourcesKeepKnownValuesVisible() {
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        var aggregate = ActivityAggregate(date: date)
        aggregate.turnCount = 3
        var snapshot = HistorySnapshot(dailyMetrics: [aggregate.metrics])
        snapshot.isActivityComplete = false
        let day = UsageHeatmapDay.grid(usage: nil, history: snapshot, columnCount: 1, today: now).compactMap(\.self).first { $0.startDate == date }
        #expect(day?.history.turnCount == 3)
    }
}
