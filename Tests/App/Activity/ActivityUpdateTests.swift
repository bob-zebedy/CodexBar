import Combine
import Foundation
import Synchronization
import Testing

struct ActivityUpdateTests {
    @Test(arguments: ["resolved", "pending", "replaced", "unknown", "ended"], [false, true])
    func approvalPublicationUsesFinalState(scenario: String, deferred: Bool) throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reducer = try approvalReducer(at: now)
        var graph = ActivityTaskGraph()
        _ = graph.update(
            events: [TestFixtures.event(at: now.addingTimeInterval(-60))],
            source: .bootstrap,
            lifecycle: lifecycle(reducer, at: now, verifiesChild: !deferred)
        )
        let request = try approvalRequest(id: "first", at: now.addingTimeInterval(-2))
        let events = reducer.consume(request, now: now.addingTimeInterval(-2))
        if deferred {
            let transitions = graph.update(events: events, source: .live, lifecycle: lifecycle(reducer, at: now, verifiesChild: false))
            #expect(transitions.isEmpty)
            #expect(graph.pendingSubagentEvents.count == 1)
        }
        let child = ActivityTurnReference(threadID: "child", turnID: "child-turn")
        if scenario == "resolved" || scenario == "replaced" {
            let resolved = try TestFixtures.decode(ActivityInput.self, #"{"method":"serverRequest/resolved","params":{"threadId":"child","requestId":"first"}}"#)
            #expect(reducer.consume(resolved, now: now.addingTimeInterval(-1)).isEmpty)
        }
        if scenario == "replaced" {
            _ = try reducer.consume(approvalRequest(id: "second", at: now.addingTimeInterval(-1)), now: now.addingTimeInterval(-1))
        } else if scenario == "unknown" {
            reducer.states[child]?.isWaitingApproval = nil
            reducer.states[child]?.approvalChangedAt = nil
            reducer.states[child]?.pendingApprovals.removeAll()
        } else if scenario == "ended" {
            let ended = try TestFixtures.decode(ActivityInput.self, """
            {"method":"turn/completed","params":{"threadId":"child","turn":{"id":"child-turn","rootTurnId":"turn-a","status":"completed","completedAt":\(now.timeIntervalSince1970)}}}
            """)
            _ = reducer.consume(ended, now: now)
        }
        let snapshot = lifecycle(reducer, at: now)
        let transitions = graph.update(events: deferred ? [] : events, source: deferred ? .bootstrap : .live, lifecycle: snapshot)
        let task = try #require(graph.tasks[.init(thread: "thread-a", turn: "turn-a")])
        let expectsWaiting = ["pending", "replaced", "unknown"].contains(scenario)
        #expect(graph.pendingSubagentEvents.isEmpty)
        #expect((task.state == .waitingApproval) == expectsWaiting)
        #expect(transitions.count == (expectsWaiting ? 1 : 0))
        if expectsWaiting {
            guard case let .waitingApproval(published) = try #require(transitions.first) else {
                Issue.record("Expected waiting transition")
                return
            }
            #expect(published == task.snapshot)
            #expect(published.stateChangedAt == now.addingTimeInterval(scenario == "replaced" ? -1 : -2))
        }
        let repeated = graph.update(events: [], source: .bootstrap, lifecycle: snapshot)
        #expect(repeated.isEmpty)
        #expect(graph.tasks[task.key]?.snapshot == task.snapshot)
        #expect(graph.tasks[task.key]?.progressGeneration == task.progressGeneration)
    }

    @Test(arguments: ["complete", "unknown", "unavailable"])
    func otherExecutionProgressCannotClearWaitingApproval(coverage: String) throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reducer = try approvalReducer(at: now)
        var graph = ActivityTaskGraph()
        _ = graph.update(events: [TestFixtures.event(at: now.addingTimeInterval(-60))], source: .bootstrap, lifecycle: lifecycle(reducer, at: now))
        let events = try reducer.consume(approvalRequest(id: "first", at: now.addingTimeInterval(-2)), now: now.addingTimeInterval(-2))
        let transitions = graph.update(events: events, source: .live, lifecycle: lifecycle(reducer, at: now))
        #expect(transitions.count == 1)
        let key = ActivityTaskKey(thread: "thread-a", turn: "turn-a")
        let before = try #require(graph.tasks[key]?.snapshot)
        let child = ActivityTurnReference(threadID: "child", turnID: "child-turn")
        if coverage == "unknown" {
            reducer.states[child]?.isWaitingApproval = nil
            reducer.states[child]?.approvalChangedAt = nil
            reducer.states[child]?.pendingApprovals.removeAll()
        }
        let progress = [
            TestFixtures.event(.toolCompleted, at: now),
            TestFixtures.event(.toolCompleted, at: now, turn: "child-turn", agentThreadID: "child", origin: .auxiliary)
        ]
        let updated = graph.update(events: progress, source: .live, lifecycle: lifecycle(reducer, at: now, verifiesChild: coverage != "unavailable"))
        #expect(updated.isEmpty)
        #expect(graph.tasks[key]?.state == .waitingApproval)
        #expect(graph.tasks[key]?.snapshot.stateChangedAt == before.stateChangedAt)
        #expect(graph.tasks[key]?.snapshot.approvalActionText == before.approvalActionText)
    }

    @Test func resolvingOneChildKeepsAnotherChildWaiting() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reducer = try approvalReducer(at: now)
        let sibling = try TestFixtures.decode(ActivityThread.self, """
        {"id":"sibling","source":{"subAgent":{"thread_spawn":{"parent_thread_id":"thread-a"}}},"status":{"type":"active"}}
        """)
        var turn = ActivityTurn(id: "sibling-turn", status: .running, startedAt: now.addingTimeInterval(-10))
        turn.rootTurnId = "turn-a"
        _ = reducer.reconcile(thread: sibling, turns: [turn], now: now)
        var graph = ActivityTaskGraph()
        _ = graph.update(events: [TestFixtures.event(at: now.addingTimeInterval(-60))], source: .bootstrap, lifecycle: lifecycle(reducer, at: now))
        let first = try reducer.consume(approvalRequest(id: "first", at: now.addingTimeInterval(-2)), now: now.addingTimeInterval(-2))
        let second = try reducer.consume(approvalRequest(id: "second", at: now.addingTimeInterval(-1), thread: "sibling", turn: "sibling-turn"), now: now.addingTimeInterval(-1))
        #expect(graph.update(events: first + second, source: .live, lifecycle: lifecycle(reducer, at: now)).count == 1)
        let resolved = try TestFixtures.decode(ActivityInput.self, #"{"method":"serverRequest/resolved","params":{"threadId":"child","requestId":"first"}}"#)
        _ = reducer.consume(resolved, now: now)
        #expect(graph.update(events: [], source: .bootstrap, lifecycle: lifecycle(reducer, at: now)).isEmpty)
        let task = try #require(graph.tasks[.init(thread: "thread-a", turn: "turn-a")])
        #expect(task.state == .waitingApproval)
        #expect(task.displayedApproval?.requestedAt == now.addingTimeInterval(-1))
        #expect(task.executions[.init(agentThreadID: "child", turnID: "child-turn")]?.approval == nil)
        #expect(task.executions[.init(agentThreadID: "sibling", turnID: "sibling-turn")]?.approval != nil)
    }

    @Test func historicalApprovalReplayDoesNotNotify() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reducer = try approvalReducer(at: now)
        var graph = ActivityTaskGraph()
        _ = graph.update(events: [TestFixtures.event(at: now.addingTimeInterval(-60))], source: .bootstrap, lifecycle: lifecycle(reducer, at: now, verifiesChild: false))
        let events = try reducer.consume(approvalRequest(id: "first", at: now.addingTimeInterval(-2)), now: now.addingTimeInterval(-2))
        #expect(graph.update(events: events, source: .bootstrap, lifecycle: lifecycle(reducer, at: now, verifiesChild: false)).isEmpty)
        #expect(graph.update(events: [], source: .bootstrap, lifecycle: lifecycle(reducer, at: now)).isEmpty)
        #expect(graph.tasks.values.first?.state == .waitingApproval)
    }

    @Test func monitorRejectsOlderRevisionsAndDifferentReaders() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDataDirectoryURL: directory.url
        )
        monitor.isActivitySourceHealthy = true
        let readerID = UUID()
        let now = Date()
        var first = ActivityTaskGraph()
        _ = first.consume([TestFixtures.event(at: now)], source: .live)
        var second = first
        _ = second.consume([TestFixtures.event(at: now.addingTimeInterval(1), turn: "next")], source: .live)
        monitor.consume(update(second, readerID: readerID, revision: 2))
        let expected = monitor.snapshot
        monitor.consume(update(first, readerID: readerID, revision: 1))
        monitor.consume(update(first, readerID: UUID(), revision: 3))
        monitor.consume(update(first, readerID: readerID, revision: 2))
        #expect(monitor.snapshot == expected)
        #expect(monitor.tasks.keys.map(\.turnID) == ["next"])
    }

    @Test func repeatedPublicationCannotRenewLifecycleVerification() throws {
        let now = Date()
        let reference = ActivityTurnReference(threadID: "thread-a", turnID: "turn-a")
        let state = TurnLifecycleState(
            requestedThreadID: reference.threadID,
            turnID: reference.turnID,
            startedAt: now,
            effort: nil,
            lastProgressAt: now,
            terminal: nil
        )
        let snapshot = TurnLifecycleSnapshot(states: [reference: state], verifiedTurns: [reference: now])
        var graph = ActivityTaskGraph()
        _ = graph.consume([TestFixtures.event(at: now)], source: .bootstrap)
        for _ in 0 ..< 3 {
            _ = graph.reconcile(snapshot.lifecycleStates(for: [reference], now: now.addingTimeInterval(4)))
        }
        let task = try #require(graph.tasks.values.first)
        #expect(task.lifecycleCoverageCheckedAt == now)
        #expect(!task.hasFreshLifecycle(at: now.addingTimeInterval(6)))
    }

    @Test func recoveryAppliesExplicitTerminalSilentlyAndKeepsProtectionPaused() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDataDirectoryURL: directory.url
        )
        monitor.isActivitySourceHealthy = true
        let readerID = UUID()
        let now = Date()
        var graph = ActivityTaskGraph()
        _ = graph.consume([TestFixtures.event(at: now)], source: .live)
        monitor.consume(update(graph, readerID: readerID, revision: 1))
        monitor.beginProtectionRecovery()
        var transitions = 0
        var terminalEvents = 0
        let notification = monitor.transitionPublisher.sink { _ in transitions += 1 }
        let presentation = monitor.presentationPublisher.sink { terminalEvents += $0.terminalEvents.count }
        defer { notification.cancel()
            presentation.cancel()
        }
        let changes = graph.consume([TestFixtures.event(.turnCompleted, at: now)], source: .live)
        var partial = update(graph, readerID: readerID, revision: 2, transitions: changes)
        partial.isComplete = false
        monitor.consume(partial)
        #expect(monitor.snapshot.activeCount == 0)
        #expect(monitor.snapshot.recentCompletions.count == 1)
        #expect(monitor.isProtectionRecoveryInProgress)
        #expect(transitions == 0 && terminalEvents == 0)
    }

    @Test func eachDrainWaitsForAReadStartedAfterItsOwnRequest() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = Mutex(false)
        let now = Date()
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            var round = 0
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/loaded/list":
                    round += 1
                    if round == 2 {
                        entered.withLock { $0 = true }
                        _ = release.wait(timeout: .now() + 5)
                    }
                    try peer.reply(to: request, result: ["data": ["thread-a"]])
                case "thread/read", "thread/resume":
                    try peer.reply(to: request, result: ["thread": ["id": "thread-a", "source": "cli", "status": ["type": "active"]]])
                case "thread/turns/list":
                    let turns = (1 ... round).map { index -> [String: Any] in
                        ["id": "turn-\(index)", "rootTurnId": "turn-\(index)", "status": index == round ? "inProgress" : "completed", "startedAt": now.timeIntervalSince1970]
                    }
                    try peer.reply(to: request, result: ["data": turns])
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        var ready = false
        var published: [ActivityUpdate] = []
        let reader = AppServerActivityReader(
            socketURL: server.url,
            logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { update in
            published.append(update)
            if case .bootstrapEnd = update.phase {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        let first = Task { await reader.drainNow() }
        for _ in 0 ..< 200 where !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(entered.withLock { $0 })
        let second = Task { await reader.drainNow() }
        try await Task.sleep(for: .milliseconds(20))
        release.signal()
        let firstResult = await first.value
        let secondResult = await second.value
        #expect(firstResult.status == .completed)
        #expect(secondResult.status == .completed)
        if case let .completed(a) = firstResult, case let .completed(b) = secondResult {
            #expect(a.readerID == b.readerID && a.revision < b.revision)
            #expect(a.graph.tasks.keys.map(\.turnID) == ["turn-2"])
            #expect(b.graph.tasks.keys.map(\.turnID) == ["turn-3"])
            #expect(published.contains { $0.readerID == b.readerID && $0.revision == b.revision })
        }
        #expect(await reader.stop())
        #expect(await reader.drainNow().status == .cancelled)
        try server.finish()
    }

    private func approvalReducer(at now: Date) throws -> AppServerActivityReducer {
        var reducer = AppServerActivityReducer()
        let root = try TestFixtures.decode(ActivityThread.self, #"{"id":"thread-a","source":"cli","status":{"type":"active"}}"#)
        let child = try TestFixtures.decode(ActivityThread.self, """
        {"id":"child","source":{"subAgent":{"thread_spawn":{"parent_thread_id":"thread-a"}}},"status":{"type":"active"}}
        """)
        for (thread, id, offset) in [(root, "turn-a", -60.0), (child, "child-turn", -10.0)] {
            var turn = ActivityTurn(id: id, status: .running, startedAt: now.addingTimeInterval(offset))
            turn.rootTurnId = "turn-a"
            _ = reducer.reconcile(thread: thread, turns: [turn], now: now)
        }
        return reducer
    }

    private func approvalRequest(id: String, at date: Date, thread: String = "child", turn: String = "child-turn") throws -> ActivityInput {
        try TestFixtures.decode(ActivityInput.self, """
        {"id":"\(id)","method":"item/commandExecution/requestApproval","params":{"threadId":"\(thread)","turnId":"\(turn)","itemId":"\(id)","startedAtMs":\(date.timeIntervalSince1970 * 1000)}}
        """)
    }

    private func lifecycle(_ reducer: AppServerActivityReducer, at now: Date, verifiesChild: Bool = true) -> TurnLifecycleSnapshot {
        let verified = reducer.states.keys.filter { verifiesChild || $0.threadID == "thread-a" }.map { ($0, now) }
        return TurnLifecycleSnapshot(states: reducer.states, verifiedTurns: Dictionary(uniqueKeysWithValues: verified))
    }

    private func update(_ graph: ActivityTaskGraph, readerID: UUID, revision: UInt64, transitions: [ActivityTransition] = []) -> ActivityUpdate {
        ActivityUpdate(
            readerID: readerID,
            revision: revision,
            phase: .lifecycleChanged,
            graph: graph,
            transitions: transitions,
            terminalEvents: graph.terminalEvents,
            backfilledTasks: graph.backfilledTasks
        )
    }
}
