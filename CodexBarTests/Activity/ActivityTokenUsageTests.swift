import Foundation
import Testing

struct ActivityTokenUsageTests {
    @Test func cacheHitRateUsesAllInputAndIsUnavailableWithoutInput() {
        let usage = TokenUsage(
            inputTokens: 1000, cachedInputTokens: 800, cacheWriteInputTokens: 100,
            outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 1200
        )
        #expect(usage.cacheHitRate == 0.8)
        let outputOnly = TokenUsage(
            inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 200
        )
        #expect(outputOnly.cacheHitRate == nil)
    }

    @Test(arguments: [true, false])
    func rootAndMultipleChildTurnsAreSummedOnce(explicitRootThread: Bool) throws {
        let root = reference("thread-a", "turn-a")
        let first = reference("child-a", "child-turn-a")
        let second = reference("child-a", "child-turn-b")
        let third = reference("child-b", "child-turn-c")
        let request = request(root: root, children: [first, second, third, first])
        var rootState = state(root, input: 100)
        rootState.rootThreadID = explicitRootThread ? root.threadID : nil
        let states = [rootState, state(first, input: 200), state(second, input: 300), state(third, input: 400)]
        let usage = try #require(request.usage(from: states))
        #expect(usage.inputTokens == 1000)
        #expect(usage.outputTokens == 40)
        #expect(usage.totalTokens == 1040)
        #expect(usage.cachedInputTokens == 80)
    }

    @Test(arguments: ["missing", "unavailable", "other-root", "other-session", "running-child", "missing-usage"])
    func incompleteOrUnrelatedChildPreventsPartialTotal(scenario: String) {
        let root = reference("thread-a", "turn-a")
        let child = reference("child-a", "child-turn")
        let request = request(root: root, children: [child])
        var childState = state(child)
        switch scenario {
        case "unavailable": childState.readStatus = .unavailable
        case "other-root": childState.rootTurnID = "other-root"
        case "other-session": childState.rootThreadID = "other-session"
        case "missing-usage": childState.tokenUsage = nil
        case "running-child": childState = state(child, terminal: nil)
        default: break
        }
        let states = scenario == "missing" ? [state(root)] : [state(root), childState]
        #expect(request.usage(from: states) == nil)
    }

    @Test func knownAgentWithoutResolvedTurnPreventsPartialTotal() {
        let root = reference("thread-a", "turn-a")
        let request = TaskTokenRequest(
            root: root, expectedAgentIDs: ["unknown-child"], references: [root]
        )
        #expect(request.usage(from: [state(root)]) == nil)
    }

