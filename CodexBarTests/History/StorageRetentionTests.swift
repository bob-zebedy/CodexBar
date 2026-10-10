import Foundation
import SQLite3
import Testing

struct StorageRetentionTests {
    @Test func dailyCleanupSkipsRepeatedRefreshButStillAggregatesNewEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let expiredKey = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400))
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        let expiredURL = try directory.writeJournal(Data(), to: "Events/\(expiredKey).jsonl")
        let recorder = ActivityRecorder(directoryURL: directory.url)
        try await recorder.record(event: ActivityRecord(
            timestamp: now, name: ActivityEventKind.turnStarted.rawValue, origin: .main,
            cwd: nil, toolName: nil, model: nil, effort: nil, threadID: "session", turnID: "turn", agentID: nil, id: "new-event"
        ))
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(FileManager.default.fileExists(atPath: expiredURL.path))
        let data = try Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))
        #expect(JSONLines.decode(ActivityAggregate.self, from: data).first { $0.date == HistoryStorage.dateKey(for: now) }?.turnStartedCount == 1)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: tomorrow)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
        _ = try directory.writeJournal(Data(), to: "Events/\(expiredKey).jsonl")
        let restarted = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await restarted.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: tomorrow)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
    }

    @Test func failedEventCleanupRetriesDuringSameDay() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let date = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400))
        let expiredURL = try directory.writeJournal(Data(), to: "Events/\(date).jsonl")
        let lockURL = HistoryStorage.lockURL(in: directory.url)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: true)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(FileManager.default.fileExists(atPath: expiredURL.path))
        try FileManager.default.removeItem(at: lockURL)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
    }

    @Test func cacheCleanupRunsDailyAndRetriesOnlyFailedStore() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let expired = HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400)
        let key = HistoryStorage.dateKey(for: expired)
        let activity = try JSONLines.stableEncoder.encode(ActivitySyncCache(state: SyncState(hashByDate: [key: "old"])))
        let token = TokenTurn(id: "old", rootID: "old", updatedAt: expired)
        let tokens = try JSONLines.stableEncoder.encode(SeededTokenCache(turns: [token.id: token]))
        let activityURL = try directory.write(activity, to: "Activity/cache.json")
        let tokenURL = try directory.write(Data(#"{"version":999}"#.utf8), to: "Tokens/cache.json")
        let sync = SyncService(directoryURL: directory.url, isEnabled: { false })
        await sync.pruneLocalCaches(now: now)
        #expect(try JSONLines.decoder.decode(ActivitySyncCache.self, from: Data(contentsOf: activityURL)).state.hashByDate.isEmpty)
        try activity.write(to: activityURL)
        try tokens.write(to: tokenURL)
        await sync.pruneLocalCaches(now: now)
        #expect(try Data(contentsOf: activityURL) == activity)
        #expect(try JSONLines.decoder.decode(SeededTokenCache.self, from: Data(contentsOf: tokenURL)).turns.isEmpty)
        try tokens.write(to: tokenURL)
        await sync.pruneLocalCaches(now: now)
        #expect(try Data(contentsOf: tokenURL) == tokens)
        _ = try ActivitySyncStore(directoryURL: directory.url).load()
        #expect(try Data(contentsOf: activityURL) == activity)
        await sync.pruneLocalCaches(now: tomorrow)
        #expect(try JSONLines.decoder.decode(ActivitySyncCache.self, from: Data(contentsOf: activityURL)).state.hashByDate.isEmpty)
        #expect(try JSONLines.decoder.decode(SeededTokenCache.self, from: Data(contentsOf: tokenURL)).turns.isEmpty)
    }

    @Test func eventFilesAndOrphanedStateExpireAtCalendarBoundary() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let cutoff = HistoryStorage.retentionCutoffDate()
        let dates = [cutoff.addingTimeInterval(-86400), cutoff, Date()]
        let keys = dates.map { HistoryStorage.dateKey(for: $0) }
        for (date, key) in zip(dates, keys) {
            let record = AppServerEventRecord(activity: TestFixtures.event(.turnStarted, at: date), recordedAt: date)
            _ = try directory.writeJournal(record.jsonLineData(), to: "Events/\(key).jsonl")
        }
        let orphan = HistoryStorage.dateKey(for: cutoff.addingTimeInterval(-2 * 86400))
        var state = HistoryMaintenanceState()
        state.markPending(orphan)
        state.markDirty(orphan)
        try HistoryStorage.saveMaintenanceState(state, in: directory.url)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(HistoryStorage.eventLogDateKeys(in: HistoryStorage.eventsDirectoryURL(in: directory.url)) == Array(keys.dropFirst()))
        let retained = try HistoryStorage.loadMaintenanceState(in: directory.url)
        #expect(retained.days[orphan] == nil)
        #expect(!retained.pending.contains(orphan))
        #expect(!retained.dirty.contains(orphan))
        let aggregates = try Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))
        #expect(JSONLines.decode(ActivityAggregate.self, from: aggregates).allSatisfy { $0.date >= keys[1] })
    }

    @Test(arguments: [false, true])
    func logsExpireOnReadAndReopenWithoutCapacityPressure(reopen: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let clock = RetentionClock()
        let storage = AppServerLogStore(directoryURL: directory.url, now: { clock.read() })
        let expired = storage.beginRequest(method: "expired", payload: "{}")
        let boundary = storage.beginRequest(method: "boundary", payload: "{}")
        let original = try await storage.page()
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: clock.read()))
        let cutoff = HistoryStorage.retentionCutoffDate(today: tomorrow)
        var database: OpaquePointer?
        #expect(sqlite3_open(directory.url.appendingPathComponent(AppServerLogStore.databaseName).path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        for (id, date) in [(expired, cutoff.addingTimeInterval(-1)), (boundary, cutoff)] {
            let sql = "UPDATE entries SET payload = CAST(json_set(CAST(payload AS TEXT), '$.requestedAt', \(date.timeIntervalSinceReferenceDate)) AS BLOB) WHERE id = '\(id.uuidString)'"
            #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        }
        clock.set(tomorrow)
        let reader = reopen ? AppServerLogStore(directoryURL: directory.url, now: { clock.read() }) : storage
        let page = try await reader.page()
        #expect(page.total == 1)
        #expect(page.entries.map(\.id) == [boundary])
        #expect(page.generation > original.generation)
        reader.finishRequest(expired, response: "late response")
        #expect(try await reader.page().total == 1)
    }

    @Test func disabledSyncStillPrunesBothLocalCachesAndKeepsRequiredTokenRoot() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let cutoff = HistoryStorage.retentionCutoffDate()
        let expired = cutoff.addingTimeInterval(-86400)
        let expiredKey = HistoryStorage.dateKey(for: expired)
        let retainedKey = HistoryStorage.dateKey(for: cutoff)
        let records = try [expiredKey, retainedKey].map { date in
            let daily = try TestFixtures.decode(SyncedActivity.self, """
            {"version":1,"aggregationVersion":1,"date":"\(date)","generationID":"source","eventCount":1}
            """)
            return try ActivitySyncRecord(
                deviceID: "device", daily: daily,
                recordName: ActivitySyncRecord.recordName(deviceID: "device", date: date, generation: "source")
            )
        }
        let cache = ActivitySyncCache(state: SyncState(hashByDate: [expiredKey: "old", retainedKey: "keep"]), records: records)
        _ = try directory.write(JSONLines.stableEncoder.encode(cache), to: "Sync/Activity/cache.json")
        let turns = [
            TokenTurn(id: "expired", rootID: "expired", updatedAt: expired),
            TokenTurn(id: "root", rootID: "root", updatedAt: expired),
            TokenTurn(id: "child", rootID: "root", updatedAt: cutoff)
        ]
        let tokenCache = SeededTokenCache(turns: Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) }))
        _ = try directory.write(JSONLines.stableEncoder.encode(tokenCache), to: "Sync/Tokens/cache.json")
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let activityData = try Data(contentsOf: directory.url.appendingPathComponent("Sync/Activity/cache.json"))
        let activity = try JSONLines.decoder.decode(ActivitySyncCache.self, from: activityData)
        #expect(activity.records.map(\.date) == [retainedKey])
        #expect(activity.state.hashByDate == [retainedKey: "keep"])
        let tokenData = try Data(contentsOf: directory.url.appendingPathComponent("Sync/Tokens/cache.json"))
        let tokens = try JSONLines.decoder.decode(SeededTokenCache.self, from: tokenData)
        #expect(Set(tokens.turns.keys) == ["root", "child"])
        #expect(tokens.cursor == nil)
    }
}

