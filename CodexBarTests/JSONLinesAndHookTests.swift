import Foundation
import Testing

struct JSONLinesAndHookTests {
    @Test func corruptUTF8DoesNotDiscardNeighboringJSONLines() {
        let data = Data("1\n \t\r\n".utf8) + Data([0xFF, 0x0A]) + Data("{broken}\n2\n3".utf8)
        let result = JSONLines.decodeWithFailures(Int.self, from: data)
        #expect(result.values == [1, 2, 3])
        #expect(result.failedLineCount == 2)
    }

    @Test func leadingPartialLineIsDroppedAtByteBoundary() {
        #expect(JSONLines.droppingLeadingPartialLine(Data("partial\n1\n2\n".utf8)) == Data("1\n2\n".utf8))
        #expect(JSONLines.droppingLeadingPartialLine(Data("partial\n".utf8)).isEmpty)
        #expect(JSONLines.droppingLeadingPartialLine(Data("partial".utf8)) == Data("partial".utf8))
    }

    @Test(arguments: ["PermissionRequest", "permissionRequest", "permission_request", "permission-request"])
    func hookNamesNormalizeAcrossWireFormats(_ name: String) {
        #expect(CodexHookEvent(eventName: name) == .permissionRequest)
    }

    @Test func unknownHookNamesAreNotGuessed() {
        #expect(CodexHookEvent(eventName: "future_event") == nil)
    }

    @Test func hookDecodingToleratesMissingMetadataAndUnknownOrigins() throws {
        let event = try TestFixtures.decode(WorkflowHookEvent.self, """
        {"timestamp":"2026-09-15 12:00:00.000","event":" UserPromptSubmit ","origin":"future","session":"  ","tool":123}
        """)
        #expect(event.hookEvent == .userPromptSubmit)
        #expect(event.origin == .unknown)
        #expect(event.sessionId == nil)
        #expect(event.toolName == nil)
    }

    @Test(arguments: [#"{"event":"Stop"}"#, #"{"timestamp":"invalid","event":"Stop"}"#, #"{"timestamp":"2026-09-15 12:00:00.000","event":" "}"#])
    func hookDecodingRequiresTimestampAndEvent(_ json: String) {
        #expect(throws: (any Error).self) {
            try TestFixtures.decode(WorkflowHookEvent.self, json)
        }
    }

    @Test func hookSerializationRoundTripsEscapedMetadata() throws {
        let event = WorkflowHookEvent(
            timestamp: TestFixtures.now, name: "PreToolUse", origin: .main,
            directoryPath: "/projects/a\"b", toolName: "line\nbreak", modelName: nil,
            effort: nil, permissionMode: nil, approvalReviewer: nil,
            sessionId: "session", turnId: "turn", agentId: "agent"
        )
        let data = try event.jsonLineData()
        #expect(data.filter { $0 == JSONLines.newlineByte }.count == 1)
        #expect(try JSONDecoder().decode(WorkflowHookEvent.self, from: data) == event)
    }

    @Test func guardianModelOnlyFillsUnknownOrigin() throws {
        let unknown = try TestFixtures.decode(WorkflowHookEvent.self, #"{"timestamp":"2026-09-15 12:00:00.000","event":"Stop","model":"codex-auto-review"}"#)
        let explicit = try TestFixtures.decode(WorkflowHookEvent.self, #"{"timestamp":"2026-09-15 12:00:00.000","event":"Stop","model":"codex-auto-review","origin":"main"}"#)
        #expect(unknown.origin == .autoReview)
        #expect(explicit.origin == .main)
    }

    @Test func terminalHookTimeoutsRespectCodexDeadline() {
        for event in CodexHookEvent.allCases {
            #expect(WorkflowHookEventRecorder.hookTimeoutSeconds(for: event) == ([.sessionEnd, .interrupt].contains(event) ? 3 : 5))
        }
    }

    @Test(arguments: [
        (#""cli""#, WorkflowEventOrigin.main),
        (#"{"custom":"integration"}"#, .main),
        (#"{"subagent":{"other":"guardian"}}"#, .autoReview),
        (#"{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}"#, .auxiliary),
        (#"{"subagent":"review"}"#, .auxiliary),
        (#""future""#, .unknown),
        (#"{"subagent":{"other":""}}"#, .unknown)
    ])
    func rolloutSourcesAreClassifiedConservatively(_ json: String, _ expected: WorkflowEventOrigin) throws {
        #expect(try TestFixtures.decode(WorkflowRolloutSource.self, json).origin == expected)
    }

    @Test func metadataReaderExtractsSourceBeforeLargeInstructions() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let prefix = #"{"type":"session_meta","payload":{"id":"thread","source":"cli","instructions":""#
        let url = try directory.write(prefix + String(repeating: "x", count: 300000) + "\"}}\n", to: "large.jsonl")
        #expect(WorkflowRolloutMetadataReader.origin(transcriptPath: url.path) == .main)
        #expect(WorkflowRolloutMetadataReader.metadata(transcriptPath: url.path)?.id == "thread")
    }

    @Test func metadataReaderDoesNotSearchOtherLinesOrBeyondBudget() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let late = #"{"type":"session_meta","payload":{"source":"cli"}}"#
        let wrongFirstLine = try directory.write("{}\n" + late + "\n", to: "wrong.jsonl")
        #expect(WorkflowRolloutMetadataReader.origin(transcriptPath: wrongFirstLine.path) == .unknown)
        let oversized = try directory.write(String(repeating: " ", count: 256 * 1024) + late + "\n", to: "oversized.jsonl")
        #expect(WorkflowRolloutMetadataReader.origin(transcriptPath: oversized.path) == .unknown)
        #expect(WorkflowRolloutMetadataReader.origin(transcriptPath: nil) == .unknown)
    }
}