    @Test func inProgressUsageIncludesAvailableRunningAndCompletedChildren() throws {
        let root = reference("thread-a", "turn-a")
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
        let root = reference("thread-a", "turn-a")
        let child = reference("child-a", "child-turn")
        let request = request(root: root, children: [child])
        var childState = state(child, terminal: nil)
        switch scenario {
        case "other-root": childState.rootTurnID = "other-root"
        case "other-session": childState.rootThreadID = "other-session"
        case "other-thread": childState = state(reference("other-thread", child.turnID), terminal: nil)
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
        let key = try #require(ActivityTaskKey(event: event))
        monitor.tasks[key] = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        let root = reference("thread-a", "turn-a")
        let child = reference("child-a", "child-turn")
        monitor.subagentTurnLinks[child] = (key, TestFixtures.now)
        #expect(Set(monitor.activeTokenUsageReferences()) == [root, child])
        #expect(monitor.tasks[key]?.snapshot.tokenUsage == nil)
        let initial = [state(root, terminal: nil)]
        #expect(monitor.applyActiveTokenUsage(initial))
        let running = try #require(monitor.tasks[key]?.snapshot)
        #expect(running.tokenUsage?.totalTokens == 110)
        #expect(!monitor.applyActiveTokenUsage(initial))

        monitor.tasks[key]?.state = .waitingApproval
        let updated = [state(root, input: 200, terminal: nil), state(child, input: 300)]
        #expect(monitor.applyActiveTokenUsage(updated))
        let waiting = try #require(monitor.tasks[key]?.snapshot)
        #expect(waiting.tokenUsage?.totalTokens == 520)
        #expect(monitor.tasks[key]?.state == .waitingApproval)
        #expect(monitor.pendingTerminalPresentationEvents.isEmpty)
        #expect(monitor.completions.isEmpty)

        let task = try #require(monitor.tasks[key])
        var transitions: [ActivityTransition] = []
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
        let key = try #require(ActivityTaskKey(event: event))
        monitor.tasks[key] = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        #expect(!monitor.applyActiveTokenUsage([state(reference("thread-a", "turn-a"))]))
        #expect(monitor.tasks[key]?.tokenUsage == nil)
        var current = state(reference("thread-a", "turn-b"), terminal: nil)
        current.rootTurnID = "turn-b"
        #expect(monitor.applyActiveTokenUsage([current]))
        #expect(monitor.tasks[key]?.tokenUsage?.totalTokens == 110)
        current.readStatus = .unavailable
        #expect(monitor.applyActiveTokenUsage([current]))
        #expect(monitor.tasks[key]?.tokenUsage == nil)
    }

    @Test func overflowIsRejectedAndConfirmedZeroRemainsAvailable() {
        let large = TokenUsage(
            inputTokens: .max, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: .max
        )
        #expect(large.isValid)
        #expect(large.adding(large) == nil)
        let zero = TokenUsage(
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
        let key = try #require(ActivityTaskKey(event: event))
        let task = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        monitor.resolveTerminal(
            .completed(at: TestFixtures.now, duration: 1), task: task, key: key,
            abortFallback: TestFixtures.now, into: &transitions
        )
        let completedID = try #require(monitor.completions.first?.id)
        let otherEvent = TestFixtures.event(.turnAborted, turn: "turn-b")
        let otherKey = try #require(ActivityTaskKey(event: otherEvent))
        monitor.tasks[otherKey] = ActivityTask(
            displayID: UUID(), key: otherKey, event: otherEvent, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        monitor.finishTask(from: otherEvent, source: .bootstrap, into: &transitions)
        #expect(monitor.completions.first?.tokenUsage == nil)
        #expect(monitor.terminations.first?.tokenUsage == nil)

        var stopped = state(reference("thread-a", "turn-b"), input: 200, terminal: nil)
        stopped.rootTurnID = "turn-b"
        let states = [state(reference("thread-a", "turn-a")), stopped]
        #expect(monitor.applyTerminalTokenUsage(states))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        #expect(monitor.terminations.first?.tokenUsage?.totalTokens == 210)
        #expect(monitor.completions.first?.id == completedID)
        #expect(monitor.pendingTerminalPresentationEvents.isEmpty)
        #expect(!monitor.applyTerminalTokenUsage(states))
        stopped.readStatus = .unavailable
        #expect(!monitor.applyTerminalTokenUsage([stopped]))
        #expect(monitor.terminations.first?.tokenUsage?.totalTokens == 210)
        let terminalReferences = monitor.terminalTokenUsageReferences()
        #expect(terminalReferences.count == 2)
        let laterReferences = monitor.terminalTokenUsageReferences()
        #expect(Set(laterReferences) == Set(terminalReferences))
        #expect(monitor.terminalTokenUsageRequests.count == 2)
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
        let firstKey = try #require(ActivityTaskKey(event: first))
        let task = ActivityTask(
            displayID: UUID(), key: firstKey, event: first, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        monitor.resolveTerminal(.completed(at: TestFixtures.now, duration: 1), task: task, key: firstKey, abortFallback: TestFixtures.now, into: &transitions)
        let firstState = state(reference("thread-a", "turn-a"))
        _ = monitor.applyTerminalTokenUsage([firstState])
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        let second = TestFixtures.event(at: TestFixtures.now.addingTimeInterval(2), turn: "turn-b")
        let secondKey = try #require(ActivityTaskKey(event: second))
        monitor.tasks[secondKey] = ActivityTask(
            displayID: UUID(), key: secondKey, event: second, state: .running,
            startedAt: second.timestamp, progressGeneration: 2
        )
        let child = TestFixtures.event(.subagentStarted, at: TestFixtures.now.addingTimeInterval(3), turn: "child-turn-b", agent: "child-b")
        #expect(monitor.deferUnassociatedSubagentEvent(child, source: .live))
        _ = monitor.applyTerminalTokenUsage([firstState])
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        let lateChild = reference("child-a", "child-turn-a")
        monitor.subagentTurnLinks[lateChild] = (firstKey, TestFixtures.now)
        #expect(!monitor.applyTerminalTokenUsage([firstState]))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 110)
        #expect(monitor.applyTerminalTokenUsage([firstState, state(lateChild, input: 200)]))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 320)
        var unavailable = firstState
        unavailable.readStatus = .unavailable
        #expect(!monitor.applyTerminalTokenUsage([unavailable]))
        _ = monitor.terminalTokenUsageReferences()
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 320)
    }

    @Test(arguments: [false, true])
    func historicalTerminalUpdatesHistoryWithoutPublishingEvents(aborted: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        monitor.isActivitySourceHealthy = true
        monitor.isProtectionRecoveryInProgress = false
        let now = Date()
        monitor.sessionTransitionNotBefore = now.addingTimeInterval(-1)
        monitor.terminalPresentationNotBefore = now.addingTimeInterval(-1)
        #expect(monitor.canPublishActivityTransitions)
        for publishesEvents in [false, true] {
            let event = TestFixtures.event(at: now, turn: publishesEvents ? "live-turn" : "historical-turn")
            let key = try #require(ActivityTaskKey(event: event))
            let task = ActivityTask(
                displayID: UUID(), key: key, event: event, state: .running,
                startedAt: now, progressGeneration: 1
            )
            var transitions: [ActivityTransition] = []
            monitor.resolveTerminal(
                aborted ? .aborted(at: now, duration: nil) : .completed(at: now, duration: 1),
                task: task, key: key, abortFallback: now, publishesEvents: publishesEvents, into: &transitions
            )
            #expect(transitions.isEmpty == (aborted || !publishesEvents))
            #expect(monitor.pendingTerminalPresentationEvents.isEmpty == !publishesEvents)
            #expect(monitor.recentEndedDate(for: key, now: now) != nil)
            let presentationCount = monitor.pendingTerminalPresentationEvents.count
            monitor.resolveTerminal(
                aborted ? .aborted(at: now, duration: nil) : .completed(at: now, duration: 1),
                task: task, key: key, abortFallback: now, publishesEvents: true, into: &transitions
            )
            #expect(monitor.pendingTerminalPresentationEvents.count == presentationCount)
        }
        #expect(aborted ? monitor.terminations.count == 2 : monitor.completions.count == 2)
        #expect(monitor.terminalTokenUsageRequests.count == 2)
    }

    @Test(arguments: [false, true])
    func liveTerminalPresentationPreservesInterruptBehavior(interrupted: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        monitor.isActivitySourceHealthy = true
        monitor.isProtectionRecoveryInProgress = false
        let now = Date()
        monitor.sessionTransitionNotBefore = now.addingTimeInterval(-1)
        monitor.terminalPresentationNotBefore = now.addingTimeInterval(-1)
        let event = TestFixtures.event(.turnAborted, at: now)
        let key = try #require(ActivityTaskKey(event: event))
        let task = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        if interrupted {
            monitor.tasks[key] = task
            monitor.finishTask(from: event, source: .live, into: &transitions)
            monitor.finishTask(from: event, source: .live, into: &transitions)
            #expect(monitor.tasks.isEmpty)
            #expect(monitor.terminations.count == 1)
        } else {
            monitor.resolveTerminal(
                .completed(at: now, duration: 1), task: task, key: key,
                abortFallback: now, into: &transitions
            )
            #expect(monitor.completions.count == 1)
        }
        #expect(transitions.count == (interrupted ? 0 : 1))
        #expect(monitor.pendingTerminalPresentationEvents.count == 1)
        #expect(monitor.terminalTokenUsageRequests.count == 1)
    }

    @Test(arguments: [ActivityTaskState.running, .waitingApproval])
    func tasksDoNotExpireWithoutProgress(state: ActivityTaskState) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let now = Date()
        let old = now.addingTimeInterval(-ActivityRetention.window - 1)
        let event = TestFixtures.event(at: old)
        let key = try #require(ActivityTaskKey(event: event))
        monitor.tasks[key] = ActivityTask(
            displayID: UUID(), key: key, event: event, state: state,
            startedAt: old, progressGeneration: 1
        )
        monitor.refreshSnapshot(now: now)
        #expect(monitor.tasks.count == 1)
        #expect(monitor.snapshot.activeCount == 1)
    }

    @Test(arguments: [false, true])
    func terminalUsageContinuesUntilCardIsRemoved(clearExplicitly: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let now = Date()
        let event = TestFixtures.event(at: now)
        let key = try #require(ActivityTaskKey(event: event))
        let task = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        monitor.resolveTerminal(.completed(at: now, duration: 1), task: task, key: key, abortFallback: now, into: &transitions)
        let root = reference("thread-a", "turn-a")
        #expect(monitor.terminalTokenUsageReferences().contains(root))
        #expect(monitor.terminalTokenUsageReferences().contains(root))
        #expect(monitor.applyTerminalTokenUsage([state(root, input: 500)]))
        #expect(monitor.completions.first?.tokenUsage?.totalTokens == 510)
        if clearExplicitly {
            monitor.clearCollectedActivityState()
        } else {
            monitor.refreshSnapshot(now: now.addingTimeInterval(601))
        }
        #expect(monitor.completions.isEmpty)
        #expect(monitor.terminalTokenUsageRequests.isEmpty)
        #expect(monitor.terminalTokenUsageReferences().isEmpty)
    }

    private func reference(_ thread: String, _ turn: String) -> ActivityTurnReference {
        ActivityTurnReference(threadID: thread, turnID: turn)
    }

    private func request(root: ActivityTurnReference, children: [ActivityTurnReference]) -> TaskTokenRequest {
        TaskTokenRequest(
            root: root, expectedAgentIDs: Set(children.map(\.threadID)), references: Set([root] + children)
        )
    }

    private func state(
        _ reference: ActivityTurnReference, input: Int64 = 100,
        terminal: SessionTerminalState? = .completed(at: TestFixtures.now, duration: 1)
    ) -> SessionLifecycleState {
        SessionLifecycleState(
            requestedThreadID: reference.threadID, turnID: reference.turnID, startedAt: TestFixtures.now,
            effort: nil, lastProgressAt: TestFixtures.now, terminal: terminal,
            rootTurnID: "turn-a", rootThreadID: "thread-a",
            tokenUsage: TokenUsage(
                inputTokens: input, cachedInputTokens: 20, cacheWriteInputTokens: 0,
                outputTokens: 10, reasoningOutputTokens: 2, totalTokens: input + 10
            )
        )
    }

    private func makeMonitor(directory: TestDirectory, preferences: TestPreferences) throws -> ActivityMonitor {
        ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url)
        )
    }

    private nonisolated func makeStatusService(suiteName: String) -> CodexStatusService {
        CodexStatusService(socketURL: URL(fileURLWithPath: "/tmp/\(suiteName).sock"))
    }
}

extension ActivityTokenUsageTests {
    @Test func unknownCompletionTimeDoesNotInventDurationOrRepeatCompletion() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let now = Date()
        let event = TestFixtures.event(at: now.addingTimeInterval(-60))
        let key = try #require(ActivityTaskKey(event: event))
        let task = ActivityTask(
            displayID: UUID(),
            key: key,
            event: event,
            state: .running,
            startedAt: now.addingTimeInterval(-60),
            progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        monitor.resolveTerminal(
            .completed(at: nil, duration: nil),
            task: task,
            key: key,
            abortFallback: now,
            publishesEvents: false,
            into: &transitions
        )
        monitor.resolveTerminal(
            .completed(at: now.addingTimeInterval(-10), duration: 10),
            task: task,
            key: key,
            abortFallback: now,
            into: &transitions
        )
        #expect(monitor.completions.count == 1)
        #expect(monitor.completions.first?.duration == nil)
        #expect(transitions.isEmpty)
    }
}
