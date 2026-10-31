import Foundation
import SQLite3
import Testing

@Suite(.tags(.integration))
struct HistoryDatabaseTests {
    @Test func storedCommandActionsPreserveDuplicatesAndDoNotCountCompletionTwice() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        let actions = ["search", "read", "read"]
        let started = Self.record("command:started", at: now, commandActionTypes: actions)
        try database.append(started)
        try database.append(started)
        let first = try database.aggregateActivityData(date: date, now: now)
        #expect(first.eventCount == 1)
        #expect(first.metrics.toolCallCount == 3)

        let completed = Self.record("command:completed", at: now, kind: .toolCompleted, commandActionTypes: actions)
        try database.append(completed)
        let incremental = try database.aggregateActivityData(date: date, now: now)
        #expect(incremental.eventCount == 2)
        #expect(incremental.metrics.toolCallCount == 3)
        let rebuilt = try database.aggregateActivityData(date: date, rebuilding: true, now: now)
        #expect(rebuilt == incremental)
        #expect(rebuilt.syncedAggregate.metrics.toolCallCount == 3)
    }

    @Test func rebuildableDatesIncludeActivityAndTokenOnlyDaysWithinRetention() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        let expired = cutoff.addingTimeInterval(-1)
        for date in [expired, yesterday, now] {
            try database.append(event(UUID().uuidString, at: date))
        }
        for date in [expired, cutoff, now] {
            let observation = TestFixtures.tokenUsageObservation(at: date, tokenUsage: .zero)
            try database.append(AppServerEventRecord(tokenUsage: observation, recordedAt: now))
        }
        #expect(await HistoryStorage.rebuildableEventDateKeys(in: directory.url) == [cutoff, yesterday, now].map(HistoryStorage.dateKey(for:)))
    }

    @Test func committedEventsSurviveRestartAndDeduplicate() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let record = event("one", at: now)
        #expect(try HistoryDatabase(directoryURL: directory.url).append(record))
        #expect(try !HistoryDatabase(directoryURL: directory.url).append(record))
        let database = try HistoryDatabase(directoryURL: directory.url)
        let date = HistoryStorage.dateKey(for: now)
        #expect(try database.pendingActivityDataDates() == [date])
        let first = try database.aggregateActivityData(date: date)
        #expect(first.eventCount == 1)
        #expect(try database.pendingActivityDataDates().isEmpty)
        #expect(try database.aggregateActivityData(date: date) == first)
        #expect(try database.exportJSONLines(date: date) == record.jsonLineData())
    }

    @Test func aggregateAndCursorRollBackTogetherWithoutLosingSource() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        try database.append(event("one", at: now))
        let before = try database.aggregateActivityData(date: date)
        try database.append(event("two", at: now))
        try database.execute("CREATE TRIGGER reject_aggregate BEFORE UPDATE ON aggregates BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        #expect(throws: (any Error).self) { try database.aggregateActivityData(date: date) }
        #expect(try database.activityDataAggregates() == [before])
        #expect(try database.pendingActivityDataDates() == [date])
        var count = 0
        try database.entries { _ in count += 1 }
        #expect(count == 2)
        try database.execute("DROP TRIGGER reject_aggregate")
        #expect(try database.aggregateActivityData(date: date).eventCount == 2)
        #expect(try database.pendingActivityDataDates().isEmpty)
    }

    @Test func transactionFailureAndCancellationReleaseWriter() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        #expect(throws: (any Error).self) {
            try database.transaction {
                try database.execute("INSERT INTO days(date) VALUES ('test')")
                throw CancellationError()
            }
        }
        #expect(try database.dates().isEmpty)
        try database.transaction { try database.execute("INSERT INTO days(date) VALUES ('test')") }
        #expect(try database.dates() == ["test"])
    }

    @Test func separateConnectionsSerializeWritersAndKeepAllEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url
        let now = Date()
        _ = try HistoryDatabase(directoryURL: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0 ..< 3 {
                group.addTask {
                    let database = try HistoryDatabase(directoryURL: url)
                    for index in 0 ..< 12 {
                        try database.append(Self.record("\(writer)-\(index)", at: now))
                    }
                }
            }
            try await group.waitForAll()
        }
        let aggregate = try HistoryDatabase(directoryURL: url).aggregateActivityData(date: HistoryStorage.dateKey(for: now))
        #expect(aggregate.eventCount == 36)
    }

    @Test func compactedIdentityStillDeduplicatesLateEvents() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let old = now.addingTimeInterval(-7 * 86400)
        let date = HistoryStorage.dateKey(for: old)
        try database.append(event("one", at: old))
        let first = try database.aggregateActivityData(date: date, now: now)
        #expect(first.threadIDs == nil)
        #expect(first.threadCount == 1)
        try database.append(event("two", at: old))
        let updated = try database.aggregateActivityData(date: date, now: now)
        let rebuilt = try database.aggregateActivityData(date: date, rebuilding: true, now: now)
        #expect(updated == rebuilt)
        #expect(updated.eventCount == 2)
        #expect(updated.threadCount == 1)
        #expect(updated.turnCount == 1)
    }

    @Test func retentionRemovesSourceAndAggregateInOneTransaction() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        let expired = cutoff.addingTimeInterval(-86400)
        for date in [expired, cutoff, now] {
            try database.append(event(UUID().uuidString, at: date))
            _ = try database.aggregateActivityData(date: HistoryStorage.dateKey(for: date), now: now)
        }
        #expect(try database.prune(now: now) == 1)
        #expect(try database.dates().count == 2)
        #expect(try database.activityDataAggregates().count == 2)
        #expect(throws: HistoryDataRebuildError.self) {
            try database.aggregateActivityData(date: HistoryStorage.dateKey(for: expired), rebuilding: true, now: now)
        }
        var count = 0
        try database.entries { _ in count += 1 }
        #expect(count == 2)
    }

    @Test func unsupportedDatabaseIsRejectedWithoutResettingData() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.append(event("one", at: Date()))
        try database.execute("PRAGMA user_version = 999")
        #expect(throws: StorageCompatibilityError.unsupportedFormat("HistoryDatabase", 999)) {
            try HistoryDatabase(directoryURL: directory.url)
        }
        #expect(try database.dates().count == 1)
    }

    @Test func brokenDateDoesNotPreventHealthyDateCommit() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        try database.append(event("bad", at: yesterday))
        try database.append(event("good", at: now))
        try database.execute("UPDATE events SET payload = ? WHERE identity = ?", [.data(Data("broken".utf8)), .text("activityData:bad")])
        #expect(throws: (any Error).self) { try database.aggregateActivityData(date: HistoryStorage.dateKey(for: yesterday)) }
        #expect(try database.aggregateActivityData(date: HistoryStorage.dateKey(for: now)).eventCount == 1)
        #expect(try database.pendingActivityDataDates() == [HistoryStorage.dateKey(for: yesterday)])
    }

    @Test func actualTaskCancellationRollsBackAndReleasesDatabaseLock() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url
        let writer = Task.detached {
            let database = try HistoryDatabase(directoryURL: url)
            try database.transaction {
                try database.execute("INSERT INTO days(date) VALUES ('cancelled')")
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await writer.value }
        let reopened = try HistoryDatabase(directoryURL: url)
        #expect(try reopened.dates().isEmpty)
        try reopened.transaction { try reopened.execute("INSERT INTO days(date) VALUES ('cancelled')") }
        #expect(try reopened.dates() == ["cancelled"])
    }

    @Test func damagedAggregateIsPendingWhileOtherDatesRemainReadable() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let today = HistoryStorage.dateKey(for: now)
        let yesterday = HistoryStorage.dateKey(for: now.addingTimeInterval(-86400))
        try database.append(event("one", at: now))
        try database.append(event("two", at: now.addingTimeInterval(-86400)))
        _ = try database.aggregateActivityData(date: today)
        let good = try database.aggregateActivityData(date: yesterday)
        try database.execute(
            "UPDATE aggregates SET activityData = ? WHERE date = ?",
            [.data(Data("broken".utf8)), .text(today)]
        )
        #expect(try database.activityDataAggregates() == [good])
        #expect(try database.pendingActivityDataDates() == [today])
        #expect(try database.aggregateActivityData(date: today).eventCount == 1)
        #expect(try database.pendingActivityDataDates().isEmpty)
    }

    private func tokenUsage(_ count: Int64) -> TokenUsage {
        TokenUsage(inputTokens: count, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: count)
    }

    private func event(_ id: String, at date: Date) -> AppServerEventRecord {
        Self.record(id, at: date)
    }

    private nonisolated static func record(
        _ id: String, at date: Date, kind: ActivityDataEventKind = .toolStarted, commandActionTypes: [String]? = nil
    ) -> AppServerEventRecord {
        AppServerEventRecord(activityData: ActivityDataRecord(
            timestamp: date, name: kind.rawValue, origin: .main, cwd: "/test",
            toolName: "read", commandActionTypes: commandActionTypes, model: nil, effort: nil, threadID: "thread", turnID: "turn", agentThreadID: nil, id: id
        ), recordedAt: date)
    }

    @Test func aggregateColumnsStoreProgressWithEachResultAndLeaveMissingUsageNull() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        try database.append(event("one", at: now))
        let aggregate = try database.aggregateActivityData(date: HistoryStorage.dateKey(for: now))
        var connection: OpaquePointer?
        #expect(sqlite3_open_v2(directory.url.appendingPathComponent("event.db").path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        let sql = """
        SELECT (SELECT group_concat(name, ',') FROM pragma_table_info('aggregates')), activityData, tokenUsage,
            (SELECT group_concat(name, ',') FROM pragma_table_info('days'))
        FROM aggregates
        """
        #expect(sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        let columns = try #require(sqlite3_column_text(statement, 0))
        #expect(String(cString: columns) == "date,activityData,tokenUsage")
        let dayColumns = try #require(sqlite3_column_text(statement, 3))
        #expect(String(cString: dayColumns) == "date")
        #expect(sqlite3_column_type(statement, 1) == SQLITE_BLOB)
        #expect(sqlite3_column_type(statement, 2) == SQLITE_NULL)
        let bytes = try #require(sqlite3_column_blob(statement, 1))
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fields["position"] as? Int == 1)
        #expect(fields["aggregationVersion"] as? Int == AggregationVersion.activityData)
        #expect(try JSONLines.decoder.decode(ActivityDataAggregate.self, from: data) == aggregate)
        #expect(try database.pendingTokenUsageDates().isEmpty)
        #expect(try database.tokenUsageAggregates().isEmpty)
    }

    @Test(arguments: ["activityData", "tokenUsage"], ["outdatedAlgorithm", "missingPosition", "negativePosition"])
    func invalidAggregateMetadataRebuildsOnlyItsOwnColumn(kind: String, damage: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        try database.append(event("one", at: now))
        try database.append(AppServerEventRecord(tokenUsage: TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20)), recordedAt: now))
        let activityData = try database.aggregateActivityData(date: date)
        let usage = try database.aggregateTokenUsage(date: date)
        let mutation = switch damage {
        case "outdatedAlgorithm": "json_set(CAST(\(kind) AS TEXT), '$.aggregationVersion', 0)"
        case "missingPosition": "json_remove(CAST(\(kind) AS TEXT), '$.position')"
        default: "json_set(CAST(\(kind) AS TEXT), '$.position', -1)"
        }
        try database.execute("UPDATE aggregates SET \(kind) = CAST(\(mutation) AS BLOB)")
        #expect(try database.pendingActivityDataDates() == (kind == "activityData" ? [date] : []))
        #expect(try database.pendingTokenUsageDates() == (kind == "tokenUsage" ? [date] : []))
        if kind == "activityData" {
            #expect(try database.aggregateActivityData(date: date) == activityData)
        } else {
            #expect(try database.aggregateTokenUsage(date: date) == usage)
        }
        #expect(try database.activityDataAggregates() == [activityData])
        #expect(try database.tokenUsageAggregates() == [usage])
        #expect(try database.pendingActivityDataDates().isEmpty)
        #expect(try database.pendingTokenUsageDates().isEmpty)
    }

    @Test func damagedAggregateColumnDoesNotReplaceTheOtherSummary() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        try database.append(event("one", at: now))
        try database.append(AppServerEventRecord(tokenUsage: TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20)), recordedAt: now))
        _ = try database.aggregateActivityData(date: date)
        _ = try database.aggregateTokenUsage(date: date)
        try database.execute("UPDATE aggregates SET activityData = CAST('broken' AS BLOB)")
        try database.append(AppServerEventRecord(tokenUsage: TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(30)), recordedAt: now))
        #expect(try database.aggregateTokenUsage(date: date).tokenUsage == tokenUsage(50))
        #expect(try database.pendingActivityDataDates() == [date])
        #expect(try database.aggregateActivityData(date: date).eventCount == 1)
        #expect(try database.tokenUsageAggregates().first?.tokenUsage == tokenUsage(50))

        try database.execute("UPDATE aggregates SET tokenUsage = CAST('broken' AS BLOB)")
        try database.append(event("two", at: now))
        #expect(try database.aggregateActivityData(date: date).eventCount == 2)
        #expect(try database.pendingTokenUsageDates() == [date])
        #expect(try database.aggregateTokenUsage(date: date).tokenUsage == tokenUsage(50))
        #expect(try database.activityDataAggregates().first?.eventCount == 2)
        #expect(try database.pendingTokenUsageDates().isEmpty)
    }

    @Test func mismatchedEventKindCannotAdvanceTheAggregateCursor() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        try database.append(event("one", at: now))
        try database.execute("UPDATE events SET kind = 'tokenUsage'")
        #expect(throws: StorageCompatibilityError.incompleteSource) { try database.aggregateTokenUsage(date: date) }
        #expect(try database.tokenUsageAggregates().isEmpty)
        #expect(try database.pendingTokenUsageDates() == [date])
    }

    @Test func activityDataAndTokenUsageTotalsShareOneDayWithoutAdvancingEachOthersCursor() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        try database.append(event("first", at: now))
        try database.append(AppServerEventRecord(tokenUsage: TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20)), recordedAt: now))
        let tokens = try database.aggregateTokenUsage(date: date)
        let activityData = try database.aggregateActivityData(date: date)
        #expect(activityData.position == 1)
        #expect(tokens.position == 2)
        #expect(try database.tokenUsageAggregates() == [tokens])
        #expect(try database.activityDataAggregates() == [activityData])
        #expect(try database.pendingActivityDataDates().isEmpty)
        #expect(try database.pendingTokenUsageDates().isEmpty)

        try database.append(AppServerEventRecord(tokenUsage: TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(30)), recordedAt: now))
        #expect(try database.pendingActivityDataDates().isEmpty)
        #expect(try database.pendingTokenUsageDates() == [date])
        _ = try database.aggregateActivityData(date: date)
        #expect(try database.pendingTokenUsageDates() == [date])
        #expect(try database.aggregateTokenUsage(date: date).tokenUsage == tokenUsage(50))
        #expect(try HistoryDatabase(directoryURL: directory.url).tokenUsageAggregates().first?.position == 3)
        #expect(try database.activityDataAggregates() == [activityData])

        try database.append(event("second", at: now))
        #expect(try database.pendingTokenUsageDates().isEmpty)
        #expect(try database.pendingActivityDataDates() == [date])
        _ = try database.aggregateTokenUsage(date: date)
        #expect(try database.pendingActivityDataDates() == [date])
        #expect(try database.aggregateActivityData(date: date).eventCount == 2)
        #expect(try HistoryDatabase(directoryURL: directory.url).activityDataAggregates().first?.position == 4)
        #expect(try database.tokenUsageAggregates().first?.tokenUsage == tokenUsage(50))
    }

    @Test func failedTokenUsageCommitDoesNotBlockActivityDataInTheSameRow() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let before = try await store.recordObservations([TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(20))], now: now)
        try await store.appendObservation(TestFixtures.tokenUsageObservation(at: now, tokenUsage: tokenUsage(30)), now: now)
        try database.append(event("activityData", at: now))
        try database.execute("CREATE TRIGGER reject_tokenUsage BEFORE UPDATE OF tokenUsage ON aggregates BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        let failed = try await store.loadSnapshot(now: now)
        #expect(failed.coverage == .partial)
        #expect(failed.aggregates == before)
        #expect(try database.aggregateActivityData(date: date).eventCount == 1)
        #expect(try database.tokenUsageAggregates().first?.tokenUsage == tokenUsage(20))
        #expect(try database.pendingActivityDataDates().isEmpty)
        #expect(try database.pendingTokenUsageDates() == [date])
        try database.execute("DROP TRIGGER reject_tokenUsage")
        let recovered = try await store.loadSnapshot(now: now)
        #expect(recovered.coverage == .complete)
        #expect(recovered.aggregates.first?.tokenUsage == tokenUsage(50))
        #expect(try await store.refresh(now: now) == recovered.aggregates)
        #expect(try database.activityDataAggregates().first?.eventCount == 1)
    }
}
