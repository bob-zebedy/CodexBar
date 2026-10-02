import Foundation
import Testing

struct CodexSessionLifecycleReaderTests {
    @Test(arguments: [false, true], ["whitespace", "invalid-json", "invalid-utf8"])
    func singleLineDecodingPreservesCoverageInBothDirections(historical: Bool, content: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        var data = Data(([metadata(session: "session-a"), context, start, tokenUsage(input: 100)]
                .joined(separator: "\r\n") + "\r\n").utf8)
        switch content {
        case "invalid-json": data.append(contentsOf: "{broken}\r\n".utf8)
        case "invalid-utf8": data.append(contentsOf: [0xFF, 0x0D, 0x0A])
        default: data.append(contentsOf: "\r\n \t\r\n".utf8)
        }
        if historical {
            data.append(contentsOf: (oversizedLine(type: "compacted", payloadByteCount: 1024 * 1024) + "\r\n").utf8)
        }
        let url = try directory.write(data, to: "archived_sessions/rollout-test-session-a.jsonl")
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == (content == "whitespace" ? .complete : .incomplete))
        #expect(state.hasContext)
        #expect(state.startedAt == TestFixtures.now)
        #expect(state.tokenUsage?.totalTokens == (content == "whitespace" ? 110 : nil))
        try append(completion + "\r\n", to: url)
        let completed = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(completed.readStatus == .complete)
        #expect(completed.terminal != nil)
        #expect(!completed.isHistoricalTerminal)
    }

    @Test func completionHasStartDurationContextAndProgress() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try writeRollout(in: directory, lines: [context, start, completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.recordedThreadID == "session-a")
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
        let unchanged = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(unchanged.readStatus == .incomplete)
        #expect(unchanged.terminal == nil)
        try append("\n", to: url)
        let complete = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(complete.readStatus == .complete)
        #expect(complete.terminal != nil)
    }

    @Test func incompleteTailWaitsForFullThresholdAndGrowthRestartsObservation() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        try append(String(completion.dropLast()), to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let firstObserved = TestFixtures.now.addingTimeInterval(7200)
        var task = CodexActivityTask(
            displayID: UUID(), key: CodexActivityTaskKey(event: TestFixtures.event()), event: TestFixtures.event(),
            state: .running, latestEvent: .promptSubmitted, startedAt: TestFixtures.now, progressGeneration: 1
        )

        for elapsed in [0.0, 3599, 3600] {
            let now = firstObserved.addingTimeInterval(elapsed)
            let state = try #require(await reader.lifecycleStates(for: [reference], now: now).first)
            #expect(state.readStatus == .incomplete)
            #expect(state.incompleteTailUnchangedSince == firstObserved)
            task.recordLifecycleRead(state, at: now)
            let deadline = try #require(task.activityProtectionDeadline(at: now, inactivityDuration: 3600))
            #expect((deadline <= now) == (elapsed == 3600))
            #expect(!task.hasFreshLifecycle(at: now))
            #expect(task.lastProgressAt == TestFixtures.now)
        }

        try append("}", to: url)
        let growthTime = firstObserved.addingTimeInterval(3601)
        let growing = try #require(await reader.lifecycleStates(for: [reference], now: growthTime).first)
        #expect(growing.incompleteTailUnchangedSince == growthTime)
        task.recordLifecycleRead(growing, at: growthTime)
        #expect(task.activityProtectionDeadline(at: growthTime, inactivityDuration: 3600) == growthTime.addingTimeInterval(3600))

        try append("\n", to: url)
        let completed = try #require(await reader.lifecycleStates(for: [reference], now: growthTime).first)
        #expect(completed.readStatus == .complete)
        #expect(completed.terminal != nil)
        #expect(completed.incompleteTailUnchangedSince == nil)
    }

    @Test func restartAndFileReplacementStartNewTailObservation() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        try append(completion, to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference], now: TestFixtures.now)
        let later = TestFixtures.now.addingTimeInterval(3600)
        let restarted = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await restarted.lifecycleStates(for: [reference], now: later).first?.incompleteTailUnchangedSince == later)

        let replacement = (metadata(session: "session-a") + "\n" + context + "\n" + start + "\n" + completion)
        try Data(replacement.utf8).write(to: url, options: .atomic)
        #expect(await reader.lifecycleStates(for: [reference], now: later).first?.incompleteTailUnchangedSince == later)
    }

    @Test func unreadableTailClearsObservationAndRecoveryStartsAgain() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        try append(completion, to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference], now: TestFixtures.now)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let unavailable = try #require(await reader.lifecycleStates(for: [reference], now: TestFixtures.now.addingTimeInterval(1)).first)
        #expect(unavailable.readStatus == .unavailable)
        #expect(unavailable.incompleteTailUnchangedSince == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let later = TestFixtures.now.addingTimeInterval(3600)
        #expect(await reader.lifecycleStates(for: [reference], now: later).first?.incompleteTailUnchangedSince == later)
    }

    @Test(arguments: ["missing-context", "read-gap"])
    func incompleteTailRequiresContextWithoutOtherGapsOrTerminal(scenario: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let lines = switch scenario {
        case "missing-context": [start]
        case "read-gap": [context, start, "broken"]
        default: [context, start, "broken"]
        }
        let url = try writeRollout(in: directory, lines: lines)
        try append("{", to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        for _ in 0 ..< 2 {
            let state = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(state.readStatus == .incomplete)
            #expect(state.incompleteTailUnchangedSince == nil)
            #expect(state.terminal == nil)
        }
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

    @Test func lineLargerThanIncrementalBudgetContinuesAcrossReads() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference])

        let compacted = oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)
        try append(compacted + "\n" + completion + "\n", to: url)

        let partial = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(partial.readStatus == .incomplete)
        #expect(partial.terminal == nil)
        #expect(partial.incompleteTailUnchangedSince == nil)
        let resolved = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(resolved.readStatus == .complete)
        #expect(resolved.terminal != nil)
    }

    @Test func lineLargerThanBufferLimitIsSkippedWithoutBlockingTerminal() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference])

        let compacted = oversizedLine(type: "compacted", payloadByteCount: 17 * 1024 * 1024)
        try append(compacted + "\n" + completion + "\n", to: url)

        for _ in 0 ..< 2 {
            let partial = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(partial.readStatus == .incomplete)
            #expect(partial.terminal == nil)
            #expect(partial.incompleteTailUnchangedSince == nil)
        }
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

    @Test(arguments: [false, true])
    func historicalTerminalIsFoundDespiteCompleteTailContextOrPartialTail(partialTail: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, completion, oversizedLine(type: "compacted", payloadByteCount: 1500 * 1024), context
        ])
        if partialTail {
            try append("{", to: url)
        }
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal != nil)
        #expect(state.isHistoricalTerminal)
        #expect(state.incompleteTailUnchangedSince == nil)
    }

    @Test func completeTerminalRemainsUsableWhileNextLineIsPartial() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start, completion])
        try append("{", to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal != nil)
        #expect(state.tokenUsage == nil)
        #expect(state.incompleteTailUnchangedSince == nil)
    }

    @Test func partialTerminalSpanningBootstrapBoundaryIsRecoveredWhenCompleted() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        let largeTerminal = String(completion.dropLast(2)) + ",\"last_agent_message\":\"" + String(repeating: "x", count: 1024 * 1024) + "\"}}"
        try append(largeTerminal, to: url)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal == nil)
        try append("\n", to: url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal != nil)
    }

    @Test func historicalReadsContinuePastEightMiBAndAcrossOversizedLines() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try writeRollout(in: directory, lines: [
            context, start, completion, oversizedLine(type: "compacted", payloadByteCount: 17 * 1024 * 1024), context
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        for _ in 0 ..< 2 {
            let state = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(state.readStatus == .incomplete)
            #expect(state.terminal == nil)
            #expect(state.incompleteTailUnchangedSince == nil)
        }
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal != nil)
    }

    @Test func historicalTerminalCrossingReadBoundaryIsNotDropped() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let tailCount = (8 * 1024 * 1024 - 512 * 1024) - 80
        let tail = oversizedLine(type: "compacted", payloadByteCount: tailCount)
        _ = try writeRollout(in: directory, lines: [context, start, completion, tail])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal == nil)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal != nil)
    }

    @Test func historicalReadsPreserveNewContextUsageAndImplicitProgress() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let newerContext = context.replacingOccurrences(of: "high", with: "low")
            .replacingOccurrences(of: "08:00:00", with: "08:01:00")
        let progress = #"{"timestamp":"2026-09-15T08:02:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        let url = try writeRollout(in: directory, lines: [
            context, start, tokenUsage(input: 100), newerContext,
            oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024),
            tokenUsage(input: 200), progress
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.readStatus == .incomplete)
        try append(progress.replacingOccurrences(of: "08:02:00", with: "08:04:00") + "\n", to: url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal == nil)
        #expect(state.effort == "low")
        #expect(state.contextObservedAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:01:00Z"))
        #expect(state.tokenUsage?.totalTokens == 210)
        #expect(state.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:04:00Z"))
        try append(progress.replacingOccurrences(of: "08:02:00", with: "08:05:00") + "\n", to: url)
        let live = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(live.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:05:00Z"))
        try append(completion + "\n", to: url)
        let completed = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(completed.terminal != nil)
        #expect(!completed.isHistoricalTerminal)
    }

    @Test(arguments: ["agent_message", "function_call_output", "token_count"])
    func progressArrivingAcrossHistoricalReadsKeepsItsExecutionMeaning(kind: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.readStatus == .incomplete)
        let type = kind == "function_call_output" ? "response_item" : "event_msg"
        try append("""
        {"timestamp":"2026-09-15T08:04:00Z","type":"\(type)","payload":{"type":"\(kind)"}}

        """, to: url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.lastProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:04:00Z"))
        #expect((state.lastExecutionProgressAt != nil) == (kind != "token_count"))
        #expect(state.terminal == nil)
    }

    @Test(arguments: [false, true])
    func pendingInitialProgressDoesNotCrossIntoTheNextTurn(switchBeforeFirstRead: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)
        ])
        let progress = #"{"timestamp":"2026-09-15T08:04:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        let nextContext = context.replacingOccurrences(of: "turn-a", with: "turn-b")
        let nextStart = start.replacingOccurrences(of: "turn-a", with: "turn-b")
        let boundary = [progress, nextContext, nextStart].joined(separator: "\n") + "\n"
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        if switchBeforeFirstRead {
            try append(boundary, to: url)
        }
        _ = await reader.lifecycleStates(for: [reference, next])
        if !switchBeforeFirstRead {
            try append(boundary, to: url)
        }
        let states = await reader.lifecycleStates(for: [reference, next])
        let previous = try #require(states.first { $0.turnID == "turn-a" })
        let current = try #require(states.first { $0.turnID == "turn-b" })
        #expect(previous.readStatus == .complete)
        #expect(previous.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:04:00Z"))
        #expect(current.readStatus == .complete)
        #expect(current.lastExecutionProgressAt == nil)
        try append(progress.replacingOccurrences(of: "08:04:00", with: "08:05:00") + "\n", to: url)
        let live = await reader.lifecycleStates(for: [reference, next])
        #expect(live.first { $0.turnID == "turn-a" }?.lastExecutionProgressAt == previous.lastExecutionProgressAt)
        #expect(live.first { $0.turnID == "turn-b" }?.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:05:00Z"))
    }

    @Test(arguments: ["history", "bootstrap", "append"], [1, 9])
    func lateOldTerminalPreservesNewTurnProgressDuringBackfill(location: String, paddingMiB: Int) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let progress = #"{"timestamp":"2026-09-15T08:04:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        var lines = [
            context, start, context.replacingOccurrences(of: "turn-a", with: "turn-b"),
            start.replacingOccurrences(of: "turn-a", with: "turn-b")
        ]
        if location == "history" {
            lines.append(completion)
        }
        lines.append(oversizedLine(type: "compacted", payloadByteCount: paddingMiB * 1024 * 1024))
        if location == "bootstrap" {
            lines.append(completion)
        }
        if location != "append" {
            lines.append(progress)
        }
        let url = try writeRollout(in: directory, lines: lines)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        var state = try #require(await reader.lifecycleStates(for: [next]).first)
        if location == "append" {
            try append(completion + "\n" + progress + "\n", to: url)
        }
        for _ in 0 ..< 3 {
            state = try #require(await reader.lifecycleStates(for: [next]).first)
        }
        #expect(state.readStatus == .complete)
        #expect(state.terminal == nil)
        #expect(state.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:04:00Z"))
        try append(progress.replacingOccurrences(of: "08:04:00", with: "08:05:00") + "\n", to: url)
        let live = try #require(await reader.lifecycleStates(for: [next]).first)
        #expect(live.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:05:00Z"))
    }

    @Test func historicalProgressStopsAtItsOwnTerminalDespiteOtherLateTerminals() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let progress = #"{"timestamp":"2026-09-15T08:02:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        _ = try writeRollout(in: directory, lines: [
            context, start, context.replacingOccurrences(of: "turn-a", with: "turn-b"),
            start.replacingOccurrences(of: "turn-a", with: "turn-b"), progress,
            completion.replacingOccurrences(of: "turn-a", with: "turn-b"), completion,
            progress.replacingOccurrences(of: "08:02:00", with: "08:04:00"),
            oversizedLine(type: "compacted", payloadByteCount: 1024 * 1024)
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        let state = try #require(await reader.lifecycleStates(for: [next]).first)
        #expect(state.terminal != nil)
        #expect(state.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:02:00Z"))
    }

    @Test(arguments: [false, true], ["progress", "context", "usage"])
    func corruptGapSurvivesLateTurnDiscoveryWithoutTaintingNewTurns(duringBackfill: Bool, recordKind: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let progress = #"{"timestamp":"2026-09-15T08:04:00Z","type":"event_msg","payload":{"type":"agent_message","turn_id":"turn-a"}}"#
        let record = recordKind == "context" ? context : recordKind == "usage" ? tokenUsage(input: 200) : progress
        let suffix = [
            "{broken}", record, context.replacingOccurrences(of: "turn-a", with: "turn-b"),
            start.replacingOccurrences(of: "turn-a", with: "turn-b"), tokenUsage(input: 300, turn: "turn-b")
        ]
        var lines = [context, start, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)]
        if !duringBackfill {
            lines += suffix
        }
        let url = try writeRollout(in: directory, lines: lines)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        _ = await reader.lifecycleStates(for: [reference, next])
        if duringBackfill {
            try append(suffix.joined(separator: "\n") + "\n", to: url)
        }
        for _ in 0 ..< 3 {
            let states = await reader.lifecycleStates(for: [reference, next])
            let old = try #require(states.first { $0.turnID == "turn-a" })
            #expect(old.readStatus == .incomplete)
            #expect(old.incompleteTailUnchangedSince == nil)
            #expect(old.tokenUsage == nil)
            #expect(states.first { $0.turnID == "turn-b" }?.readStatus == .complete)
            #expect(states.first { $0.turnID == "turn-b" }?.tokenUsage?.totalTokens == 310)
        }
        try append(completion + "\n", to: url)
        let states = await reader.lifecycleStates(for: [reference, next])
        #expect(states.first { $0.turnID == "turn-a" }?.terminal != nil)
        #expect(states.first { $0.turnID == "turn-b" }?.terminal == nil)
    }

    @Test func pendingProgressStopsAtTerminalBeforeAnotherTurnBegins() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference])
        let progress = #"{"timestamp":"2026-09-15T08:04:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        try append([
            progress, completion, progress.replacingOccurrences(of: "08:04:00", with: "08:09:00"),
            context.replacingOccurrences(of: "turn-a", with: "turn-b"), start.replacingOccurrences(of: "turn-a", with: "turn-b")
        ].joined(separator: "\n") + "\n", to: url)
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        let states = await reader.lifecycleStates(for: [reference, next])
        let previous = try #require(states.first { $0.turnID == "turn-a" })
        let current = try #require(states.first { $0.turnID == "turn-b" })
        #expect(previous.terminal != nil)
        #expect(previous.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:04:00Z"))
        #expect(current.terminal == nil)
        #expect(current.readStatus == .complete)
        #expect(current.lastExecutionProgressAt == nil)
    }

    @Test func corruptBoundaryDiscardsPendingProgressWithoutBlockingANewTurn() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference])
        let progress = #"{"timestamp":"2026-09-15T08:04:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        try append([
            progress, "broken", context.replacingOccurrences(of: "turn-a", with: "turn-b"),
            start.replacingOccurrences(of: "turn-a", with: "turn-b")
        ].joined(separator: "\n") + "\n", to: url)
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        let states = await reader.lifecycleStates(for: [reference, next])
        #expect(states.first { $0.turnID == "turn-a" }?.readStatus == .incomplete)
        #expect(states.first { $0.turnID == "turn-b" }?.readStatus == .complete)
        #expect(states.first { $0.turnID == "turn-b" }?.lastExecutionProgressAt == nil)
    }

    @Test func unassignedProgressAtFileHeadDoesNotClaimCompleteCoverage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024)])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference])
        let progress = #"{"timestamp":"2026-09-15T08:04:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        try append(progress + "\n", to: url)
        for _ in 0 ..< 2 {
            let state = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(state.readStatus == .incomplete)
            #expect(state.lastExecutionProgressAt == nil)
            #expect(state.incompleteTailUnchangedSince == nil)
        }
    }

    @Test(arguments: [false, true])
    func replacingFileClearsUnassignedProgress(atomic: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let progress = #"{"timestamp":"2026-09-15T08:09:00Z","type":"event_msg","payload":{"type":"agent_message"}}"#
        let url = try writeRollout(in: directory, lines: [
            context, start, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024), progress
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        _ = await reader.lifecycleStates(for: [reference])
        let replacement = [metadata(session: "session-a"), context, start, progress.replacingOccurrences(of: "08:09:00", with: "08:02:00")]
            .joined(separator: "\n") + "\n"
        try Data(replacement.utf8).write(to: url, options: atomic ? .atomic : [])
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.lastExecutionProgressAt == CodexDateFormat.iso8601Date(from: "2026-09-15T08:02:00Z"))
    }

    @Test func oldTerminalNeverCompletesAnotherTurnAndHistoryDoesNotReplaceFreshUsage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let nextContext = context.replacingOccurrences(of: "turn-a", with: "turn-b")
        let nextStart = start.replacingOccurrences(of: "turn-a", with: "turn-b")
        _ = try writeRollout(in: directory, lines: [
            context, start, tokenUsage(input: 100), completion,
            oversizedLine(type: "compacted", payloadByteCount: 1200 * 1024),
            tokenUsage(input: 200), nextContext, nextStart
        ])
        let next = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let states = await reader.lifecycleStates(for: [reference, next])
        let previous = try #require(states.first { $0.turnID == "turn-a" })
        #expect(previous.terminal != nil)
        #expect(previous.tokenUsage?.totalTokens == 210)
        let running = try #require(states.first { $0.turnID == "turn-b" })
        #expect(running.terminal == nil)
        #expect(running.readStatus == .complete)
    }

    @Test func multipleFilesShareBudgetAndAllEventuallyReachTheirTerminals() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        var references: [CodexActivityTurnReference] = []
        for session in ["session-a", "session-b", "session-c"] {
            let text = [
                metadata(session: session),
                context,
                start,
                completion,
                oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024),
                context
            ].joined(separator: "\n") + "\n"
            _ = try directory.write(text, to: "archived_sessions/rollout-test-\(session)_00000000-0000-0000-0000-000000000001.jsonl")
            references.append(CodexActivityTurnReference(threadID: session, turnID: "turn-a", startedAt: TestFixtures.now))
        }
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let first = await reader.lifecycleStates(for: references)
        #expect(first.allSatisfy { $0.terminal == nil })
        var completed: Set<String> = []
        for _ in 0 ..< 6 {
            let states = await reader.lifecycleStates(for: references)
            completed.formUnion(states.filter { $0.terminal != nil }.map(\.requestedThreadID))
        }
        #expect(completed == Set(references.map(\.threadID)))
    }

    @Test(arguments: [false, true])
    func replacementOrTruncationDiscardsPendingHistory(atomic: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, completion, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024), context
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal == nil)
        let replacement = Data(([metadata(session: "session-a"), context, start].joined(separator: "\n") + "\n").utf8)
        try replacement.write(to: url, options: atomic ? .atomic : [])
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal == nil)
        #expect(!state.isHistoricalTerminal)
    }

    @Test func archiveMoveDuringHistoricalReadRelocatesWithoutUsingOldCursor() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [
            context, start, completion, oversizedLine(type: "compacted", payloadByteCount: 9 * 1024 * 1024), context
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal == nil)
        let archived = directory.url.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: archived.appendingPathComponent(url.lastPathComponent))
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal == nil)
        #expect(await reader.lifecycleStates(for: [reference]).first?.terminal != nil)
    }

    private var reference: CodexActivityTurnReference {
        CodexActivityTurnReference(threadID: "session-a", turnID: "turn-a", startedAt: TestFixtures.now)
    }

    @Test(arguments: [1, 9])
    func terminalBackfillsUsageAndOwnershipWithoutDelayingCompletion(paddingMiB: Int) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try writeRollout(
            in: directory,
            lines: [context, start, tokenUsage(input: 100)]
                + historyPadding(mebibytes: paddingMiB) + [completion]
        )
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let first = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(first.terminal != nil)
        #expect(first.readStatus == .complete)
        #expect(!first.isHistoricalTerminal)
        #expect(first.tokenUsage?.totalTokens == (paddingMiB == 1 ? 110 : nil))
        let recovered = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(recovered.tokenUsage?.totalTokens == 110)
        #expect(recovered.rootTurnID == "turn-a")
        #expect(!recovered.isHistoricalTerminal)
    }

    @Test(arguments: [31, 33], [false, true])
    func supplementalHistoryStopsAtLimitAndAcceptsAppendedUsage(paddingMiB: Int, hookEnded: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let other = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        let url = try writeRollout(
            in: directory,
            lines: [context, start, tokenUsage(input: 100)]
                + historyPadding(mebibytes: paddingMiB) + (hookEnded ? [] : [completion])
                + [
                    context.replacingOccurrences(of: "turn-a", with: "turn-b"),
                    tokenUsage(input: 300, turn: "turn-b"),
                    completion.replacingOccurrences(of: "turn-a", with: "turn-b")
                ]
        )
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        var query = reference
        query.isTerminalUsageOnly = hookEnded
        for _ in 0 ..< 12 {
            _ = await reader.lifecycleStates(for: [query], now: TestFixtures.now)
            // 用量查询间隔中的其他轮次轮询不能重置累计预算
            _ = await reader.lifecycleStates(for: [other], now: TestFixtures.now)
        }
        let state = try #require(await reader.lifecycleStates(for: [query], now: TestFixtures.now).first)
        #expect(state.tokenUsage?.totalTokens == (paddingMiB == 31 ? 110 : nil))
        #expect(state.rootTurnID == (paddingMiB == 31 ? "turn-a" : nil))
        #expect((state.terminal != nil) == !hookEnded)

        try append([context, start, tokenUsage(input: 200), completion].joined(separator: "\n") + "\n", to: url)
        let updated = try #require(await reader.lifecycleStates(for: [query], now: TestFixtures.now).first)
        #expect(updated.terminal != nil)
        #expect(updated.tokenUsage?.totalTokens == 210)
    }

    @Test(arguments: [false, true])
    func laterSearchCanContinueBeyondSupplementalLimitAndShareResults(usageOnly: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        var other = CodexActivityTurnReference(threadID: "session-a", turnID: "turn-b", startedAt: TestFixtures.now)
        other.isTerminalUsageOnly = usageOnly
        _ = try writeRollout(in: directory, lines: [
            context.replacingOccurrences(of: "turn-a", with: "turn-b"),
            start.replacingOccurrences(of: "turn-a", with: "turn-b"),
            completion.replacingOccurrences(of: "turn-a", with: "turn-b"),
            context, start, tokenUsage(input: 100)
        ] + historyPadding(mebibytes: 33) + [completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        for _ in 0 ..< 8 {
            _ = await reader.lifecycleStates(for: [reference])
        }
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage == nil)
        let states = await reader.lifecycleStates(for: [reference, other])
        #expect(states.first { $0.turnID == "turn-b" }?.terminal != nil)
        #expect(states.first { $0.turnID == "turn-b" }?.isHistoricalTerminal == true)
        #expect(states.first { $0.turnID == "turn-a" }?.tokenUsage?.totalTokens == 110)
    }

    @Test func missingSupplementalInformationReachesHeadAndReplacementResetsBudget() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: historyPadding(mebibytes: 33) + [completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        for _ in 0 ..< 8 {
            _ = await reader.lifecycleStates(for: [reference])
        }
        let replacement = [metadata(session: "session-a"), context, start]
            + historyPadding(mebibytes: 1) + [completion]
        try Data((replacement.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        for _ in 0 ..< 3 {
            let state = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(state.startedAt == TestFixtures.now)
            #expect(state.terminal != nil)
            #expect(state.tokenUsage == nil)
            #expect(state.rootTurnID == nil)
        }
        try append(tokenUsage(input: 200) + "\n", to: url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage?.totalTokens == 210)
    }

    @Test(arguments: [false, true])
    func terminalBackfillDoesNotReplaceLatestUsageWithOlderSnapshot(invalidLatest: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let rootContext = context.replacingOccurrences(of: "\"turn_id\":\"turn-a\"", with: "\"turn_id\":\"turn-a\",\"root_turn_id\":\"turn-a\"")
        let latest = invalidLatest ? tokenUsage(input: 200).replacingOccurrences(of: "\"total_tokens\":210", with: "\"total_tokens\":-1") : tokenUsage(input: 200)
        _ = try writeRollout(
            in: directory,
            lines: [rootContext, start, tokenUsage(input: 100)]
                + historyPadding(mebibytes: 9) + [latest, completion]
        )
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        for _ in 0 ..< 4 {
            let state = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(state.terminal != nil)
            #expect(state.tokenUsage?.totalTokens == (invalidLatest ? nil : 210))
        }
        #expect(await reader.lifecycleStates(for: [reference]).first?.rootTurnID == "turn-a")
    }

    private func historyPadding(mebibytes: Int) -> [String] {
        Array(repeating: oversizedLine(type: "compacted", payloadByteCount: 1024 * 1024), count: mebibytes)
    }

    @Test func tokenUsageUpdatesIncrementallyBeforeTaskCompletion() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage == nil)
        for input in [100, 200, 300] {
            try append(tokenUsage(input: input) + "\n", to: url)
            let state = try #require(await reader.lifecycleStates(for: [reference]).first)
            #expect(state.readStatus == .complete)
            #expect(state.terminal == nil)
            #expect(state.tokenUsage?.totalTokens == Int64(input + 10))
        }
        try append(completion + "\n", to: url)
        let completed = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(completed.terminal != nil)
        #expect(completed.tokenUsage?.totalTokens == 310)
    }

    @Test func tokenUsageUsesLatestTurnSnapshotWithoutDoubleCounting() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let latest = tokenUsage(input: 200)
        _ = try writeRollout(in: directory, lines: [context, start, tokenUsage(input: 100), latest, latest, completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.tokenUsage?.inputTokens == 200)
        #expect(state.tokenUsage?.totalTokens == 210)
        #expect(state.rootTurnID == "turn-a")
    }

    @Test func lateUsageAfterAbortIsReadWithoutIncludingNextTurn() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let abort = #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}"#
        let url = try writeRollout(in: directory, lines: [context, start, tokenUsage(input: 100), abort])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage?.totalTokens == 110)
        try append(tokenUsage(input: 200) + "\n" + tokenUsage(input: 999, turn: "turn-b") + "\n", to: url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.tokenUsage?.totalTokens == 210)
        guard case .aborted = state.terminal else {
            Issue.record("Expected the aborted turn to retain its terminal state")
            return
        }
    }

    @Test(arguments: ["wrong-thread", "wrong-session", "missing", "negative", "overflow", "wrong-type"])
    func invalidUsageDoesNotBreakTerminalOrReusePreviousCount(scenario: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let valid = tokenUsage(input: 100)
        let invalid = switch scenario {
        case "wrong-thread": valid.replacingOccurrences(of: #""thread_id":"session-a""#, with: #""thread_id":"other""#)
        case "wrong-session": valid.replacingOccurrences(of: #""session_id":"session-a""#, with: #""session_id":"other""#)
        case "missing": valid.replacingOccurrences(of: #""input_tokens":100,"#, with: "")
        case "negative": valid.replacingOccurrences(of: #""cached_input_tokens":20"#, with: #""cached_input_tokens":-1"#)
        case "overflow": valid.replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":9223372036854775807"#)
        default: valid.replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":"100""#)
        }
        _ = try writeRollout(in: directory, lines: [context, start, valid, invalid, completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.readStatus == .complete)
        #expect(state.terminal != nil)
        #expect(state.tokenUsage == nil)
    }

    @Test func oldTokenCountDoesNotBecomeZeroOrAUsageRecord() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try writeRollout(in: directory, lines: [
            context,
            start,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":999}}}}"#,
            completion
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage == nil)
    }

    @Test func corruptGapDropsUsageUntilAFreshCumulativeRecordArrives() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start, tokenUsage(input: 100), completion, "broken"])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let state = try #require(await reader.lifecycleStates(for: [reference]).first)
        #expect(state.terminal != nil)
        #expect(state.tokenUsage == nil)
        try append(tokenUsage(input: 200) + "\n", to: url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage?.totalTokens == 210)
    }

    @Test func tailBootstrapUsesCumulativeUsageEvenWhenEarlierResponsesAreOutsideWindow() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try writeRollout(in: directory, lines: [
            context,
            start,
            tokenUsage(input: 100),
            oversizedLine(type: "response_item", payloadByteCount: 600 * 1024),
            tokenUsage(input: 200),
            completion
        ])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage?.totalTokens == 210)
    }

    @Test func partialUsageAndFileReplacementDoNotExposeStaleCounts() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try writeRollout(in: directory, lines: [context, start, tokenUsage(input: 100), completion])
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage?.totalTokens == 110)
        try append(tokenUsage(input: 200), to: url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage == nil)
        try append("\n", to: url)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage?.totalTokens == 210)
        try Data((metadata(session: "session-a") + "\n" + context + "\n" + completion + "\n").utf8).write(to: url, options: .atomic)
        #expect(await reader.lifecycleStates(for: [reference]).first?.tokenUsage == nil)
    }

    private func tokenUsage(input: Int, turn: String = "turn-a") -> String {
        """
        {"type":"token_usage_record","payload":{"thread_id":"session-a","session_id":"session-a","turn_id":"\(turn)",\
        "root_turn_id":"\(turn)","response_id":"response-\(input)","turn_token_usage":{\
        "input_tokens":\(input),"cached_input_tokens":20,"cache_write_input_tokens":0,\
        "output_tokens":10,"reasoning_output_tokens":2,"total_tokens":\(input + 10)}}}
        """
    }

    @Test(arguments: [0, 9])
    func forkedMetadataDoesNotReplaceChildUsageIdentity(paddingMiB: Int) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let childMetadata = #"{"type":"session_meta","payload":{"id":"child-a","session_id":"session-a","parent_thread_id":"session-a","#
            + #""source":{"subagent":{"thread_spawn":{"parent_thread_id":"session-a"}}}}}"#
        let usage = tokenUsage(input: 100, turn: "child-turn")
            .replacingOccurrences(of: #""thread_id":"session-a""#, with: #""thread_id":"child-a""#)
            .replacingOccurrences(of: #""root_turn_id":"child-turn""#, with: #""root_turn_id":"turn-a""#)
        let datePath = CodexDateFormat.dayString(from: TestFixtures.now).replacingOccurrences(of: "-", with: "/")
        _ = try directory.write(
            ([childMetadata, metadata(session: "session-a"), usage] + historyPadding(mebibytes: paddingMiB)
                + [completion.replacingOccurrences(of: "turn-a", with: "child-turn")])
                .joined(separator: "\n") + "\n",
            to: "sessions/\(datePath)/rollout-test-child-a.jsonl"
        )
        let reader = CodexSessionLifecycleReader(codexHomeURL: directory.url)
        let child = CodexActivityTurnReference(threadID: "child-a", turnID: "child-turn", startedAt: TestFixtures.now)
        #expect(await reader.lifecycleStates(for: [child]).first?.terminal != nil)
        let state = try #require(await reader.lifecycleStates(for: [child]).first)
        #expect(state.recordedThreadID == "child-a")
        #expect(state.rootSessionID == "session-a")
        #expect(state.rootTurnID == "turn-a")
        #expect(state.tokenUsage?.totalTokens == 110)
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

    private func oversizedLine(type: String, payloadByteCount: Int) -> String {
        "{\"type\":\"\(type)\",\"payload\":{\"data\":\"\(String(repeating: "x", count: payloadByteCount))\"}}"
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