private nonisolated struct SeededTokenCache: Codable {
    var version = 1
    var accountScopedDeviceID = "device"
    var salt = Data(repeating: 1, count: 32)
    var turns: [String: TokenTurn]
    var cursor: Data? = Data("cursor".utf8)
}

private final nonisolated class RetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()

    func read() -> Date {
        lock.withLock { value }
    }

    func set(_ date: Date) {
        lock.withLock { value = date }
    }
}

extension StorageRetentionTests {
    @Test func eventDirectoryReadFailureDoesNotCompleteDailyCleanup() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let eventsURL = try directory.write("not a directory", to: "Events")
        #expect(throws: (any Error).self) { try HistoryStorage.readEventLogDateKeys(in: eventsURL) }
        let now = Date()
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        try FileManager.default.removeItem(at: eventsURL)
        #expect(try HistoryStorage.readEventLogDateKeys(in: eventsURL).isEmpty)
        let expired = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400))
        let expiredURL = try directory.writeJournal(Data(), to: "Events/\(expired).jsonl")
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(!FileManager.default.fileExists(atPath: expiredURL.path))
    }

    @Test func newDailyAggregateIncludesKnownZeroAborts() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let recorder = ActivityRecorder(directoryURL: directory.url)
        let event = ActivityRecord(
            timestamp: now,
            name: ActivityEventKind.turnStarted.rawValue,
            origin: .main,
            cwd: nil,
            toolName: nil,
            model: nil,
            effort: nil,
            threadID: "session",
            turnID: "turn",
            agentID: nil,
            id: "start"
        )
        try await recorder.record(event: event)
        let sync = SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directory.url), isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let first = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))).first)
        #expect(first.turnStartedCount == 1)
        #expect(first.turnAbortedCount == 0)
        let aborted = ActivityRecord(
            timestamp: now,
            name: ActivityEventKind.turnAborted.rawValue,
            origin: .main,
            cwd: nil,
            toolName: nil,
            model: nil,
            effort: nil,
            threadID: "session",
            turnID: "turn",
            agentID: nil,
            id: "abort"
        )
        try await recorder.record(event: aborted)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let second = try #require(JSONLines.decode(ActivityAggregate.self, from: Data(contentsOf: HistoryStorage.dailyURL(in: directory.url))).first)
        #expect(second.turnAbortedCount == 1)
        #expect(try HistoryStorage.loadMaintenanceState(in: directory.url).version == HistoryMaintenanceState.currentVersion)
    }
}
