import Foundation
import Testing

struct TurnTokenCumulativeTests {
    private let now = TestFixtures.now

    @Test func firstObservationIsPersistedAndRepeatedNotificationsCountEachFieldOnce() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let first = try await store.record(TestFixtures.tokenSample(1000))
        #expect(first.turns["root"] == nil)
        let total = TokenUsage(inputTokens: 1180, cachedInputTokens: 80, cacheWriteInputTokens: 10, outputTokens: 20, reasoningOutputTokens: 5, totalTokens: 1200)
        let sample = TokenUsageSample(
            observedAt: now,
            threadID: "main",
            turnID: "root",
            turnStartedAt: now,
            current: TokenUsageUpdate(total: total, last: TestFixtures.tokenUsage(200), modelContextWindow: 10000)
        )
        let recorded = try await store.record(sample)
        #expect(recorded.turns["root"] == TokenUsage(
            inputTokens: 180,
            cachedInputTokens: 80,
            cacheWriteInputTokens: 10,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            totalTokens: 200
        ))
        #expect(try await store.record(sample).turns == recorded.turns)
        var repeated = sample
        repeated.id = UUID().uuidString
        #expect(try await store.record(repeated).position == recorded.position)
        let observations = try directory.historyRecords().compactMap(\.tokenUsage)
        #expect(observations.count == 2)
        #expect(observations.first?.previous == observations.first?.current.total)
        #expect(observations.last?.current.modelContextWindow == 10000)
        #expect(try await store.refresh(now: now).first?.tokenUsage.totalTokens == 200)
    }

    @Test func successiveRestartsIncludeOfflineDifferencesWithoutCountingFirstTotal() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        for (totals, expected) in [([1000, 1500], 500), ([2200, 2500], 1500), ([3100, 3300], 2300)] {
            let store = TokenUsageHistoryStore(directoryURL: directory.url)
            for total in totals {
                _ = try await store.record(TestFixtures.tokenSample(Int64(total), start: now))
            }
            #expect(try await store.snapshot(threadID: "main").turns["root"]?.totalTokens == Int64(expected))
            #expect(try await store.refresh(now: now).first?.tokenUsage.totalTokens == Int64(expected))
        }
        let restarted = TokenUsageHistoryStore(directoryURL: directory.url)
        #expect(try await restarted.snapshot(threadID: "main").turns["root"]?.totalTokens == 2300)
        _ = try await restarted.rebuild(for: [HistoryStorage.dateKey(for: now)])
        #expect(try await restarted.persistedAggregates(now: now).first?.tokenUsage.totalTokens == 2300)
    }

    @Test func newTurnRetainsThreadBaselineAndLateTerminalUsageKeepsItsTurn() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        _ = try await store.record(TestFixtures.tokenSample(1000))
        _ = try await store.record(TestFixtures.tokenSample(1200))
        _ = try await store.record(TestFixtures.tokenSample(1250, turn: "next"))
        let result = try await store.record(TestFixtures.tokenSample(1270, turn: "root"))
        #expect(result.turns["root"]?.totalTokens == 220)
        #expect(result.turns["next"]?.totalTokens == 50)
        #expect(try await store.refresh(now: now).first?.tokenUsage.totalTokens == 270)
    }

    @Test func childThreadsHaveIndependentBaselinesAndRestoreIntoResolvedRoot() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        var reducer = AppServerActivityReducer()
        for (thread, turn, baseline, current) in [("main", "root", 100, 130), ("child", "child-turn", 500, 580), ("grandchild", "grand-turn", 700, 720)] {
            _ = try await store.record(TestFixtures.tokenSample(Int64(baseline), thread: thread, turn: turn))
            try await reducer.applyTokenUsage(store.record(TestFixtures.tokenSample(Int64(current), thread: thread, turn: turn)))
            _ = reducer.reconcile(
                thread: ActivityThread(id: thread, status: .init(type: .active), origin: .main, parentThreadID: thread == "main" ? nil : "main"),
                turns: [ActivityTurn(id: turn, status: .running, rootTurnId: "root", startedAt: now)],
                now: now
            )
        }
        let root = ActivityTurnReference(threadID: "main", turnID: "root")
        let request = TaskTokenUsageRequest(
            root: root, expectedAgentThreadIDs: ["child", "grandchild"],
            references: [root, .init(threadID: "child", turnID: "child-turn"), .init(threadID: "grandchild", turnID: "grand-turn")]
        )
        #expect(request.tokenUsage(from: Array(reducer.states.values), requiresFinalTokenUsage: false)?.totalTokens == 130)
        #expect(try await store.refresh(now: now).first?.tokenUsage.totalTokens == 130)
    }

    @Test func crossMidnightUsesKnownTurnStartAndUnknownStartUsesObservationDate() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let yesterday = Calendar.current.startOfDay(for: now).addingTimeInterval(-30)
        _ = try await store.record(TestFixtures.tokenSample(100, at: yesterday, start: yesterday))
        _ = try await store.record(TestFixtures.tokenSample(150, at: now, start: yesterday))
        _ = try await store.record(TestFixtures.tokenSample(180, turn: "unknown", at: now))
        let daily = try await TokenUsageAggregate.tokenUsageByDate(store.refresh(now: now), now: now)
        #expect(daily[HistoryStorage.dateKey(for: yesterday)]?.totalTokens == 50)
        #expect(daily[HistoryStorage.dateKey(for: now)]?.totalTokens == 30)
    }

    @Test func failedTransactionAndRetriedOldSampleNeverAdvanceOrRollbackBaseline() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let first = TestFixtures.tokenSample(100)
        _ = try await store.record(first)
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("CREATE TRIGGER reject_sample BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        let sample = TestFixtures.tokenSample(150)
        await #expect(throws: (any Error).self) { try await store.record(sample) }
        #expect(try await store.snapshot(threadID: "main").turns["root"] == nil)
        try database.execute("DROP TRIGGER reject_sample")
        #expect(try await store.record(sample).turns["root"]?.totalTokens == 50)
        _ = try await store.record(TestFixtures.tokenSample(200))
        #expect(try await store.record(sample).turns["root"]?.totalTokens == 100)
        #expect(try await store.record(first).turns["root"]?.totalTokens == 100)
        #expect(try await store.record(TestFixtures.tokenSample(230)).turns["root"]?.totalTokens == 130)
    }

    @Test func contextWindowSentinelOnlyRebaselinesAndDoesNotPolluteFollowingIncrements() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        _ = try await store.record(TestFixtures.tokenSample(100))
        _ = try await store.record(TestFixtures.tokenSample(120))
        for (input, total) in [(0, 1000), (20, 1020), (30, 1030)] {
            let usage = TokenUsage(
                inputTokens: Int64(input),
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: Int64(total)
            )
            let sample = TokenUsageSample(
                observedAt: now, threadID: "main", turnID: "root", turnStartedAt: now, current: TokenUsageUpdate(total: usage, last: .zero)
            )
            _ = try await store.record(sample)
        }
        #expect(try await store.snapshot(threadID: "main").turns["root"]?.totalTokens == 50)
        #expect(try await store.refresh(now: now).first?.tokenUsage.totalTokens == 50)
    }

    @Test func explicitZeroObservationIsDifferentFromMissingChildUsage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        #expect(try await store.snapshot(threadID: "child").turns["child-turn"] == nil)
        #expect(try await store.record(TestFixtures.tokenSample(0, thread: "child", turn: "child-turn")).turns["child-turn"] == .zero)
    }

    @Test func initialBaselineStaysHiddenAfterRestoreAndFirstIncrementIsDisplayed() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let baseline = try await store.record(TestFixtures.tokenSample(10000))
        #expect(baseline.position > 0)
        #expect(baseline.turns["root"] == nil)

        let restarted = TokenUsageHistoryStore(directoryURL: directory.url)
        #expect(try await restarted.snapshot(threadID: "main").turns["root"] == nil)
        #expect(try await restarted.record(TestFixtures.tokenSample(10000)).turns["root"] == nil)
        let updated = try await restarted.record(TestFixtures.tokenSample(12000))
        #expect(updated.turns["root"]?.totalTokens == 2000)
        #expect(updated.position > baseline.position)
        #expect(try await store.snapshot(threadID: "main").turns == updated.turns)
        #expect(try await store.refresh(now: now).first?.tokenUsage.totalTokens == 2000)
    }

    @Test func knownThreadBaselineKeepsNewTurnZeroAndFirstIncrement() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        _ = try await store.record(TestFixtures.tokenSample(10000))
        let nextTurn = try await store.record(TestFixtures.tokenSample(10000, turn: "next"))
        #expect(nextTurn.turns["root"] == nil)
        #expect(nextTurn.turns["next"] == .zero)
        #expect(try await store.record(TestFixtures.tokenSample(12000, turn: "next")).turns["next"]?.totalTokens == 2000)
    }

    @Test func recordingPauseAndReconnectPreserveCommittedBaseline() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        var reducer = AppServerActivityReducer()
        _ = try await store.record(TestFixtures.tokenSample(20))
        reducer.threads["main"] = ActivityThread(id: "main", origin: .main)
        reducer.setTokenUsageRecordingEnabled(false)
        let input = try TestFixtures.decode(ActivityInput.self, """
        {"method":"thread/tokenUsage/updated","params":{"threadId":"main","turnId":"root","tokenUsage":{
        "total":{"inputTokens":500,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":500},
        "last":{"inputTokens":0,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":0}}}}
        """)
        _ = reducer.consume(input, now: now)
        #expect(reducer.takeTokenUsageSamples().isEmpty)
        reducer.reconnect()
        reducer.setTokenUsageRecordingEnabled(true)
        _ = reducer.consume(input, now: now)
        for sample in reducer.takeTokenUsageSamples() {
            try await reducer.applyTokenUsage(store.record(sample))
        }
        #expect(reducer.tokenUsageTurns[.init(threadID: "main", turnID: "root")]?.totalTokens == 480)
    }

    @Test func olderRestorationCannotOverwriteNewlyCommittedUsage() {
        var reducer = AppServerActivityReducer()
        reducer.applyTokenUsage(TokenUsageThreadSnapshot(threadID: "main", position: 2, turns: ["root": TestFixtures.tokenUsage(30)]))
        reducer.applyTokenUsage(TokenUsageThreadSnapshot(threadID: "main", position: 1, turns: ["root": TestFixtures.tokenUsage(10)]))
        #expect(reducer.tokenUsageTurns[.init(threadID: "main", turnID: "root")]?.totalTokens == 30)
    }
}
