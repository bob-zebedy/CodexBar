import Foundation
import Testing

struct AppServerEventStorageTests {
    private let now = TestFixtures.now

    @Test func nativeMetadataRoundTripsWithoutChangingBusinessIdentity() throws {
        var event = TestFixtures.event(.toolStarted, thread: "root", turn: "child-turn", agentThreadID: "child", origin: .auxiliary)
        event.context = ActivityDataContext(
            method: "item/started", threadID: "child", turnID: "child-turn", parentThreadID: "parent",
            rootThreadID: "root", rootTurnID: "root-turn", itemID: "item", itemType: "commandExecution", itemStatus: "inProgress"
        )
        let record = AppServerEventRecord(activityData: event, recordedAt: now)
        let decoded = try AppServerEventRecord.decode(from: record.jsonLineData())
        #expect(decoded.activityData == event)
        #expect(decoded.context?.threadID == "child")
        #expect(decoded.activityData?.threadID == "root")
        let text = try #require(String(bytes: record.jsonLineData(), encoding: .utf8))
        #expect(text.contains("toolStarted"))
        #expect(!text.contains("PreToolUse"))
        #expect(!text.contains("commandLine"))
    }

    @Test func activityDataStorageSeparatesProtocolContextFromBusinessFields() throws {
        var event = TestFixtures.event(.approvalRequested, agentThreadID: "child")
        event.context = ActivityDataContext(
            method: "item/commandExecution/requestApproval", threadID: "child", turnID: "child-turn",
            parentThreadID: "parent", rootThreadID: "root", rootTurnID: "root-turn", itemID: "item",
            itemType: "commandExecution", itemStatus: "inProgress", agentThreadID: "child",
            itemKind: "started", requestID: "request", turnStatus: .running,
            turnStartedAt: now, turnCompletedAt: now.addingTimeInterval(1), duration: 1
        )
        let data = try AppServerEventRecord(activityData: event, recordedAt: now).jsonLineData()
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(record.keys) == ["schemaVersion", "recordedAt", "context", "activityData"])
        #expect(record["kind"] == nil)
        let context = try #require(record["context"] as? [String: Any])
        #expect(Set(context.keys) == [
            "method", "threadID", "turnID", "parentThreadID", "rootThreadID",
            "rootTurnID", "itemID", "itemType", "itemStatus", "agentThreadID",
            "itemKind", "requestID", "turnStatus", "turnStartedAt", "turnCompletedAt", "duration"
        ])
        #expect(context["itemKind"] as? String == "started")
        #expect(context["duration"] as? Double == 1)
        #expect(context["turnStartedAt"] as? Double == now.timeIntervalSince1970 * 1000)
        let payload = try #require(record["activityData"] as? [String: Any])
        #expect(Set(payload.keys) == [
            "timestamp", "name", "origin", "cwd", "toolName", "model", "effort",
            "threadID", "turnID", "agentThreadID"
        ])
        #expect(try AppServerEventRecord.decode(from: data).activityData == event)
    }

    @Test func unsupportedVersionAndMixedPayloadAreRejected() throws {
        let observation = TestFixtures.tokenUsageObservation(at: now, tokenUsage: .zero)
        let valid = try #require(String(bytes: AppServerEventRecord(tokenUsage: observation, recordedAt: now).jsonLineData(), encoding: .utf8))
        let future = valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":99")
        let mixed = valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"activityData\":{}")
        for text in [future, mixed] {
            #expect(throws: (any Error).self) { try AppServerEventRecord.decode(from: Data(text.utf8)) }
        }
    }

    @Test func tokenUsageStorageUsesTokenUsageWithoutDuplicatingKind() throws {
        let observation = TestFixtures.tokenUsageObservation(at: now, tokenUsage: .zero)
        let record = AppServerEventRecord(tokenUsage: observation, recordedAt: now)
        let data = try record.jsonLineData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "recordedAt", "tokenUsage"])
        #expect(record.kind.rawValue == "tokenUsage")
        #expect(try AppServerEventRecord.decode(from: data).tokenUsage == observation)
    }

    @Test func timestampsUseIntegerMillisecondsAcrossJournalAndSyncCache() throws {
        let timestamp = now.addingTimeInterval(0.1234567)
        let expected = Int64(now.timeIntervalSince1970 * 1000) + 123
        var event = TestFixtures.event(.turnStarted)
        event.context = ActivityDataContext(
            method: "turn/started", threadID: "thread", turnStartedAt: timestamp,
            turnCompletedAt: timestamp, duration: 0.4567
        )
        let data = try AppServerEventRecord(activityData: event, recordedAt: timestamp).jsonLineData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"recordedAt\":\(expected),"))
        #expect(text.contains("\"turnStartedAt\":\(expected)}"))
        let decoded = try AppServerEventRecord.decode(from: data)
        #expect(decoded.recordedAt == Date(timeIntervalSince1970: Double(expected) / 1000))
        #expect(decoded.context?.duration == 0.4567)

        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.json")
        let record = try ActivityDataSyncRecord(
            deviceID: "device", activityData: ActivityDataAggregate(date: "2026-09-15").syncedAggregate,
            updatedAt: timestamp, recordName: "activityData_device_2026-09-15"
        )
        try JSONFileStorage.save(record, to: url)
        let stored = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object["updatedAt"] as? Int64 == expected)
        #expect(object["date"] as? String == "2026-09-15")
        let restored = try JSONLines.decoder.decode(ActivityDataSyncRecord.self, from: stored)
        #expect(restored.updatedAt == decoded.recordedAt)
        #expect(try JSONLines.stableEncoder.encode(restored) == stored)

        var cache = TokenUsageFileCache<[TokenUsageObservation]>(url: directory.url.appendingPathComponent("tokenUsage.json"))
        try cache.save([TestFixtures.tokenUsageObservation(at: timestamp, tokenUsage: .zero)])
        var reopened = TokenUsageFileCache<[TokenUsageObservation]>(url: cache.url)
        #expect(try reopened.load()?.first?.observedAt == decoded.recordedAt)
    }
}
