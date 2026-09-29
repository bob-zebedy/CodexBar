import Foundation
import Testing

struct CodexActivityTokenUsageTests {
    @Test func cacheHitRateUsesAllInputAndIsUnavailableWithoutInput() {
        let usage = CodexTokenUsage(
            inputTokens: 1000, cachedInputTokens: 800, cacheWriteInputTokens: 100,
            outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 1200
        )
        #expect(usage.cacheHitRate == 0.8)
        let outputOnly = CodexTokenUsage(
            inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 200
        )
        #expect(outputOnly.cacheHitRate == nil)
    }

    @Test func rootAndMultipleChildTurnsAreSummedOnce() throws {
        let root = reference("session-a", "turn-a")
        let first = reference("child-a", "child-turn-a")
        let second = reference("child-a", "child-turn-b")
        let third = reference("child-b", "child-turn-c")
        let request = request(root: root, children: [first, second, third, first])
        let states = [state(root, input: 100), state(first, input: 200), state(second, input: 300), state(third, input: 400)]
        let usage = try #require(request.usage(from: states))
        #expect(usage.inputTokens == 1000)
        #expect(usage.outputTokens == 40)
        #expect(usage.totalTokens == 1040)
        #expect(usage.cachedInputTokens == 80)
    }

    @Test(arguments: ["missing", "unavailable", "other-root", "other-session", "running-child", "missing-usage"])
    func incompleteOrUnrelatedChildPreventsPartialTotal(scenario: String) {
        let root = reference("session-a", "turn-a")
        let child = reference("child-a", "child-turn")
        let request = request(root: root, children: [child])
        var childState = state(child)
        switch scenario {
        case "unavailable": childState.readStatus = .unavailable
        case "other-root": childState.rootTurnId = "other-root"
        case "other-session": childState.rootSessionId = "other-session"
        case "missing-usage": childState.tokenUsage = nil
        case "running-child": childState = state(child, terminal: nil)
        default: break
        }
        let states = scenario == "missing" ? [state(root)] : [state(root), childState]
        #expect(request.usage(from: states) == nil)
    }

    @Test func knownAgentWithoutResolvedTurnPreventsPartialTotal() {
        let root = reference("session-a", "turn-a")
        let request = CodexTaskTokenUsageRequest(
            root: root, expectedAgentIDs: ["unknown-child"], references: [root], deadline: TestFixtures.now
        )
        #expect(request.usage(from: [state(root)]) == nil)
    }

    @Test func inProgressUsageIncludesAvailableRunningAndCompletedChildren() throws {
        let root = reference("session-a", "turn-a")
        let running = reference("child-a", "child-turn-a")
        let completed = reference("child-a", "child-turn-b")
        let unknown = reference("child-b", "child-turn-c")
        let request = request(root: root, children: [running, completed, unknown, running])
        let states = [state(root, terminal: nil), state(running, input: 200, terminal: nil), state(completed, input: 300)]
        let usage = try #require(request.usage(from: states, requiresFinalUsage: false))
        #expect(usage.totalTokens == 630)
        #expect(usage.cachedInputTokens == 60)
        #expect(request.usage(from: states) == nil)
        #expect(request.usage(from: [], requiresFinalUsage: false) == nil)
    }

    @Test(arguments: ["other-root", "other-session", "other-thread", "unavailable", "missing-usage"])
    func inProgressUsageDoesNotIncludeUnverifiedChildren(scenario: String) {
        let root = reference("session-a", "turn-a")
        let child = reference("child-a", "child-turn")
        let request = request(root: root, children: [child])
        var childState = state(child, terminal: nil)
        switch scenario {
        case "other-root": childState.rootTurnId = "other-root"
        case "other-session": childState.rootSessionId = "other-session"
        case "other-thread": childState.threadId = "other-thread"
        case "unavailable": childState.readStatus = .unavailable
        default: childState.tokenUsage = nil
        }
        let states = [state(root, terminal: nil), childState]
        #expect(request.usage(from: states, requiresFinalUsage: false)?.totalTokens == 110)
    }

