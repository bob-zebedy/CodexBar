import Foundation
import SQLite3
import Testing

struct HistoryDatabaseStoreTests {
    @Test func releasingConnectionPreservesCommittedData() async throws {
        let directory = try TestDirectory()
        defer { await #expect(throws: Never.self) { try await directory.removeAfterClosingHistory() } }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        try await store.access { try $0.execute("INSERT INTO days(date) VALUES ('committed')") }
        #expect(try !directory.openFilePaths().isEmpty)
        await store.releaseConnection()
        await store.releaseConnection()
        #expect(try directory.openFilePaths().isEmpty)
        #expect(try await store.access { try $0.dates() } == ["committed"])
    }

    @Test func activityAndTokenWritersUseTheSharedConnection() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        let recorder = ActivityDataRecorder(directoryURL: directory.url)
        let tokens = TokenUsageHistoryStore(directoryURL: directory.url)
        let event = Self.event(at: Date())
        let sample = TokenUsageSample(
            observedAt: Date(), threadID: "thread", turnID: "turn", turnStartedAt: nil, current: TokenUsageUpdate(total: .zero, last: .zero)
        )
        try await store.access {
            // TEMP 触发器只对创建它的连接生效
            try $0.execute("CREATE TEMP TRIGGER reject_event BEFORE INSERT ON main.events BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        await #expect(throws: (any Error).self) { try await recorder.record(event: event) }
        await #expect(throws: (any Error).self) { try await tokens.record(sample) }
        try await store.access { try $0.execute("DROP TRIGGER reject_event") }
        try await recorder.record(event: event)
        _ = try await tokens.record(sample)
        let count = try await store.access {
            var count = 0
            try $0.entries { _ in count += 1 }
            return count
        }
        #expect(count == 2)
    }

    @Test func historyMaintenanceUsesTheSharedConnection() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let store = HistoryDatabaseStore.shared(in: directory.url)
        let sync = SyncService(directoryURL: directory.url, isEnabled: { false })
        let history = HistoryService(directoryURL: directory.url, syncService: sync)
        let event = Self.event(at: now)
        try await ActivityDataRecorder(directoryURL: directory.url).record(event: event)
        try await store.access {
            try $0.execute("CREATE TEMP TRIGGER reject_aggregate BEFORE INSERT ON main.aggregates BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        let failed = await history.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(failed.counts?.failed == 1)
        #expect(try await store.access { try $0.activityDataAggregates().isEmpty })
        try await store.access { try $0.execute("DROP TRIGGER reject_aggregate") }
        let recovered = await history.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(recovered.counts?.written == 1)
        #expect(try await store.access { try $0.activityDataAggregates().first?.eventCount } == 1)
    }

    @Test func concurrentAccessKeepsFailedTransactionsSeparate() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 24 {
                group.addTask {
                    do {
                        try await store.access { database in
                            try database.transaction {
                                try database.execute("INSERT INTO days(date) VALUES (?)", [.text("day-\(index)")])
                                if index.isMultiple(of: 2) {
                                    throw InjectedFailure.write
                                }
                            }
                        }
                    } catch InjectedFailure.write {}
                }
            }
            try await group.waitForAll()
        }
        let dates = try await store.access { try $0.dates() }
        #expect(Set(dates) == Set((0 ..< 24).filter { !$0.isMultiple(of: 2) }.map { "day-\($0)" }))
    }

    @Test func cancellationRollsBackWithoutDiscardingTheConnection() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        try await store.access { try $0.execute("CREATE TEMP TABLE connection_probe(value INTEGER)") }
        let task = Task {
            try await store.access { database in
                try database.transaction {
                    try database.execute("INSERT INTO days(date) VALUES ('cancelled')")
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let dates = try await store.access {
            try $0.execute("INSERT INTO connection_probe VALUES (1)")
            return try $0.dates()
        }
        #expect(dates.isEmpty)
        try await store.access { try $0.execute("INSERT INTO days(date) VALUES ('committed')") }
        #expect(try await store.access { try $0.dates() } == ["committed"])
    }

    @Test func failedOpenCanRecoverOnTheSameStore() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("not a database", to: "event.db")
        let store = HistoryDatabaseStore.shared(in: directory.url)
        await #expect(throws: (any Error).self) { try await store.access { try $0.dates() } }
        try FileManager.default.removeItem(at: blocker)
        #expect(try await store.access { try $0.dates() }.isEmpty)
    }

    @Test func reusedConnectionSeesOtherConnectionCommitsAndKeepsDirectoriesSeparate() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let firstURL = directory.url.appendingPathComponent("first", isDirectory: true)
        let secondURL = directory.url.appendingPathComponent("second", isDirectory: true)
        let first = HistoryDatabaseStore.shared(in: firstURL)
        let second = HistoryDatabaseStore.shared(in: secondURL)
        #expect(try await first.access { try $0.dates() }.isEmpty)
        try HistoryDatabase(directoryURL: firstURL).execute("INSERT INTO days(date) VALUES ('external')")
        #expect(try await first.access { try $0.dates() } == ["external"])
        #expect(try await second.access { try $0.dates() }.isEmpty)
    }

    @Test func replacingDatabaseReopensConnectionAndDiscardsThreadSnapshots() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let activeDirectory = directory.url.appendingPathComponent("active", isDirectory: true)
        let store = HistoryDatabaseStore.shared(in: activeDirectory)
        defer {
            await store.releaseConnection()
            #expect(throws: Never.self) { try #require(directory.openFilePaths().isEmpty) }
        }
        let tokens = TokenUsageHistoryStore(directoryURL: activeDirectory)
        let now = Date()
        let first = Self.observation(tokens: 5, at: now)
        try await tokens.appendObservation(first)
        #expect(try await tokens.snapshot(threadID: "thread").turns["turn"]?.totalTokens == 5)
        let replacementDirectory = directory.url.appendingPathComponent("replacement", isDirectory: true)
        let replacement = Self.observation(tokens: 20, at: now)
        try HistoryDatabase(directoryURL: replacementDirectory).append(AppServerEventRecord(tokenUsage: replacement, recordedAt: now))
        // 替换容器目录以改变数据库身份, 避免直接重命名 SQLite 监视的文件
        try FileManager.default.moveItem(at: activeDirectory, to: directory.url.appendingPathComponent("previous", isDirectory: true))
        try FileManager.default.moveItem(at: replacementDirectory, to: activeDirectory)
        #expect(try await tokens.snapshot(threadID: "thread").turns["turn"]?.totalTokens == 20)
        #expect(try await store.access { try $0.dates() } == [HistoryStorage.dateKey(for: now)])
    }

