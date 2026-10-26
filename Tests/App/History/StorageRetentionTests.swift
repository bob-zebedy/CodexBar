import Foundation
import SQLite3
import Testing

struct StorageRetentionTests {
    @Test func cacheCleanupRunsDailyAndRetriesOnlyFailedStore() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let tomorrow = try #require(Calendar.current.date(byAdding: .day, value: 1, to: now))
        let expired = HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400)
        let key = HistoryStorage.dateKey(for: expired)
        let activityDataRecord = try ActivityDataSyncRecord(
            deviceID: "device", activityData: ActivityDataAggregate(date: key).syncedAggregate,
            recordName: ActivityDataSyncRecord.recordName(deviceID: "device", date: key)
        )
        let activityDataCache = try JSONLines.stableEncoder.encode(ActivityDataSyncCache(
            state: ActivityDataSyncState(deviceID: "device"), records: [activityDataRecord.id: activityDataRecord]
        ))
        let tokenUsageRecord = TokenUsageSyncRecord(deviceID: "device", date: key, tokenUsage: .zero)
        let tokenUsageCacheData = try JSONLines.stableEncoder.encode(TokenUsageSyncCache(
            state: TokenUsageSyncState(deviceID: "device"), records: [tokenUsageRecord.id: tokenUsageRecord]
        ))
        let activityDataURL = try directory.write(activityDataCache, to: "Sync/activityData.json")
        let tokenUsageURL = try directory.write(Data(#"{"schemaVersion":999}"#.utf8), to: "Sync/tokenUsage.json")
        let sync = SyncService(directoryURL: directory.url, isEnabled: { false })
        await sync.pruneLocalCaches(now: now)
        #expect(try JSONLines.decoder.decode(ActivityDataSyncCache.self, from: Data(contentsOf: activityDataURL)).records.isEmpty)
        try activityDataCache.write(to: activityDataURL)
        try tokenUsageCacheData.write(to: tokenUsageURL)
        await sync.pruneLocalCaches(now: now)
        #expect(try Data(contentsOf: activityDataURL) == activityDataCache)
        #expect(try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: Data(contentsOf: tokenUsageURL)).records.isEmpty)
        try tokenUsageCacheData.write(to: tokenUsageURL)
        await sync.pruneLocalCaches(now: now)
        #expect(try Data(contentsOf: tokenUsageURL) == tokenUsageCacheData)
        _ = try ActivityDataSyncStore(directoryURL: directory.url).load()
        #expect(try Data(contentsOf: activityDataURL) == activityDataCache)
        await sync.pruneLocalCaches(now: tomorrow)
        #expect(try JSONLines.decoder.decode(ActivityDataSyncCache.self, from: Data(contentsOf: activityDataURL)).records.isEmpty)
        #expect(try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: Data(contentsOf: tokenUsageURL)).records.isEmpty)
    }

    @Test(arguments: [false, true])
    func logsExpireOnReadAndReopenWithoutCapacityPressure(reopen: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let clock = RetentionClock()
        let storage = AppServerLogStore(directoryURL: directory.url, now: { clock.read() })
        defer { await #expect(throws: Never.self) { try await storage.close() } }
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
        defer { await #expect(throws: Never.self) { try await reader.close() } }
        let page = try await reader.page()
        #expect(page.total == 1)
        #expect(page.entries.map(\.id) == [boundary])
        #expect(page.generation > original.generation)
        reader.finishRequest(expired, response: "late response")
        #expect(try await reader.page().total == 1)
    }

    @Test func disabledSyncStillPrunesBothLocalCaches() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let cutoff = HistoryStorage.retentionCutoffDate()
        let expired = cutoff.addingTimeInterval(-86400)
        let expiredKey = HistoryStorage.dateKey(for: expired)
        let retainedKey = HistoryStorage.dateKey(for: cutoff)
        let records = try [expiredKey, retainedKey].map { date in
            let daily = try TestFixtures.decode(SyncedActivityData.self, """
            {"schemaVersion":1,"aggregationVersion":1,"date":"\(date)","eventCount":1}
            """)
            return try ActivityDataSyncRecord(
                deviceID: "device", activityData: daily,
                recordName: ActivityDataSyncRecord.recordName(deviceID: "device", date: date)
            )
        }
        let cache = ActivityDataSyncCache(
            state: ActivityDataSyncState(deviceID: "device"),
            records: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        )
        _ = try directory.write(JSONLines.stableEncoder.encode(cache), to: "Sync/activityData.json")
        let days = [
            TokenUsageSyncRecord(deviceID: "device", date: expiredKey, tokenUsage: .zero),
            TokenUsageSyncRecord(deviceID: "device", date: retainedKey, tokenUsage: .zero),
            TokenUsageSyncRecord(deviceID: "other", date: retainedKey, tokenUsage: .zero)
        ]
        let tokenUsageCache = TokenUsageSyncCache(
            state: TokenUsageSyncState(deviceID: "device"), records: Dictionary(uniqueKeysWithValues: days.map { ($0.id, $0) }),
            cursor: Data("cursor".utf8)
        )
        _ = try directory.write(JSONLines.stableEncoder.encode(tokenUsageCache), to: "Sync/tokenUsage.json")
        let sync = SyncService(directoryURL: directory.url, isEnabled: { false })
        let service = HistoryService(directoryURL: directory.url, syncService: sync)
        _ = await service.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        let activityData = try Data(contentsOf: directory.url.appendingPathComponent("Sync/activityData.json"))
        let activityDataCache = try JSONLines.decoder.decode(ActivityDataSyncCache.self, from: activityData)
        #expect(activityDataCache.sortedRecords.map(\.date) == [retainedKey])
        #expect(activityDataCache.state.deviceID == "device")
        let tokenUsageData = try Data(contentsOf: directory.url.appendingPathComponent("Sync/tokenUsage.json"))
        let tokenUsageCacheData = try JSONLines.decoder.decode(TokenUsageSyncCache.self, from: tokenUsageData)
        #expect(Set(tokenUsageCacheData.records.keys) == ["tokenUsage_device_\(retainedKey)", "tokenUsage_other_\(retainedKey)"])
        #expect(tokenUsageCacheData.cursor == nil)
    }
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

extension StorageRetentionTests {}
