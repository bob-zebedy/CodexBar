import Foundation
import Testing

@Suite(.tags(.integration))
struct TokenUsageHistoryStoreTests {
    @Test func recordingLeaseTransfersWithoutTwoWriters() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = TokenUsageHistoryStore(directoryURL: directory.url)
        let second = TokenUsageHistoryStore(directoryURL: directory.url)
        #expect(try first.acquireRecordingLease())
        #expect(try !second.acquireRecordingLease())
        first.releaseRecordingLease()
        #expect(try second.acquireRecordingLease())
        second.releaseRecordingLease()
    }

    @Test func dailyTokenUsageDeduplicateRetriesAndRebuildAfterCacheDamage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let first = TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20))
        let second = TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(30), previous: tokenUsage(20))
        let initial = try await store.recordObservations([first, first, second], now: now)
        #expect(initial.first?.tokenUsage == tokenUsage(50))
        #expect(initial.first?.eventCount == 2)
        #expect(try await TokenUsageHistoryStore(directoryURL: directory.url).refresh(now: now) == initial)
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("UPDATE aggregates SET tokenUsage = ?", [.data(Data("broken".utf8))])
        #expect(try await store.refresh(now: now) == initial)
        try database.execute("UPDATE aggregates SET tokenUsage = ?", [.data(Data("broken".utf8))])
        let rebuilt = try await store.rebuild(for: [HistoryStorage.dateKey(for: now)])
        #expect(rebuilt.eventCount == 2)
        #expect(try await store.persistedAggregates(now: now) == initial)
        try database.execute("UPDATE aggregates SET tokenUsage = NULL")
        #expect(try await store.refresh(now: now) == initial)
    }

    @Test func tokenRebuildChecksOnlyRequestedDatesWithSourceEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = TestFixtures.now
        let dates = (0 ..< 5).map { now.addingTimeInterval(Double($0) * 86400) }
        let keys = dates.map(HistoryStorage.dateKey(for:))
        for index in [0, 1, 2] {
            try database.append(AppServerEventRecord(
                tokenUsage: TestFixtures.tokenUsageObservation(at: dates[index], tokenUsage: tokenUsage(10)), recordedAt: now
            ))
        }
        try database.append(event("activity-only", at: dates[3]))
        try database.append(event("mixed", at: dates[0]))
        let requested = [keys[2], keys[0], keys[3], keys[4], keys[2]]
        #expect(try database.tokenUsageAggregates().isEmpty)
        #expect(try database.tokenUsageDates(in: requested) == [keys[0], keys[2]])
        #expect(try database.tokenUsageDates(in: []).isEmpty)

        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let rebuilt = try await store.rebuild(for: requested)
        #expect(rebuilt.dateKeys == [keys[0], keys[2]])
        #expect(rebuilt.eventCount == 2)
        #expect(rebuilt.failedDateKeys.isEmpty)
        #expect(try database.tokenUsageAggregates().map(\.date) == [keys[0], keys[2]])
        #expect(try database.pendingTokenUsageDates() == [keys[1]])
    }

    @Test func observedDateSurvivesDelayedWriteAcrossMidnight() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        let before = midnight.addingTimeInterval(-1)
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let first = TestFixtures.tokenUsageObservation(at: before, tokenUsage: tokenUsage(20))
        let second = TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(30), previous: tokenUsage(20))
        let result = try await store.recordObservations([first, second], now: now)
        #expect(TokenUsageAggregate.tokenUsageByDate(result, now: now) == [HistoryStorage.dateKey(for: before): tokenUsage(20), HistoryStorage.dateKey(for: now): tokenUsage(30)])
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
        #expect(try await store.refresh(now: now) == result)
    }

    @Test(arguments: [-1, 1])
    func storedTokenDatesSurviveLocalDateChanges(dayOffset: Int) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = TestFixtures.now
        let localDate = HistoryStorage.dateKey(for: now)
        let storedDate = HistoryStorage.dateKey(for: now.addingTimeInterval(Double(dayOffset) * 86400))
        func sample(_ id: String, _ count: Int64) -> TokenUsageSample {
            let usage = tokenUsage(count)
            return TokenUsageSample(
                id: id, observedAt: now, threadID: "thread", turnID: "turn", turnStartedAt: now,
                current: TokenUsageUpdate(total: usage, last: usage)
            )
        }
        do {
            let database = try HistoryDatabase(directoryURL: directory.url)
            try database.appendTokenUsage(sample("baseline", 0))
            try database.appendTokenUsage(sample("first", 100))
            let initial = try database.aggregateTokenUsage(date: localDate)
            try database.appendTokenUsage(sample("pending", 130))
            // 模拟在另一时区保存的日期, 避免修改并行测试共享的系统时区
            var stored = TokenUsageAggregate(date: storedDate, tokenUsage: initial.tokenUsage, eventCount: initial.eventCount)
            stored.position = initial.position
            try database.transaction {
                try database.execute("INSERT INTO days(date) VALUES (?)", [.text(storedDate)])
                try database.execute("UPDATE events SET date = ?", [.text(storedDate)])
                try database.execute("INSERT INTO aggregates(date, tokenUsage) VALUES (?, ?)", [.text(storedDate), .data(JSONLines.stableEncoder.encode(stored))])
                try database.execute("DELETE FROM days WHERE date = ?", [.text(localDate)])
            }
        }

        let database = try HistoryDatabase(directoryURL: directory.url)
        let latest = sample("after-switch", 150)
        try database.appendTokenUsage(latest)
        try database.appendTokenUsage(latest)
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let snapshot = try await store.loadSnapshot(now: now)
        #expect(snapshot.coverage == .complete)
        #expect(Dictionary(uniqueKeysWithValues: snapshot.aggregates.map { ($0.date, $0.tokenUsage.totalTokens) }) == [storedDate: 130, localDate: 20])
        #expect(snapshot.aggregates.reduce(0) { $0 + $1.eventCount } == 4)
        #expect(try database.pendingTokenUsageDates().isEmpty)
        #expect(try database.tokenUsageSnapshot(threadID: "thread").turns["turn"]?.totalTokens == 150)

        let rebuilt = try await store.rebuild(for: [storedDate, localDate])
        #expect(rebuilt.failedDateKeys.isEmpty)
        #expect(rebuilt.dateKeys == [storedDate, localDate].sorted())
        #expect(rebuilt.eventCount == 4)
        #expect(try await store.persistedAggregates(now: now) == snapshot.aggregates)
        let expectedDates = dayOffset > 0 ? [localDate] : [storedDate, localDate].sorted()
        #expect(TokenUsageAggregate.tokenUsageByDate(snapshot.aggregates, now: now).keys.sorted() == expectedDates)
        #expect(try TokenUsageSyncRecord.dailyRecords(local: snapshot.aggregates, deviceID: "device", now: now).map(\.date) == expectedDates)
        let later = now.addingTimeInterval(86400)
        #expect(TokenUsageAggregate.tokenUsageByDate(snapshot.aggregates, now: later).values.reduce(0) { $0 + $1.totalTokens } == 150)
    }

    @Test func unchangedSnapshotReadsSavedDailyTotalsWithoutReplayingEventsOrWriting() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let saved = try await store.recordObservations([TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20))], now: now)
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("UPDATE events SET payload = ? WHERE kind = 'tokenUsage'", [.data(Data("broken".utf8))])
        try database.execute("CREATE TRIGGER reject_tokenUsage BEFORE UPDATE OF tokenUsage ON aggregates BEGIN SELECT RAISE(ABORT, 'unexpected rewrite'); END")
        let snapshot = try await store.loadSnapshot(now: now)
        #expect(snapshot.coverage == .complete)
        #expect(snapshot.aggregates == saved)
    }

    @Test func failedTokenUsageDayPreservesTotalAndHealthyDayStillAdvances() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        _ = try await store.recordObservations([TestFixtures.tokenUsageObservation(at: yesterday, tokenUsage: tokenUsage(10))], now: now)
        let bad = TestFixtures.tokenUsageObservation(at: yesterday, tokenUsage: tokenUsage(30))
        try await store.appendObservation(bad, now: now)
        try await store.appendObservation(TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20)), now: now)
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("UPDATE events SET payload = ? WHERE identity = ?", [.data(Data("broken".utf8)), .text("tokenUsage:" + bad.id)])
        for _ in 0 ..< 2 {
            let snapshot = try await store.loadSnapshot(now: now)
            #expect(snapshot.coverage == .partial)
            #expect(TokenUsageAggregate.tokenUsageByDate(snapshot.aggregates, now: now) == [
                HistoryStorage.dateKey(for: yesterday): tokenUsage(10), HistoryStorage.dateKey(for: now): tokenUsage(20)
            ])
        }
        let rebuilt = try await store.rebuild(for: [HistoryStorage.dateKey(for: yesterday)])
        #expect(rebuilt.eventCount == 0)
        #expect(rebuilt.failedDateKeys == [HistoryStorage.dateKey(for: yesterday)])
    }

    @Test func missingObservationCannotReplaceSavedDailyTotalDuringRebuild() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let second = TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20))
        let before = try await store.recordObservations([TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(10)), second], now: now)
        try HistoryDatabase(directoryURL: directory.url).execute("DELETE FROM events WHERE identity = ?", [.text("tokenUsage:" + second.id)])
        let rebuilt = try await store.rebuild(for: [HistoryStorage.dateKey(for: now)])
        #expect(rebuilt.failedDateKeys == [HistoryStorage.dateKey(for: now)])
        #expect(try await store.persistedAggregates(now: now) == before)
    }

    @Test func tokenUsageRetentionRemovesDailyAggregateWithItsObservedEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let expired = HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400)
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let observations = [(expired, "expired", Int64(20)), (now, "current", Int64(30))].map { date, turn, count in
            TokenUsageObservation(
                observedAt: date, threadID: "thread", turnID: turn, previous: .zero,
                current: TokenUsageUpdate(total: tokenUsage(count), last: tokenUsage(count))
            )
        }
        _ = try await store.recordObservations(observations, now: now)
        let database = try HistoryDatabase(directoryURL: directory.url)
        #expect(try database.tokenUsageSnapshot(threadID: "thread").turns.count == 2)
        #expect(try database.prune(now: now) == 1)
        #expect(try database.tokenUsageAggregates().count == 1)
        #expect(try database.tokenUsageAggregates().first?.tokenUsage == tokenUsage(30))
        let retained = try database.tokenUsageSnapshot(threadID: "thread")
        #expect(retained.turns["expired"] == nil)
        #expect(retained.turns["current"] == tokenUsage(30))
        let future = now.addingTimeInterval(212 * 86400)
        #expect(try HistoryDatabase(directoryURL: directory.url).prune(now: future) == 1)
        #expect(try database.prune(now: future) == 0)
        #expect(try database.tokenUsageSnapshot(threadID: "thread").turns.isEmpty)
    }

    private func tokenUsage(_ count: Int64) -> TokenUsage {
        TokenUsage(inputTokens: count, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: count)
    }

    private func event(_ id: String, at date: Date) -> AppServerEventRecord {
        AppServerEventRecord(activityData: ActivityDataRecord(
            timestamp: date, name: ActivityDataEventKind.toolStarted.rawValue, origin: .main, cwd: "/test",
            toolName: "read", commandActionTypes: nil, model: nil, effort: nil, threadID: "thread", turnID: "turn", agentThreadID: nil, id: id
        ), recordedAt: date)
    }

    @Test func incrementalTokenStorageRetainsAllCountersAcrossRestart() async throws {
        let now = TestFixtures.now
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let tokenUsage = TokenUsage(
            inputTokens: 100,
            cachedInputTokens: 50,
            cacheWriteInputTokens: 10,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            totalTokens: 120
        )
        let observation = TestFixtures.tokenUsageObservation(
            id: "stream", at: now, tokenUsage: tokenUsage
        )
        _ = try await store.recordObservations([observation, observation], now: now)
        let restarted = TokenUsageHistoryStore(directoryURL: directory.url)
        let records = try await restarted.refresh(now: now)
        #expect(records.count == 1)
        #expect(records.first?.tokenUsage == tokenUsage)
    }

    @Test func rebuildUsesObservedRecordsAndContinuesCollecting() async throws {
        let now = TestFixtures.now
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let tokenUsage = TokenUsage(
            inputTokens: 100,
            cachedInputTokens: 30,
            cacheWriteInputTokens: 10,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            totalTokens: 120
        )
        let first = TestFixtures.tokenUsageObservation(id: "stream", at: now, tokenUsage: tokenUsage)
        _ = try await store.recordObservations([first], now: now)
        let rebuilt = try await store.rebuild(for: [CodexDateFormat.dayString(from: now)])
        #expect(rebuilt.eventCount == 1)
        let second = TestFixtures.tokenUsageObservation(
            id: "second", at: now,
            tokenUsage: tokenUsage
        )
        _ = try await store.recordObservations([second], now: now.addingTimeInterval(2))
        let records = try await store.refresh(now: now.addingTimeInterval(2))
        #expect(records.first?.tokenUsage == tokenUsage.adding(tokenUsage))
    }
}
