import Foundation
import Testing

struct JSONLinesAndActivityDataTests {
    @Test func millisecondTimestampsRemainStableAcrossRepeatedEncoding() throws {
        let base = Int64(TestFixtures.now.timeIntervalSince1970 * 1000)
        for offset in 0 ..< 1000 {
            let expected = base + Int64(offset)
            let data = Data("{\"time\":\(expected)}".utf8)
            let dates = try JSONLines.decoder.decode([String: Date].self, from: data)
            #expect(try JSONLines.stableEncoder.encode(dates) == data)
        }
    }

    @Test(arguments: ["PermissionRequest", "permission_request", "permission-request", "approval.requested"])
    func eventAliasesAreNotAccepted(_ name: String) {
        #expect(ActivityDataEventKind(eventName: name) == nil)
        #expect(ActivityDataEventKind(eventName: "approvalRequested") == .approvalRequested)
    }

    @Test func unknownEventNamesAreNotGuessed() {
        #expect(ActivityDataEventKind(eventName: "future_event") == nil)
    }

    @Test func eventDecodingToleratesMissingMetadataAndUnknownOrigins() throws {
        let event = try TestFixtures.decode(ActivityDataRecord.self, """
        {"timestamp":0,"name":"turnStarted","origin":"future","threadID":"  ","toolName":123}
        """)
        #expect(event.eventKind == .turnStarted)
        #expect(event.origin == .unknown)
        #expect(event.threadID == nil)
        #expect(event.toolName == nil)
    }

    @Test(arguments: [#"{"name":"turnCompleted"}"#, #"{"timestamp":"invalid","name":"turnCompleted"}"#, #"{"timestamp":0,"name":" "}"#])
    func eventDecodingRequiresTimestampAndEvent(_ json: String) {
        #expect(throws: (any Error).self) {
            try TestFixtures.decode(ActivityDataRecord.self, json)
        }
    }

    @Test func eventSerializationRoundTripsEscapedMetadata() throws {
        let event = ActivityDataRecord(
            timestamp: TestFixtures.now, name: "toolStarted", origin: .main,
            cwd: "/projects/a\"b", toolName: "line\nbreak", model: nil,
            effort: nil, threadID: "thread", turnID: "turn", agentThreadID: "agent-thread"
        )
        let data = try JSONLines.stableEncoder.encode(event)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["threadID"] as? String == "thread")
        #expect(payload["turnID"] as? String == "turn")
        #expect(payload["agentThreadID"] as? String == "agent-thread")
        #expect(!data.contains(JSONLines.newlineByte))
        #expect(try JSONLines.decoder.decode(ActivityDataRecord.self, from: data) == event)
    }

    @Test func modelNameDoesNotClassifyTaskOrigin() throws {
        let unknown = try TestFixtures.decode(ActivityDataRecord.self, #"{"timestamp":0,"name":"turnCompleted","model":"codex-auto-review"}"#)
        let explicit = try TestFixtures.decode(ActivityDataRecord.self, #"{"timestamp":0,"name":"turnCompleted","model":"codex-auto-review","origin":"main"}"#)
        #expect(unknown.origin == .unknown)
        #expect(explicit.origin == .main)
    }
}
