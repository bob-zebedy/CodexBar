import Combine
import Foundation
import Testing

struct ActivityTokenUsageTests {
    @Test func cacheHitRateUsesAllInputAndIsUnavailableWithoutInput() {
        let tokenUsage = TokenUsage(
            inputTokens: 1000, cachedInputTokens: 800, cacheWriteInputTokens: 100,
            outputTokens: 200, reasoningOutputTokens: 50, totalTokens: 1200
        )
        #expect(tokenUsage.cacheHitRate == 0.8)
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
        let tokenUsage = try #require(request.tokenUsage(from: states))
        #expect(tokenUsage.inputTokens == 1000)
        #expect(tokenUsage.outputTokens == 40)
        #expect(tokenUsage.totalTokens == 1040)
        #expect(tokenUsage.cachedInputTokens == 80)
    }

    @Test(arguments: ["missing", "unavailable", "other-root", "other-root-thread", "running-child", "missing-tokenUsage"])
    func incompleteOrUnrelatedChildPreventsPartialTotal(scenario: String) {
        let root = reference("thread-a", "turn-a")
        let child = reference("child-a", "child-turn")
        let request = request(root: root, children: [child])
        var childState = state(child)
        switch scenario {
        case "unavailable": childState.readStatus = .unavailable
        case "other-root": childState.rootTurnID = "other-root"
        case "other-root-thread": childState.rootThreadID = "other-root-thread"
        case "missing-tokenUsage": childState.tokenUsage = nil
        case "running-child": childState = state(child, terminal: nil)
        default: break
        }
        let states = scenario == "missing" ? [state(root)] : [state(root), childState]
        #expect(request.tokenUsage(from: states) == nil)
    }

    @Test func knownAgentWithoutResolvedTurnPreventsPartialTotal() {
        let root = reference("thread-a", "turn-a")
        let request = TaskTokenUsageRequest(
            root: root, expectedAgentThreadIDs: ["unknown-child"], references: [root]
        )
        #expect(request.tokenUsage(from: [state(root)]) == nil)
    }

    @Test func inProgressUsageIncludesAvailableRunningAndCompletedChildren() throws {
        let root = reference("thread-a", "turn-a")
        let running = reference("child-a", "child-turn-a")
        let completed = reference("child-a", "child-turn-b")
        let unknown = reference("child-b", "child-turn-c")
        let request = request(root: root, children: [running, completed, unknown, running])
        let states = [state(root, terminal: nil), state(running, input: 200, terminal: nil), state(completed, input: 300)]
        let tokenUsage = try #require(request.tokenUsage(from: states, requiresFinalTokenUsage: false))
        #expect(tokenUsage.totalTokens == 630)
        #expect(tokenUsage.cachedInputTokens == 60)
        #expect(request.tokenUsage(from: states) == nil)
        #expect(request.tokenUsage(from: [], requiresFinalTokenUsage: false) == nil)
    }

    @Test(arguments: ["other-root", "other-root-thread", "other-thread", "unavailable", "missing-tokenUsage"])
    func inProgressUsageDoesNotIncludeUnverifiedChildren(scenario: String) {
        let root = reference("thread-a", "turn-a")
        let child = reference("child-a", "child-turn")
        let request = request(root: root, children: [child])
        var childState = state(child, terminal: nil)
        switch scenario {
        case "other-root": childState.rootTurnID = "other-root"
        case "other-root-thread": childState.rootThreadID = "other-root-thread"
        case "other-thread": childState = state(reference("other-thread", child.turnID), terminal: nil)
        case "unavailable": childState.readStatus = .unavailable
        default: childState.tokenUsage = nil
        }
        let states = [state(root, terminal: nil), childState]
        #expect(request.tokenUsage(from: states, requiresFinalTokenUsage: false)?.totalTokens == 110)
    }

    @Test func activeSnapshotsUpdateBeforeCompletionAndKeepCompletedChildReferences() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        let event = TestFixtures.event()
        let key = try #require(ActivityTaskKey(event: event))
        monitor.graph.tasks[key] = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        let root = reference("thread-a", "turn-a")
        let child = reference("child-a", "child-turn")
        monitor.graph.subagentTurnLinks[child] = (key, TestFixtures.now)
        #expect(Set(monitor.graph.activeTokenUsageReferences()) == [root, child])
        #expect(monitor.graph.tasks[key]?.snapshot.tokenUsage == nil)
        let initial = [state(root, terminal: nil)]
        monitor.graph.applyActiveTokenUsage(initial)
        let running = try #require(monitor.graph.tasks[key]?.snapshot)
        #expect(running.tokenUsage?.totalTokens == 110)
        monitor.graph.applyActiveTokenUsage(initial)
        #expect(monitor.graph.tasks[key]?.snapshot == running)