    @Test func activeSnapshotsUpdateBeforeCompletionAndKeepCompletedChildReferences() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let event = TestFixtures.event()
        let key = CodexActivityTaskKey(event: event)
        monitor.tasks[key] = CodexActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            latestEvent: .promptSubmitted, startedAt: TestFixtures.now, progressGeneration: 1
        )
        let root = reference("session-a", "turn-a")
        let child = reference("child-a", "child-turn")
        monitor.subagentTurnLinks[child] = key
        #expect(Set(monitor.activeTokenUsageReferences()) == [root, child])
        #expect(monitor.tasks[key]?.snapshot.tokenUsage == nil)
        let initial = [state(root, terminal: nil)]
        #expect(monitor.applyActiveTokenUsage(initial))
        let running = try #require(monitor.tasks[key]?.snapshot)
        #expect(CodexPrimaryActivity.running(running).tokenUsage?.totalTokens == 110)
        #expect(!monitor.applyActiveTokenUsage(initial))

        monitor.tasks[key]?.state = .waitingApproval
        let updated = [state(root, input: 200, terminal: nil), state(child, input: 300)]
        #expect(monitor.applyActiveTokenUsage(updated))
        let waiting = try #require(monitor.tasks[key]?.snapshot)
        #expect(CodexPrimaryActivity.waiting(waiting).tokenUsage?.totalTokens == 520)
        #expect(monitor.tasks[key]?.state == .waitingApproval)
        #expect(monitor.pendingTerminalPresentationEvents.isEmpty)
        #expect(monitor.completions.isEmpty)

        let task = try #require(monitor.tasks[key])
        var transitions: [CodexActivityTransition] = []
        monitor.resolveTerminal(
            .completed(at: TestFixtures.now, duration: 1), task: task, key: key,
            abortFallback: TestFixtures.now, into: &transitions
        )
        #expect(monitor.applyTerminalTokenUsage(updated))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 520)
    }

    @Test func activeUsageDoesNotCarryAcrossTurnsOrKeepUnavailableData() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let event = TestFixtures.event(turn: "turn-b")
        let key = CodexActivityTaskKey(event: event)
        monitor.tasks[key] = CodexActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            latestEvent: .promptSubmitted, startedAt: TestFixtures.now, progressGeneration: 1
        )
        #expect(!monitor.applyActiveTokenUsage([state(reference("session-a", "turn-a"))]))
        #expect(monitor.tasks[key]?.tokenUsage == nil)
        var current = state(reference("session-a", "turn-b"), terminal: nil)
        current.rootTurnId = "turn-b"
        #expect(monitor.applyActiveTokenUsage([current]))
        #expect(monitor.tasks[key]?.tokenUsage?.totalTokens == 110)
        current.readStatus = .unavailable
        #expect(monitor.applyActiveTokenUsage([current]))
        #expect(monitor.tasks[key]?.tokenUsage == nil)
    }

    @Test func overflowIsRejectedAndConfirmedZeroRemainsAvailable() {
        let large = CodexTokenUsage(
            inputTokens: .max, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: .max
        )
        #expect(large.isValid)
        #expect(large.adding(large) == nil)
        let zero = CodexTokenUsage(
            inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0
        )
        #expect(zero.isValid)
        #expect(zero.adding(large) == large)
    }

    @Test func completedAndInterruptedTasksReceiveLateUsageWithoutNewTerminalEvents() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let event = TestFixtures.event()
        let key = CodexActivityTaskKey(event: event)
        let task = CodexActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            latestEvent: .promptSubmitted, startedAt: TestFixtures.now, progressGeneration: 1
        )
        var transitions: [CodexActivityTransition] = []
        monitor.resolveTerminal(
            .completed(at: TestFixtures.now, duration: 1), task: task, key: key,
            abortFallback: TestFixtures.now, into: &transitions
        )
        let completedID = try #require(monitor.completions.first?.id)
        let otherEvent = TestFixtures.event(turn: "turn-b")
        let otherKey = CodexActivityTaskKey(event: otherEvent)
        monitor.tasks[otherKey] = CodexActivityTask(
            displayID: UUID(), key: otherKey, event: otherEvent, state: .running,
            latestEvent: .promptSubmitted, startedAt: TestFixtures.now, progressGeneration: 1
        )
        monitor.interruptTask(from: otherEvent, source: .bootstrap)
        #expect(monitor.completions.first?.tokenUsage == nil)
        #expect(monitor.terminations.first?.tokenUsage == nil)

        var stopped = state(reference("session-a", "turn-b"), input: 200, terminal: nil)
        stopped.rootTurnId = "turn-b"
        let states = [state(reference("session-a", "turn-a")), stopped]
        #expect(monitor.applyTerminalTokenUsage(states))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        #expect(monitor.terminations.first?.tokenUsage?.totalTokens == 210)
        #expect(monitor.completions.first?.id == completedID)
        #expect(monitor.pendingTerminalPresentationEvents.isEmpty)
        #expect(!monitor.applyTerminalTokenUsage(states))
        stopped.readStatus = .unavailable
        #expect(!monitor.applyTerminalTokenUsage([stopped]))
        #expect(monitor.terminations.first?.tokenUsage?.totalTokens == 210)
        _ = monitor.terminalTokenUsageReferences(now: Date().addingTimeInterval(31))
        #expect(monitor.terminalTokenUsageRequests.isEmpty)
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        monitor.clearCollectedActivityState()
        #expect(monitor.completions.isEmpty)
    }

    @Test func laterTurnPendingAgentMustNotEraseCompletedTurnUsage() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let first = TestFixtures.event()
        let firstKey = CodexActivityTaskKey(event: first)
        let task = CodexActivityTask(
            displayID: UUID(), key: firstKey, event: first, state: .running,
            latestEvent: .promptSubmitted, startedAt: TestFixtures.now, progressGeneration: 1
        )
        var transitions: [CodexActivityTransition] = []
        monitor.resolveTerminal(.completed(at: TestFixtures.now, duration: 1), task: task, key: firstKey, abortFallback: TestFixtures.now, into: &transitions)
        let firstState = state(reference("session-a", "turn-a"))
        _ = monitor.applyTerminalTokenUsage([firstState])
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        let second = TestFixtures.event(at: TestFixtures.now.addingTimeInterval(2), turn: "turn-b")
        let secondKey = CodexActivityTaskKey(event: second)
        monitor.tasks[secondKey] = CodexActivityTask(
            displayID: UUID(), key: secondKey, event: second, state: .running,
            latestEvent: .promptSubmitted, startedAt: second.timestamp, progressGeneration: 2
        )
        let child = TestFixtures.event(.subagentStart, at: TestFixtures.now.addingTimeInterval(3), turn: "child-turn-b", agent: "child-b")
        #expect(monitor.deferUnassociatedSubagentEvent(child, source: .live))
        _ = monitor.applyTerminalTokenUsage([firstState])
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        let lateChild = reference("child-a", "child-turn-a")
        monitor.subagentTurnLinks[lateChild] = firstKey
        #expect(!monitor.applyTerminalTokenUsage([firstState]))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        #expect(monitor.applyTerminalTokenUsage([firstState, state(lateChild, input: 200)]))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 320)
        var unavailable = firstState
        unavailable.readStatus = .unavailable
        #expect(!monitor.applyTerminalTokenUsage([unavailable]))
        _ = monitor.terminalTokenUsageReferences(now: Date().addingTimeInterval(31))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 320)
    }

    private func reference(_ thread: String, _ turn: String) -> CodexActivityTurnReference {
        CodexActivityTurnReference(sessionId: thread, turnId: turn, startedAt: TestFixtures.now)
    }

    private func request(root: CodexActivityTurnReference, children: [CodexActivityTurnReference]) -> CodexTaskTokenUsageRequest {
        CodexTaskTokenUsageRequest(
            root: root, expectedAgentIDs: Set(children.map(\.sessionId)), references: Set([root] + children), deadline: TestFixtures.now
        )
    }

    private func state(
        _ reference: CodexActivityTurnReference, input: Int64 = 100,
        terminal: CodexSessionTaskTerminalState? = .completed(at: TestFixtures.now, duration: 1)
    ) -> CodexSessionTaskLifecycleState {
        CodexSessionTaskLifecycleState(
            sessionId: reference.sessionId, turnId: reference.turnId, startedAt: TestFixtures.now,
            approvalReviewer: nil, effort: nil, lastProgressAt: TestFixtures.now, terminal: terminal,
            rootTurnId: "turn-a", threadId: reference.sessionId, rootSessionId: "session-a",
            tokenUsage: CodexTokenUsage(
                inputTokens: input, cachedInputTokens: 20, cacheWriteInputTokens: 0,
                outputTokens: 10, reasoningOutputTokens: 2, totalTokens: input + 10
            )
        )
    }

    private func makeMonitor(directory: TestDirectory, preferences: TestPreferences) throws -> CodexActivityMonitor {
        try CodexActivityMonitor(
            codexHookSettings: CodexHookSettings(
                hooksURL: directory.url.appendingPathComponent("hooks.json"),
                codexStatusService: makeStatusService(suiteName: preferences.suite)
            ),
            activityProtectionSettings: ActivityProtectionSettings(defaults: preferences.defaults),
            activityProtectionStateStore: ActivityProtectionStateStore(directoryURL: directory.url)
        )
    }

    private nonisolated func makeStatusService(suiteName: String) throws -> CodexStatusService {
        try CodexStatusService(defaults: #require(UserDefaults(suiteName: suiteName)))
    }
}
