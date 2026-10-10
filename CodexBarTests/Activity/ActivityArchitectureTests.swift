import Foundation
import Testing

struct ActivityArchitectureTests {
    @Test(arguments: [false, true])
    func currentTurnSurvivesPreviousTurnsMillisecondProgress(snapshot: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 5)
        monitor.consume(.live([TestFixtures.event(at: now.addingTimeInterval(-10))]))
        monitor.consume(.live([TestFixtures.event(.toolCompleted, at: now.addingTimeInterval(0.1))]))
        let event = TestFixtures.event(at: now, turn: "turn-b")
        monitor.consume(snapshot ? .snapshotEvents([event]) : .live([event]))
        let old = ActivityTaskKey(thread: "thread-a", turn: "turn-a")
        let current = ActivityTaskKey(thread: "thread-a", turn: "turn-b")
        let id = try #require(monitor.tasks[current]?.displayID)
        #expect(monitor.tasks[old] == nil)
        #expect(monitor.pendingTerminalTasks[old] != nil)
        monitor.consume(.snapshotEvents([event, TestFixtures.event(at: now)]))
        #expect(monitor.tasks[current]?.displayID == id)
        #expect(monitor.tasks.count == 1)
        monitor.consume(.live([TestFixtures.event(.turnCompleted, at: now.addingTimeInterval(1))]))
        #expect(monitor.pendingTerminalTasks.isEmpty)
        #expect(monitor.completions.count == 1)
        #expect(monitor.terminations.isEmpty)
        monitor.consume(.live([TestFixtures.event(.turnCompleted, at: now.addingTimeInterval(2), turn: "turn-b")]))
        monitor.consume(.snapshotEvents([event]))
        #expect(monitor.tasks.isEmpty)
    }

    @Test func creationNoticeUpdatesRootWithoutInventingExecution() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        monitor.consume(.snapshotEvents([TestFixtures.event(at: now)]))
        var event = ActivityRecord(
            timestamp: now.addingTimeInterval(1), name: ActivityEventKind.subagentStarted.rawValue, origin: .main,
            cwd: "/child-project", toolName: nil, model: "child-model", effort: "low",
            threadID: "thread-a", turnID: nil, agentID: "child"
        )
        event.context = ActivityContext(
            method: "item/completed", threadID: "thread-a", turnID: "turn-a",
            rootThreadID: "thread-a", rootTurnID: "turn-a", agentThreadID: "child", itemKind: "started"
        )
        monitor.consume(.live([event]))
        let task = try #require(monitor.tasks[.init(thread: "thread-a", turn: "turn-a")])
        #expect(task.modelName == "gpt-5")
        #expect(task.projectName == "example")
        #expect(task.effort == "mixed")
        #expect(task.executions.keys.allSatisfy { $0.agentID == nil })
        #expect(task.subagentsByID["child"]?.isRunning == true)
    }

    @Test func authoritativeChildrenRecoverCountWithoutObservedStarts() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        monitor.consume(.snapshotEvents([TestFixtures.event(at: now)]))
        let key = ActivityTaskKey(thread: "thread-a", turn: "turn-a")
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == nil)
        let root = state("thread-a", at: now)
        apply([root], to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == 0)
        monitor.tasks[key]?.recordSubagentActivity(agentID: "finished", isStarting: false, at: now)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == nil)
        let finished = state("finished", at: now, parent: "thread-a", terminal: .completed(at: now, duration: 1))
        let active = state("active", at: now, parent: "thread-a")
        apply([root, finished, active], to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == 1)
        var unavailable = active
        unavailable.readStatus = .unavailable
        apply([root, finished, unavailable], to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == nil)
        apply([root, finished, active], to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == 1)
        apply([root, finished], to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == nil)
        let ended = state("active", at: now.addingTimeInterval(1), parent: "thread-a", terminal: .completed(at: now.addingTimeInterval(1), duration: 1))
        apply([root, finished, ended], to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == 0)
    }

    @Test func unresolvedAncestryKeepsCountUnknownUntilOwnershipRecovers() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        monitor.consume(.snapshotEvents([TestFixtures.event(at: now)]))
        let root = ActivityTurnReference(threadID: "thread-a", turnID: "turn-a")
        let child = ActivityTurnReference(threadID: "child", turnID: "turn-a")
        let grandchild = ActivityTurnReference(threadID: "grandchild", turnID: "turn-a")
        let cache = SessionLifecycleCache()
        var states = [root: state("thread-a", at: now), child: state("child", at: now, parent: "thread-a"), grandchild: state("grandchild", at: now, parent: "child")]
        for reference in [child, grandchild] {
            states[reference]?.rootThreadID = nil
            states[reference]?.rootTurnID = nil
        }
        let verified = Dictionary(uniqueKeysWithValues: states.keys.map { ($0, now) })
        await cache.replace(states, verifiedTurns: verified)
        let incomplete = await cache.lifecycleStates(for: [root], now: now)
        #expect(incomplete.count == 3)
        apply(incomplete, to: monitor)
        let key = ActivityTaskKey(thread: "thread-a", turn: "turn-a")
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == nil)
        for reference in [child, grandchild] {
            states[reference]?.rootThreadID = "thread-a"
            states[reference]?.rootTurnID = "turn-a"
        }
        await cache.replace(states, verifiedTurns: verified)
        await apply(cache.lifecycleStates(for: [root], now: now), to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == 2)
        let unidentified = TestFixtures.event(.toolStarted, at: now, origin: .auxiliary)
        monitor.tasks[key]?.recordExecutionEvent(unidentified)
        await apply(cache.lifecycleStates(for: [root], now: now), to: monitor)
        #expect(monitor.tasks[key]?.snapshot.activeSubagentCount == nil)
    }

    @Test func cacheReconciliationIncludesEveryRetainedTaskWithoutDelay() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date()
        var transitions: [ActivityTransition] = []
        var terminalStates: [ActivityTurnReference: SessionLifecycleState] = [:]
        for index in 0 ..< 20 {
            let event = TestFixtures.event(at: now, thread: "session-\(index)")
            let key = try #require(ActivityTaskKey(event: event))
            let task = ActivityTask(displayID: UUID(), key: key, event: event, state: .running, startedAt: now, progressGeneration: 1)
            monitor.resolveTerminal(.completed(at: now, duration: 1), task: task, key: key, abortFallback: now, into: &transitions)
            let reference = task.turnReference
            var lifecycle = state(reference.threadID, at: now, terminal: .completed(at: now, duration: 1))
            lifecycle.rootThreadID = reference.threadID
            terminalStates[reference] = lifecycle
            let pendingEvent = TestFixtures.event(at: now, thread: "pending-\(index)")
            let pendingKey = try #require(ActivityTaskKey(event: pendingEvent))
            let pending = ActivityTask(displayID: UUID(), key: pendingKey, event: pendingEvent, state: .running, startedAt: now, progressGeneration: 1)
            monitor.pendingTerminalTasks[pendingKey] = PendingTerminalTask(task: pending, supersededAt: now)
        }
        let cache = SessionLifecycleCache()
        await cache.replace(terminalStates, verifiedTurns: [:])
        #expect(monitor.lifecycleReferences().count == 40)
        #expect(await !monitor.applyTerminalTokenUsage(cache.lifecycleStates(for: monitor.lifecycleReferences())))
        for reference in terminalStates.keys {
            terminalStates[reference]?.tokenUsage = TokenUsage(
                inputTokens: 100, cachedInputTokens: 0, cacheWriteInputTokens: 0,
                outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 100
            )
        }
        await cache.replace(terminalStates, verifiedTurns: [:])
        #expect(monitor.lifecycleReferences().count == 40)
        #expect(await monitor.applyTerminalTokenUsage(cache.lifecycleStates(for: monitor.lifecycleReferences())))
        #expect(monitor.completions.count == 20)
        #expect(monitor.completions.allSatisfy { $0.tokenUsage?.totalTokens == 100 })
    }

    @Test(arguments: [false, true], [nil, "read", "search"] as [String?])
    func approvalUsesRequestActionsWithoutInferringFromTool(cachedTool: Bool, action: String?) throws {
        let now = Date()
        var reducer = AppServerActivityReducer()
        let thread = try mainThread()
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn", status: .running)], now: now)
        if cachedTool {
            let started = try TestFixtures.decode(ActivityInput.self, """
            {"method":"item/started","params":{"threadId":"main","turnId":"turn",
            "item":{"id":"item","type":"commandExecution","commandActions":[{"type":"read"}]}}}
            """)
            _ = reducer.consume(started, now: now)
        }
        let actions = action.map { "[{\"type\":\"\($0)\"}]" } ?? "null"
        let request = try TestFixtures.decode(ActivityInput.self, """
        {"id":1,"method":"item/commandExecution/requestApproval","params":{
        "threadId":"main","turnId":"turn","itemId":"item","startedAtMs":1000,"commandActions":\(actions)}}
        """)
        let event = try #require(reducer.consume(request, now: now).first)
        #expect(event.commandActionTypes == action.map { [$0] })
        #expect(event.context?.itemType == "commandExecution")
        #expect(reducer.states.values.first?.pendingApprovals.values.first?.commandActionTypes == action.map { [$0] })
        let stored = try #require(AppServerEventRecord.decode(from: AppServerEventRecord(activity: event).jsonLineData()).activity)
        #expect(stored.commandActionTypes == event.commandActionTypes)
    }

    @Test(arguments: [false, true])
    func unknownStartRemainsUnknownUntilServerBackfill(snapshot: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reducer = AppServerActivityReducer()
        let thread = try mainThread()
        let initial = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn", status: .running)], now: now)
        if snapshot {
            monitor.consume(.snapshotEvents(initial))
        } else {
            let started = try TestFixtures.decode(ActivityInput.self, """
            {"method":"turn/started","params":{"threadId":"main","turn":{"id":"turn","status":"inProgress","startedAt":null}}}
            """)
            monitor.consume(.live(reducer.consume(started, now: now)))
        }
        let key = ActivityTaskKey(thread: "main", turn: "turn")
        var task = try #require(monitor.tasks[key])
        let displayID = task.displayID
        #expect(task.startedAt == nil)
        #expect(task.preciseDuration(until: now) == nil)
        let startedAt = now.addingTimeInterval(-60)
        let corrected = ActivityTurn(id: "turn", status: .running, startedAt: startedAt)
        _ = reducer.reconcile(thread: thread, turns: [corrected], now: now)
        let state = try #require(reducer.states.values.first)
        #expect(ActivityMonitor.mergeLifecycleBackfill(from: state, into: &task))
        #expect(task.startedAt == startedAt)
        #expect(task.preciseDuration(until: now) == 60)
        #expect(task.displayID == displayID)
        monitor.tasks[key] = task
        monitor.consume(.snapshotEvents(reducer.reconcile(
            thread: thread, turns: [ActivityTurn(id: "turn", status: .running)], now: now, bootstrap: true
        )))
        #expect(monitor.tasks[key]?.startedAt == startedAt)
    }

    @Test(arguments: ["completed", "failed", "interrupted"], [
        (snapshot: false, timestamps: false), (snapshot: false, timestamps: true),
        (snapshot: true, timestamps: false), (snapshot: true, timestamps: true)
    ])
    func terminalUsesServerDurationForLiveAndSnapshot(status: String, scenario: (snapshot: Bool, timestamps: Bool)) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = makeMonitor(directory, preferences)
        defer { monitor.stop() }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var reducer = AppServerActivityReducer()
        let thread = try mainThread()
        let key = ActivityTaskKey(thread: "main", turn: "turn")
        let active = ActivityTurn(id: "turn", status: .running)
        monitor.consume(.snapshotEvents(reducer.reconcile(thread: thread, turns: [active], now: now)))
        let terminal = ActivityTurn(
            id: "turn",
            status: ActivityTurnStatus(rawValue: status) ?? .unknown,
            startedAt: scenario.timestamps ? now.addingTimeInterval(-2) : nil,
            completedAt: scenario.timestamps ? now : nil,
            duration: 1.5
        )
        if scenario.snapshot {
            _ = reducer.reconcile(thread: thread, turns: [terminal], now: now)
            // 后续快照缺少时间字段时保留已经确认的终态时间和耗时
            _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn", status: ActivityTurnStatus(rawValue: status) ?? .unknown)], now: now)
            let lifecycle = try #require(reducer.states.values.first)
            var task = try #require(monitor.tasks[key])
            _ = ActivityMonitor.mergeLifecycleBackfill(from: lifecycle, into: &task)
            var transitions: [ActivityTransition] = []
            try monitor.resolveTerminal(#require(lifecycle.terminal), task: task, key: key, abortFallback: now, into: &transitions)
        } else {
            let start = terminal.startedAt.map { String($0.timeIntervalSince1970) } ?? "null"
            let end = terminal.completedAt.map { String($0.timeIntervalSince1970) } ?? "null"
            let completed = try TestFixtures.decode(ActivityInput.self, """
            {"method":"turn/completed","params":{"threadId":"main","turn":{"id":"turn","status":"\(status)",
            "startedAt":\(start),"completedAt":\(end),"durationMs":1500}}}
            """)
            monitor.consume(.live(reducer.consume(completed, now: now)))
        }
        if status == "completed" {
            #expect(monitor.completions.first?.duration == 1.5)
        } else {
            #expect(monitor.terminations.first?.duration == 1.5)
            #expect(monitor.terminations.first?.isFailure == (status == "failed"))
        }
    }

    private func mainThread() throws -> ActivityThread {
        try TestFixtures.decode(ActivityThread.self, #"{"id":"main","source":"cli","status":{"type":"active"}}"#)
    }

    private func apply(_ states: [SessionLifecycleState], to monitor: ActivityMonitor) {
        for state in states {
            _ = monitor.applySubagentLifecycle(state, terminalOnly: false)
        }
        monitor.reconcileSubagentCounts(states)
    }

    private func state(_ id: String, at date: Date, parent: String? = nil, terminal: SessionTerminalState? = nil) -> SessionLifecycleState {
        SessionLifecycleState(
            requestedThreadID: id, turnID: "turn-a", startedAt: date, effort: nil,
            lastProgressAt: date, terminal: terminal, rootTurnID: "turn-a", rootThreadID: "thread-a", parentThreadID: parent
        )
    }

    private func makeMonitor(_ directory: TestDirectory, _ preferences: TestPreferences) -> ActivityMonitor {
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        monitor.isActivitySourceHealthy = true
        return monitor
    }
}
