import Foundation
import Testing

struct ActivityDataSyncStoreTests {
    @Test func activityDataCacheCommitsRecordsAndCursorTogether() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        let state = ActivityDataSyncState(deviceID: "device")
        try store.saveState(state)
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("previous cursor".utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var updated = state
        updated.lastPrunedDate = "2026-10-05"
        try store.saveState(updated)
        #expect(try store.load().cursor == Data("previous cursor".utf8))
        let daily = SyncedActivityData(date: "2026-10-05", eventCount: 2, projectCounts: [:], modelCounts: [:])
        let record = try ActivityDataSyncRecord(deviceID: "device", activityData: daily, recordName: "activityData_device_2026-10-05")
        let uploadedAt = JSONLines.storageDate(Date())
        try store.saveConfirmedRecords([record], lastUploadAt: uploadedAt)
        let confirmed = try store.load()
        #expect(confirmed.cursor == Data("previous cursor".utf8))
        #expect(confirmed.sortedRecords == [record])
        #expect(confirmed.state.lastUploadAt == uploadedAt)
        updated.lastUploadAt = uploadedAt
        try store.saveFetchedRecords([record.id: record], cursor: nil)
        let reopened = try ActivityDataSyncStore(directoryURL: directory.url).load()
        #expect(reopened.state == updated)
        #expect(reopened.sortedRecords == [record])
        #expect(reopened.cursor == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(Set(files) == ["activityData.json"])
        try store.reset(state: ActivityDataSyncState())
        #expect(try store.load() == ActivityDataSyncCache(state: ActivityDataSyncState()))
    }

    @Test(arguments: ["missingFields", "missingDate", "mismatchedIdentity"])
    func damagedActivityDataRecordsInvalidateCursorAndUploadState(_ damage: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        try store.saveState(ActivityDataSyncState(deviceID: "device"))
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("stale cursor".utf8).base64EncodedString()
        var record: [String: Any] = [
            "schemaVersion": 1, "aggregationVersion": 1, "date": "2026-10-05",
            "deviceID": "device", "recordName": "activityData_device_2026-10-05", "activityData": [:]
        ]
        switch damage {
        case "missingFields": record = ["invalid": true]
        case "missingDate": record.removeValue(forKey: "date")
        default: record["recordName"] = "activityData_device_2026-10-05_other"
        }
        json["records"] = [record]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(try store.load() == ActivityDataSyncCache(state: ActivityDataSyncState()))
        try store.saveState(ActivityDataSyncState(deviceID: "new"))
        #expect(try store.load().sortedRecords.isEmpty)
        #expect(try store.load().cursor == nil)
        #expect(try store.load().state.deviceID == "new")
    }

    @Test func unsupportedActivityDataCacheIsNotOverwritten() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let original = Data(#"{"schemaVersion":999,"futureField":"unsupported"}"#.utf8)
        let url = try directory.write(original, to: "Sync/activityData.json")
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        #expect(throws: SyncRecovery.Failure.self) { try store.saveState(ActivityDataSyncState()) }
        #expect(throws: SyncRecovery.Failure.self) { try store.reset(state: ActivityDataSyncState()) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func failedActivityDataSavePreservesCacheAndCursor() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ActivityDataSyncStore(directoryURL: directory.url)
        try store.saveState(ActivityDataSyncState(deviceID: "device"))
        let url = directory.url.appendingPathComponent("Sync/activityData.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["cursor"] = Data("previous cursor".utf8).base64EncodedString()
        let original = try JSONSerialization.data(withJSONObject: json)
        try original.write(to: url)
        let daily = SyncedActivityData(date: "2026-10-05", eventCount: 2, projectCounts: [:], modelCounts: [:])
        let record = try ActivityDataSyncRecord(
            deviceID: "device", activityData: daily, updatedAt: Date(timeIntervalSince1970: .infinity),
            recordName: "activityData_device_2026-10-05"
        )
        #expect(throws: EncodingError.self) {
            try store.saveFetchedRecords([record.id: record], cursor: nil)
        }
        #expect(try Data(contentsOf: url) == original)
    }
}
