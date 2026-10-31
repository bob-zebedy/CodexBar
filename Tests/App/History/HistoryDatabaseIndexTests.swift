import Foundation
import SQLite3
import Testing

@Suite(.tags(.integration))
struct HistoryDatabaseIndexTests {
    @Test(arguments: [false, true])
    func existingDatabaseUpdatesIndexesWithoutChangingHistory(newIndexExists: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let now = TestFixtures.now
        let date = HistoryStorage.dateKey(for: now)
        let activity = AppServerEventRecord(activityData: ActivityDataRecord(
            timestamp: now, name: "toolStarted", origin: .main, cwd: nil, toolName: "read",
            model: nil, effort: nil, threadID: "thread", turnID: "turn", agentThreadID: nil, id: "event"
        ))
        let usage = AppServerEventRecord(tokenUsage: TestFixtures.tokenUsageObservation(at: now, tokenUsage: .zero), recordedAt: now)
        try database.append(activity)
        try database.append(usage)
        let activityAggregate = try database.aggregateActivityData(date: date, now: now)
        let tokenAggregate = try database.aggregateTokenUsage(date: date)
        let originalEvents = try database.exportJSONLines(date: date)
        try database.execute("CREATE INDEX IF NOT EXISTS events_date ON events(date, position)")
        try createLegacyThreadIndex(in: database)
        if newIndexExists {
            try database.execute("CREATE INDEX IF NOT EXISTS codexbar_events_date_kind_position ON events(date, kind, position)")
        } else {
            try database.execute("DROP INDEX IF EXISTS codexbar_events_date_kind_position")
            try database.execute("DROP INDEX IF EXISTS codexbar_events_token_usage_thread")
        }

        let reopened = try HistoryDatabase(directoryURL: directory.url)
        #expect(try values(in: directory, sql: "PRAGMA user_version") == ["1"])
        #expect(try values(in: directory, sql: """
        SELECT name FROM sqlite_schema WHERE name IN ('events_date', 'events_token_usage_thread')
        """).isEmpty)
        #expect(try values(in: directory, sql: "SELECT name FROM pragma_index_info('codexbar_events_date_kind_position') ORDER BY seqno") == ["date", "kind", "position"])
        #expect(try values(in: directory, sql: """
        SELECT name FROM pragma_index_list('events') WHERE name = 'codexbar_events_token_usage_thread' AND partial = 1
        """) == ["codexbar_events_token_usage_thread"])
        #expect(try reopened.exportJSONLines(date: date) == originalEvents)
        #expect(try reopened.activityDataAggregates() == [activityAggregate])
        #expect(try reopened.tokenUsageAggregates() == [tokenAggregate])
        #expect(try !reopened.append(activity))
        #expect(try !reopened.append(usage))
        #expect(try reopened.pendingActivityDataDates().isEmpty)
        #expect(try reopened.pendingTokenUsageDates().isEmpty)
    }

    @Test func currentIndexesAllowReopeningWithoutTakingTheWriterLock() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let schema = try values(in: directory, sql: "PRAGMA schema_version")
        try database.execute("BEGIN IMMEDIATE")
        defer { try? database.execute("ROLLBACK") }

        let reopened = try HistoryDatabase(directoryURL: directory.url)
        #expect(try reopened.dates().isEmpty)
        #expect(try values(in: directory, sql: "PRAGMA schema_version") == schema)
        #expect(try values(in: directory, sql: "SELECT name FROM pragma_index_info('codexbar_events_date_kind_position') ORDER BY seqno") == ["date", "kind", "position"])
    }

    @Test func failedIndexCommitRollsBackAndCanRetryOnReopen() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let reader = try HistoryDatabase(directoryURL: directory.url)
        try reader.execute("CREATE INDEX IF NOT EXISTS events_date ON events(date, position)")
        try createLegacyThreadIndex(in: reader)
        try reader.execute("DROP INDEX IF EXISTS codexbar_events_date_kind_position")
        try reader.execute("DROP INDEX IF EXISTS codexbar_events_token_usage_thread")
        try reader.execute("INSERT INTO days(date) VALUES ('2026-10-20')")
        let schema = try values(in: directory, sql: "PRAGMA schema_version")
        try reader.execute("BEGIN")
        defer { try? reader.execute("ROLLBACK") }
        _ = try reader.dates()

        do {
            _ = try HistoryDatabase(directoryURL: directory.url)
            Issue.record("Expected the reader to prevent the index transaction from committing")
        } catch let error as HistoryDatabase.Failure {
            #expect(error.code == SQLITE_BUSY)
        }
        #expect(try values(in: directory, sql: "PRAGMA schema_version") == schema)
        #expect(try values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE name = 'events_date'") == ["events_date"])
        #expect(try values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE name = 'events_token_usage_thread'") == ["events_token_usage_thread"])
        #expect(try values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE name = 'codexbar_events_date_kind_position'").isEmpty)
        #expect(try values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE name = 'codexbar_events_token_usage_thread'").isEmpty)
        #expect(try reader.dates() == ["2026-10-20"])
        try reader.execute("ROLLBACK")

        let reopened = try HistoryDatabase(directoryURL: directory.url)
        #expect(try reopened.dates() == ["2026-10-20"])
        #expect(try values(in: directory, sql: """
        SELECT name FROM sqlite_schema WHERE name IN ('events_date', 'events_token_usage_thread')
        """).isEmpty)
        #expect(try values(in: directory, sql: "SELECT name FROM pragma_index_info('codexbar_events_date_kind_position') ORDER BY seqno") == ["date", "kind", "position"])
    }

    @Test func obsoleteManagedIndexesAreRemovedWithoutTouchingOtherIndexes() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("CREATE INDEX codexbar_events_retired_v1 ON events(kind)")
        try database.execute("CREATE INDEX codexbar_events_retired_v3 ON events(date)")
        try database.execute("CREATE INDEX \"codexbar_events_retired\"\"name\" ON events(position)")
        try database.execute("CREATE INDEX external_events_kind ON events(kind)")
        try database.execute("CREATE INDEX codexbarXevents_kind ON events(kind)")
        try database.execute("CREATE UNIQUE INDEX codexbar_events_unique_identity ON events(identity)")
        try database.execute("CREATE INDEX codexbar_events_other_table ON days(date)")
        let original = try Set(values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE type = 'index'"))

        _ = try HistoryDatabase(directoryURL: directory.url)
        let remaining = try Set(values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE type = 'index'"))
        #expect(remaining == original.subtracting(["codexbar_events_retired_v1", "codexbar_events_retired_v3", "codexbar_events_retired\"name"]))
        #expect(try values(in: directory, sql: "PRAGMA integrity_check") == ["ok"])
    }

    @Test func missingThreadIndexIsRestoredWithoutRebuildingCurrentIndexes() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("DROP INDEX codexbar_events_token_usage_thread")
        let original = try values(in: directory, sql: """
        SELECT name || ':' || rootpage || ':' || sql FROM sqlite_schema
        WHERE type = 'index' AND sql IS NOT NULL ORDER BY name
        """)

        _ = try HistoryDatabase(directoryURL: directory.url)
        #expect(try values(in: directory, sql: """
        SELECT name FROM pragma_index_list('events') WHERE name = 'codexbar_events_token_usage_thread' AND partial = 1
        """) == ["codexbar_events_token_usage_thread"])
        let remaining = try values(in: directory, sql: """
        SELECT name || ':' || rootpage || ':' || sql FROM sqlite_schema
        WHERE type = 'index' AND sql IS NOT NULL AND name != 'codexbar_events_token_usage_thread' ORDER BY name
        """)
        #expect(remaining == original)
    }

    @Test func legacyThreadIndexIsRemovedAfterOlderVersionRecreatesIt() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        let original = try values(in: directory, sql: """
        SELECT name || ':' || rootpage || ':' || sql FROM sqlite_schema
        WHERE type = 'index' AND sql IS NOT NULL ORDER BY name
        """)
        try createLegacyThreadIndex(in: database)
        #expect(try values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE name = 'events_token_usage_thread'") == ["events_token_usage_thread"])

        _ = try HistoryDatabase(directoryURL: directory.url)
        let remaining = try values(in: directory, sql: """
        SELECT name || ':' || rootpage || ':' || sql FROM sqlite_schema
        WHERE type = 'index' AND sql IS NOT NULL ORDER BY name
        """)
        #expect(remaining == original)
    }

    @Test func indexNameConflictPreservesOldIndexesAndCanRetryAfterRecovery() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("CREATE INDEX events_date ON events(date, position)")
        try database.execute("DROP INDEX IF EXISTS codexbar_events_date_kind_position")
        try database.execute("CREATE INDEX codexbar_events_date_kind_position ON days(date)")
        try database.execute("INSERT INTO days(date) VALUES ('2026-10-20')")
        let schema = try values(in: directory, sql: "PRAGMA schema_version")

        #expect(throws: HistoryDatabase.Failure.self) { _ = try HistoryDatabase(directoryURL: directory.url) }
        #expect(try values(in: directory, sql: "PRAGMA schema_version") == schema)
        #expect(try values(in: directory, sql: "SELECT name FROM pragma_index_list('events') WHERE name = 'events_date'") == ["events_date"])
        #expect(try values(in: directory, sql: "SELECT tbl_name FROM sqlite_schema WHERE name = 'codexbar_events_date_kind_position'") == ["days"])
        #expect(try database.dates() == ["2026-10-20"])
        try database.execute("DROP INDEX codexbar_events_date_kind_position")

        let reopened = try HistoryDatabase(directoryURL: directory.url)
        #expect(try reopened.dates() == ["2026-10-20"])
        #expect(try values(in: directory, sql: "SELECT name FROM pragma_index_info('codexbar_events_date_kind_position') ORDER BY seqno") == ["date", "kind", "position"])
        #expect(try values(in: directory, sql: "SELECT name FROM sqlite_schema WHERE name = 'events_date'").isEmpty)
    }

    @Test func concurrentOpensConvergeOnCurrentIndexes() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("CREATE INDEX events_date ON events(date, position)")
        try createLegacyThreadIndex(in: database)
        try database.execute("DROP INDEX IF EXISTS codexbar_events_date_kind_position")
        try database.execute("DROP INDEX IF EXISTS codexbar_events_token_usage_thread")
        try database.execute("INSERT INTO days(date) VALUES ('2026-10-20')")
        let schemaValue = try #require(values(in: directory, sql: "PRAGMA schema_version").first)
        let schema = try #require(Int(schemaValue))

        try await withThrowingTaskGroup(of: [String].self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try HistoryDatabase(directoryURL: directory.url).dates() }
            }
            for try await dates in group {
                #expect(dates == ["2026-10-20"])
            }
        }
        #expect(try values(in: directory, sql: "PRAGMA schema_version") == [String(schema + 4)])
        #expect(try values(in: directory, sql: """
        SELECT name FROM sqlite_schema WHERE name IN ('events_date', 'events_token_usage_thread')
        """).isEmpty)
        #expect(try values(in: directory, sql: "SELECT name FROM pragma_index_info('codexbar_events_date_kind_position') ORDER BY seqno") == ["date", "kind", "position"])
    }

    private func createLegacyThreadIndex(in database: HistoryDatabase) throws {
        try database.execute("""
        CREATE INDEX IF NOT EXISTS events_token_usage_thread
        ON events(CASE WHEN json_valid(CAST(payload AS TEXT)) THEN json_extract(CAST(payload AS TEXT), '$.tokenUsage.threadID') END, position)
        WHERE kind = 'tokenUsage'
        """)
    }

    private func values(in directory: TestDirectory, sql: String) throws -> [String] {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(directory.url.appendingPathComponent("event.db").path, &connection, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(connection) }
        try #require(opened == SQLITE_OK)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        try #require(prepared == SQLITE_OK)
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return result
            }
            try #require(step == SQLITE_ROW)
            try result.append(String(cString: #require(sqlite3_column_text(statement, 0))))
        }
    }
}
