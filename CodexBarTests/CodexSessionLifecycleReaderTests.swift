import Foundation
import Testing

struct CodexSessionLifecycleReaderTests {
    @Test func completionHasStartDurationContextAndProgress() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try writeRollout(in: directory, lines: [context, start, completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.threadId == "session-a")
        #expect(state.startedAt == Date(timeIntervalSince1970: 1789459200))
        #expect(state.approvalReviewer == .user)
        #expect(state.effort == "high")
        guard case let .completed(at, duration) = state.terminal else {
            Issue.record("Expected a completed turn")
            return
        }
        #expect(at == Date(timeIntervalSince1970: 1789459260))
        #expect(duration == 60)
    }

    @Test func partialCompletionIsNotPublishedUntilLineIsComplete() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        try append(completion, to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let partial = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(partial.readStatus == .incomplete)
        #expect(partial.terminal == nil)
        try append("\n", to: url)
        let complete = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(complete.readStatus == .complete)
        #expect(complete.terminal != nil)
    }

    @Test func corruptGapBlocksInactivityButExplicitTerminalStillResolves() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start, "broken"])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let partial = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(partial.readStatus == .incomplete)
        try append(completion + "\n", to: url)
        let resolved = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(resolved.readStatus == .complete)
        #expect(resolved.terminal != nil)
    }

    @Test func tokenUsageDoesNotResumeApprovalButAssistantOutputDoes() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let usage = #"{"timestamp":"2026-09-15T08:00:30Z","type":"token_usage_record","payload":{"turn_id":"turn-a"}}"#
        let output = #"{"timestamp":"2026-09-15T08:00:40Z","type":"response_item","payload":{"type":"message","role":"assistant","#
            + #""internal_chat_message_metadata_passthrough":{"turn_id":"turn-a"}}}"#
        let url = try writeRollout(in: directory, lines: [context, start, usage])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let usageState = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(usageState.lastProgressAt != nil)
        #expect(usageState.lastExecutionProgressAt == nil)
        try append(output + "\n", to: url)
        let outputState = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(outputState.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:00:40Z"))
    }

    @Test func missingOrMismatchedRolloutCannotSupplyCachedTerminal() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start, completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal != nil)
        try FileManager.default.removeItem(at: url)
        let missing = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(missing.readStatus == .notFound)
        #expect(missing.terminal == nil)
        _ = try writeRollout(in: directory, lines: [context, completion], session: "other-session")
        let freshReader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let mismatch = try #require(await freshReader.lifecycleStates(for: [reference]).first)
        #expect(mismatch.readStatus == .notFound)
        #expect(mismatch.terminal == nil)
    }

    @Test func fileReplacementDiscardsPriorTerminal() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start, completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal != nil)
        try Data((metadata(session: "session-a") + "\n" + context + "\n" + start + "\n").utf8).write(to: url, options: .atomic)
        let replacement = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(replacement.readStatus == .complete)
        #expect(replacement.terminal == nil)
    }

    @Test func archivedRolloutAndAlternateFilenameAreRecognized() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let filename = "archived_sessions/rollout-test-session-a_00000000-0000-0000-0000-000000000001.jsonl"
        _ = try directory.write(metadata(session: "session-a") + "\n" + completion + "\n", to: filename)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal != nil)
    }

    private var reference: CodexActivityTurnReference {
        CodexActivityTurnReference(sessionId: "session-a", turnId: "turn-a", startedAt: TestFixtures.now)
    }

    private var context: String {
        #"{"timestamp":"2026-09-15T08:00:00Z","type":"turn_context","payload":{"turn_id":"turn-a","approvals_reviewer":"user","effort":" high "}}"#
    }

    private var start: String {
        #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":1789459200}}"#
    }

    private var completion: String {
        #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a","completed_at":1789459260,"duration_ms":60000}}"#
    }

    private func metadata(session: String) -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\",\"source\":\"cli\"}}"
    }

    private func writeRollout(in directory: TestDirectory, lines: [String], session: String = "session-a") throws -> URL {
        let datePath = CodexDateFormat.dayString(from: TestFixtures.now).replacingOccurrences(of: "-", with: "/")
        return try directory.write(([metadata(session: session)] + lines).joined(separator: "\n") + "\n", to: "sessions/\(datePath)/rollout-test-session-a.jsonl")
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