        monitor.graph.tasks[key]?.state = .waitingApproval
        let updated = [state(root, input: 200, terminal: nil), state(child, input: 300)]
        monitor.graph.applyActiveTokenUsage(updated)
        let waiting = try #require(monitor.graph.tasks[key]?.snapshot)
        #expect(waiting.tokenUsage?.totalTokens == 520)
        #expect(monitor.graph.tasks[key]?.state == .waitingApproval)
        var presentations: [ActivityPresentationUpdate] = []
        let presentation = monitor.presentationPublisher.sink { presentations.append($0) }
        defer { presentation.cancel()
            monitor.stop()
        }
        monitor.refreshSnapshot(now: TestFixtures.now)
        #expect(presentations.count == 1)
        let hasNoTerminalEvents = presentations.allSatisfy(\.terminalEvents.isEmpty)
        #expect(hasNoTerminalEvents)
        #expect(monitor.graph.completions.isEmpty)

        let task = try #require(monitor.graph.tasks[key])
        var transitions: [ActivityTransition] = []
        monitor.graph.resolveTerminal(
            .completed(at: TestFixtures.now, duration: 1), task: task, key: key,
            abortFallback: TestFixtures.now, into: &transitions
        )
        monitor.graph.applyTerminalTokenUsage(updated)
        #expect(monitor.graph.completions.first?.tokenUsage?.totalTokens == 520)
    }

    @Test func activeUsageDoesNotCarryAcrossTurnsOrKeepUnavailableData() throws {
        var graph = ActivityTaskGraph()
        let event = TestFixtures.event(turn: "turn-b")
        let key = try #require(ActivityTaskKey(event: event))
        graph.tasks[key] = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        graph.applyActiveTokenUsage([state(reference("thread-a", "turn-a"))])
        #expect(graph.tasks[key]?.tokenUsage == nil)
        var current = state(reference("thread-a", "turn-b"), terminal: nil)
        current.rootTurnID = "turn-b"
        graph.applyActiveTokenUsage([current])
        #expect(graph.tasks[key]?.tokenUsage?.totalTokens == 110)
        current.readStatus = .unavailable
        graph.applyActiveTokenUsage([current])
        #expect(graph.tasks[key]?.tokenUsage == nil)
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
        monitor.graph.resolveTerminal(
            .completed(at: TestFixtures.now, duration: 1), task: task, key: key,
            abortFallback: TestFixtures.now, into: &transitions
        )
        let completedID = try #require(monitor.graph.completions.first?.id)
        let otherEvent = TestFixtures.event(.turnAborted, turn: "turn-b")
        let otherKey = try #require(ActivityTaskKey(event: otherEvent))
        monitor.graph.tasks[otherKey] = ActivityTask(
            displayID: UUID(), key: otherKey, event: otherEvent, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        monitor.graph.finishTask(from: otherEvent, source: .bootstrap, into: &transitions)
        #expect(monitor.graph.completions.first?.tokenUsage == nil)
        #expect(monitor.graph.terminations.first?.tokenUsage == nil)

        var stopped = state(reference("thread-a", "turn-b"), input: 200, terminal: nil)
        stopped.rootTurnID = "turn-b"
        let states = [state(reference("thread-a", "turn-a")), stopped]
        var presentations: [ActivityPresentationUpdate] = []
        let presentation = monitor.presentationPublisher.sink { presentations.append($0) }
        defer { presentation.cancel()
            monitor.stop()
        }
        monitor.graph.applyTerminalTokenUsage(states)
        #expect(monitor.graph.completions.first?.tokenUsage?.totalTokens == 110)
        #expect(monitor.graph.terminations.first?.tokenUsage?.totalTokens == 210)
        #expect(monitor.graph.completions.first?.id == completedID)
        monitor.refreshSnapshot(now: TestFixtures.now)
        #expect(presentations.count == 1)
        let hasNoTerminalEvents = presentations.allSatisfy(\.terminalEvents.isEmpty)
        #expect(hasNoTerminalEvents)
        let completed = monitor.graph.completions
        let terminated = monitor.graph.terminations
        monitor.graph.applyTerminalTokenUsage(states)
        monitor.refreshSnapshot(now: TestFixtures.now)
        #expect(presentations.count == 1)
        #expect(monitor.graph.completions == completed)
        #expect(monitor.graph.terminations == terminated)
        stopped.readStatus = .unavailable
        monitor.graph.applyTerminalTokenUsage([stopped])
        #expect(monitor.graph.terminations.first?.tokenUsage?.totalTokens == 210)
        let terminalReferences = monitor.graph.terminalTokenUsageReferences()
        #expect(terminalReferences.count == 2)
        let laterReferences = monitor.graph.terminalTokenUsageReferences()
        #expect(Set(laterReferences) == Set(terminalReferences))
        #expect(monitor.graph.terminalTokenUsageRequests.count == 2)
        #expect(monitor.graph.completions.first?.tokenUsage?.totalTokens == 110)
        monitor.clearCollectedActivityState()
        #expect(monitor.graph.completions.isEmpty)
    }

    @Test func laterTurnPendingAgentMustNotEraseCompletedTurnUsage() throws {
        var graph = ActivityTaskGraph()
        let first = TestFixtures.event()
        let firstKey = try #require(ActivityTaskKey(event: first))
        let task = ActivityTask(
            displayID: UUID(), key: firstKey, event: first, state: .running,
            startedAt: TestFixtures.now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        graph.resolveTerminal(.completed(at: TestFixtures.now, duration: 1), task: task, key: firstKey, abortFallback: TestFixtures.now, into: &transitions)
        let firstState = state(reference("thread-a", "turn-a"))
        graph.applyTerminalTokenUsage([firstState])
        #expect(graph.completions.first?.tokenUsage?.totalTokens == 110)
        let second = TestFixtures.event(at: TestFixtures.now.addingTimeInterval(2), turn: "turn-b")
        let secondKey = try #require(ActivityTaskKey(event: second))
        graph.tasks[secondKey] = ActivityTask(
            displayID: UUID(), key: secondKey, event: second, state: .running,
            startedAt: second.timestamp, progressGeneration: 2
        )
        let child = TestFixtures.event(.subagentStarted, at: TestFixtures.now.addingTimeInterval(3), turn: "child-turn-b", agentThreadID: "child-b")
        let observedResult11 = graph.deferUnassociatedSubagentEvent(child, source: .live)
        #expect(observedResult11)
        graph.applyTerminalTokenUsage([firstState])
        #expect(graph.completions.first?.tokenUsage?.totalTokens == 110)
        let lateChild = reference("child-a", "child-turn-a")
        graph.subagentTurnLinks[lateChild] = (firstKey, TestFixtures.now)
        graph.applyTerminalTokenUsage([firstState])
        #expect(graph.completions.first?.tokenUsage?.totalTokens == 110)
        graph.applyTerminalTokenUsage([firstState, state(lateChild, input: 200)])
        #expect(graph.completions.first?.tokenUsage?.totalTokens == 320)
        var unavailable = firstState
        unavailable.readStatus = .unavailable
        graph.applyTerminalTokenUsage([unavailable])
        _ = graph.terminalTokenUsageReferences()
        #expect(graph.completions.first?.tokenUsage?.totalTokens == 320)
    }

    @Test(arguments: [false, true])
    func historicalTerminalUpdatesHistoryWithoutPublishingEvents(aborted: Bool) throws {
        var graph = ActivityTaskGraph()
        let now = Date()
        for publishesEvents in [false, true] {
            let event = TestFixtures.event(at: now, turn: publishesEvents ? "live-turn" : "historical-turn")
            let key = try #require(ActivityTaskKey(event: event))
            let task = ActivityTask(
                displayID: UUID(), key: key, event: event, state: .running,
                startedAt: now, progressGeneration: 1
            )
            var transitions: [ActivityTransition] = []
            graph.resolveTerminal(
                aborted ? .aborted(at: now, duration: nil) : .completed(at: now, duration: 1),
                task: task, key: key, abortFallback: now, publishesEvents: publishesEvents, into: &transitions
            )
            #expect(transitions.isEmpty == (aborted || !publishesEvents))
            #expect(graph.terminalEvents.isEmpty == !publishesEvents)
            let observedResult15 = graph.recentEndedDate(for: key, now: now) != nil
            #expect(observedResult15)
            let presentationCount = graph.terminalEvents.count
            graph.resolveTerminal(
                aborted ? .aborted(at: now, duration: nil) : .completed(at: now, duration: 1),
                task: task, key: key, abortFallback: now, publishesEvents: true, into: &transitions
            )
            #expect(graph.terminalEvents.count == presentationCount)
        }
        #expect(aborted ? graph.terminations.count == 2 : graph.completions.count == 2)
        #expect(graph.terminalTokenUsageRequests.count == 2)
    }

    @Test(arguments: [false, true])
    func liveTerminalPresentationPreservesInterruptBehavior(interrupted: Bool) throws {
        var graph = ActivityTaskGraph()
        let now = Date()
        let event = TestFixtures.event(.turnAborted, at: now)
        let key = try #require(ActivityTaskKey(event: event))
        let task = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        if interrupted {
            graph.tasks[key] = task
            graph.finishTask(from: event, source: .live, into: &transitions)
            graph.finishTask(from: event, source: .live, into: &transitions)
            #expect(graph.tasks.isEmpty)
            #expect(graph.terminations.count == 1)
        } else {
            graph.resolveTerminal(
                .completed(at: now, duration: 1), task: task, key: key,
                abortFallback: now, into: &transitions
            )
            #expect(graph.completions.count == 1)
        }
        #expect(transitions.count == (interrupted ? 0 : 1))
        #expect(graph.terminalEvents.count == 1)
        #expect(graph.terminalTokenUsageRequests.count == 1)
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
        monitor.graph.tasks[key] = ActivityTask(
            displayID: UUID(), key: key, event: event, state: state,
            startedAt: old, progressGeneration: 1
        )
        monitor.refreshSnapshot(now: now)
        #expect(monitor.graph.tasks.count == 1)
        #expect(monitor.snapshot.activeCount == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func terminalUsageContinuesUntilCardIsRemoved(clearExplicitly: Bool, aborted: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeMonitor(directory: directory, preferences: preferences)
        defer {
            monitor.clearCollectedActivityState()
            monitor.refreshSnapshot(now: Date())
        }
        let now = Date()
        let event = TestFixtures.event(at: now)
        let key = try #require(ActivityTaskKey(event: event))
        let task = ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: now, progressGeneration: 1
        )
        var transitions: [ActivityTransition] = []
        let terminal: TurnTerminalState = aborted ? .aborted(at: now, duration: 1) : .completed(at: now, duration: 1)
        monitor.graph.resolveTerminal(terminal, task: task, key: key, abortFallback: now, into: &transitions)
        let root = reference("thread-a", "turn-a")
        #expect(monitor.graph.terminalTokenUsageReferences().contains(root))
        monitor.graph.applyTerminalTokenUsage([state(root, input: 500)])
        monitor.refreshSnapshot(now: now.addingTimeInterval(599))
        #expect(monitor.snapshot.recentCompletions.count == (aborted ? 0 : 1))
        #expect(monitor.snapshot.recentTerminations.count == (aborted ? 1 : 0))
        let tokenUsage = aborted
            ? monitor.snapshot.recentTerminations.first?.tokenUsage
            : monitor.snapshot.recentCompletions.first?.tokenUsage
        #expect(tokenUsage?.totalTokens == 510)
        #expect(monitor.graph.terminalTokenUsageReferences().contains(root))
        if clearExplicitly {
            monitor.clearCollectedActivityState()
            monitor.refreshSnapshot(now: now.addingTimeInterval(599))
        } else {
            monitor.refreshSnapshot(now: now.addingTimeInterval(600))
        }
        #expect(monitor.snapshot.recentCompletions.isEmpty)
        #expect(monitor.snapshot.recentTerminations.isEmpty)
        #expect(monitor.graph.completions.isEmpty)
        #expect(monitor.graph.terminations.isEmpty)
        #expect(monitor.graph.terminalTokenUsageRequests.isEmpty)
        #expect(monitor.graph.terminalTokenUsageReferences().isEmpty)
    }

    private func reference(_ thread: String, _ turn: String) -> ActivityTurnReference {
        ActivityTurnReference(threadID: thread, turnID: turn)
    }

    private func request(root: ActivityTurnReference, children: [ActivityTurnReference]) -> TaskTokenUsageRequest {
        TaskTokenUsageRequest(
            root: root, expectedAgentThreadIDs: Set(children.map(\.threadID)), references: Set([root] + children)
        )
    }

    private func state(
        _ reference: ActivityTurnReference, input: Int64 = 100,
        terminal: TurnTerminalState? = .completed(at: TestFixtures.now, duration: 1)
    ) -> TurnLifecycleState {
        TurnLifecycleState(
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
}

extension ActivityTokenUsageTests {
    @Test func unknownCompletionTimeDoesNotInventDurationOrRepeatCompletion() throws {
        var graph = ActivityTaskGraph()
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
        graph.resolveTerminal(
            .completed(at: nil, duration: nil),
            task: task,
            key: key,
            abortFallback: now,
            publishesEvents: false,
            into: &transitions
        )
        graph.resolveTerminal(
            .completed(at: now.addingTimeInterval(-10), duration: 10),
            task: task,
            key: key,
            abortFallback: now,
            into: &transitions
        )
        #expect(graph.completions.count == 1)
        #expect(graph.completions.first?.duration == nil)
        #expect(transitions.isEmpty)
    }
}
