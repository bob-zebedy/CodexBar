import Foundation
import Testing

struct JSONLinesAndActivityTests {
    @Test func millisecondTimestampsRemainStableAcrossRepeatedEncoding() throws {
        let base = Int64(TestFixtures.now.timeIntervalSince1970 * 1000)
        for offset in 0 ..< 1000 {
            let expected = base + Int64(offset)
            let data = Data("{\"time\":\(expected)}".utf8)
            let dates = try JSONLines.decoder.decode([String: Date].self, from: data)
            #expect(try JSONLines.stableEncoder.encode(dates) == data)
        }
    }

    @Test func corruptUTF8DoesNotDiscardNeighboringJSONLines() {
        let data = Data("1\n \t\r\n".utf8) + Data([0xFF, 0x0A]) + Data("{broken}\n2\n3".utf8)
        let result = JSONLines.decodeWithFailures(Int.self, from: data)
        #expect(result.values == [1, 2, 3])
        #expect(result.failedLineCount == 2)
    }

    @Test(arguments: ["PermissionRequest", "permission_request", "permission-request", "approval.requested"])
    func eventAliasesAreNotAccepted(_ name: String) {
        #expect(ActivityEventKind(eventName: name) == nil)
        #expect(ActivityEventKind(eventName: "approvalRequested") == .approvalRequested)
    }

    @Test func unknownEventNamesAreNotGuessed() {
        #expect(ActivityEventKind(eventName: "future_event") == nil)
    }

    @Test func eventDecodingToleratesMissingMetadataAndUnknownOrigins() throws {
        let event = try TestFixtures.decode(ActivityRecord.self, """
        {"timestamp":0,"name":"turnStarted","origin":"future","sessionID":"  ","tool":123}
        """)
        #expect(event.eventKind == .turnStarted)
        #expect(event.origin == .unknown)
        #expect(event.sessionID == nil)
        #expect(event.tool == nil)
    }

    @Test(arguments: [#"{"name":"turnCompleted"}"#, #"{"timestamp":"invalid","name":"turnCompleted"}"#, #"{"timestamp":0,"name":" "}"#])
    func eventDecodingRequiresTimestampAndEvent(_ json: String) {
        #expect(throws: (any Error).self) {
            try TestFixtures.decode(ActivityRecord.self, json)
        }
    }

    @Test func eventSerializationRoundTripsEscapedMetadata() throws {
        let event = ActivityRecord(
            timestamp: TestFixtures.now, name: "toolStarted", origin: .main,
            cwd: "/projects/a\"b", tool: "line\nbreak", model: nil,
            effort: nil, approvalReviewer: nil,
            sessionID: "session", turnID: "turn", agentID: "agent"
        )
        let data = try JSONLines.stableEncoder.encode(event)
        #expect(!data.contains(JSONLines.newlineByte))
        #expect(try JSONLines.decoder.decode(ActivityRecord.self, from: data) == event)
    }

    @Test func guardianModelOnlyFillsUnknownOrigin() throws {
        let unknown = try TestFixtures.decode(ActivityRecord.self, #"{"timestamp":0,"name":"turnCompleted","model":"codex-auto-review"}"#)
        let explicit = try TestFixtures.decode(ActivityRecord.self, #"{"timestamp":0,"name":"turnCompleted","model":"codex-auto-review","origin":"main"}"#)
        #expect(unknown.origin == .autoReview)
        #expect(explicit.origin == .main)
    }
}