    @Test func threadSnapshotsRemainAccurateBeyondCacheCapacity() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let tokens = TokenUsageHistoryStore(directoryURL: directory.url)
        let now = Date()
        for index in 0 ..< 129 {
            let threadID = "thread-\(index)"
            try await tokens.appendObservation(Self.observation(tokens: 5, at: now, threadID: threadID))
            #expect(try await tokens.snapshot(threadID: threadID).turns["turn"]?.totalTokens == 5)
        }
        let updated = try await tokens.record(TokenUsageSample(
            observedAt: now, threadID: "thread-0", turnID: "turn", turnStartedAt: nil,
            current: Self.observation(tokens: 9, at: now).current
        ))
        #expect(updated.turns["turn"]?.totalTokens == 9)
        for index in 0 ..< 129 {
            #expect(try await tokens.snapshot(threadID: "thread-\(index)").turns["turn"]?.totalTokens == (index == 0 ? 9 : 5))
        }
    }

    @Test func schemaChangesAreValidatedBeforeReusingConnection() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        try await store.access { try $0.execute("INSERT INTO days(date) VALUES ('preserved')") }
        let external = try HistoryDatabase(directoryURL: directory.url)
        try external.execute("PRAGMA user_version = 999")
        await #expect(throws: StorageCompatibilityError.unsupportedFormat("HistoryDatabase", 999)) {
            try await store.access { try $0.dates() }
        }
        #expect(try external.dates() == ["preserved"])
        try external.execute("PRAGMA user_version = 1")
        #expect(try await store.access { try $0.dates() } == ["preserved"])
    }

    @Test func ioFailureReopensConnectionWithoutReplayingCommittedWork() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        await #expect(throws: HistoryDatabase.Failure.self) {
            try await store.access {
                try $0.execute("CREATE TEMP TABLE connection_probe(value INTEGER)")
                try $0.execute("INSERT INTO days(date) VALUES ('committed')")
                throw HistoryDatabase.Failure(code: SQLITE_IOERR, message: "injected failure")
            }
        }
        let dates = try await store.access {
            try $0.execute("CREATE TEMP TABLE connection_probe(value INTEGER)")
            return try $0.dates()
        }
        #expect(dates == ["committed"])
    }

    @Test func lockContentionPreservesConnection() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = HistoryDatabaseStore.shared(in: directory.url)
        try await store.access {
            try $0.execute("CREATE TEMP TABLE connection_probe(value INTEGER)")
            try $0.execute("PRAGMA busy_timeout = 0")
        }
        let external = try HistoryDatabase(directoryURL: directory.url)
        try external.execute("BEGIN EXCLUSIVE")
        do {
            _ = try await store.access { try $0.dates() }
            Issue.record("Expected the external writer to block the read")
        } catch let error as HistoryDatabase.Failure {
            #expect(error.code == SQLITE_BUSY)
        }
        try external.execute("ROLLBACK")
        try await store.access { try $0.execute("INSERT INTO connection_probe VALUES (1)") }
    }

    private static func event(at date: Date) -> ActivityDataRecord {
        ActivityDataRecord(
            timestamp: date, name: ActivityDataEventKind.turnStarted.rawValue, origin: .main,
            cwd: nil, toolName: nil, model: nil, effort: nil, threadID: "thread", turnID: "turn", agentThreadID: nil, id: "event"
        )
    }

    private static func observation(tokens: Int64, at date: Date, threadID: String = "thread") -> TokenUsageObservation {
        let usage = TokenUsage(inputTokens: tokens, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: tokens)
        return TokenUsageObservation(
            observedAt: date, threadID: threadID, turnID: "turn", previous: .zero, current: TokenUsageUpdate(total: usage, last: usage)
        )
    }

    private enum InjectedFailure: Error {
        case write
    }
}
