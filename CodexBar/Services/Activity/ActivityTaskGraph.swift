import Foundation

/// reader 独占任务状态, UI 只读取发布的值快照, 不处理原始事件或补查其他缓存
nonisolated struct ActivityTaskGraph {
    var tasks: [ActivityTaskKey: ActivityTask] = [:]
    var pendingTerminalTasks: [ActivityTaskKey: PendingTerminalTask] = [:]
    var subagentTurnLinks: [ActivityTurnReference: (root: ActivityTaskKey, retainedAt: Date)] = [:]
    var pendingSubagentEvents: [PendingSubagentEvent] = []
    var completions: [ActivityCompletion] = []
    var terminations: [ActivityTermination] = []
    var recentlyEndedTaskAt: [ActivityTaskKey: Date] = [:]
    var terminalTokenUsageRequests: [UUID: TaskTokenUsageRequest] = [:]
    var unavailableTurns = Set<ActivityTaskKey>()
    var backfilledTasks = Set<ActivityTaskKey>()
    var terminalEvents: [ActivityTerminalEvent] = []

    mutating func update(
        events: [ActivityDataRecord], source: ActivityEventSource, lifecycle: TurnLifecycleSnapshot
    ) -> [ActivityTransition] {
        let previouslyWaiting = Set(tasks.values.filter { $0.blockingWaitStartedAt != nil }.map(\.displayID))
        let previouslyAwaitingApproval = Set(tasks.values.filter { $0.state == .waitingApproval }.map(\.displayID))
        var transitions = consume(events, source: source)
        transitions += reconcile(lifecycle.lifecycleStates(for: lifecycleReferences()))
        for (key, task) in tasks where task.state == .waitingApproval && !previouslyAwaitingApproval.contains(task.displayID) {
            if let approval = task.displayedApproval {
                tasks[key]?.stateChangedAt = approval.requestedAt
            }
        }
        var waiting: [UUID: (snapshot: ActivityTaskSnapshot, since: Date)] = [:]
        for task in tasks.values {
            guard let since = task.blockingWaitStartedAt else { continue }
            let snapshot = task.snapshot
            waiting[task.displayID] = (snapshot, since)
            // 提问只存在于实时内存状态, 不产生历史事件, 在生命周期核对后发布
            if snapshot.presentation?.hasBlockingInputRequest == true {
                transitions.append(.waiting(snapshot, since: since))
            }
        }
        var notified = Set<UUID>()
        // 事件中的等待只是候选, 提醒必须使用本次核对后的最终状态
        return transitions.compactMap { transition in
            guard case let .waiting(snapshot, _) = transition else { return transition }
            guard !previouslyWaiting.contains(snapshot.id), let current = waiting[snapshot.id],
                  notified.insert(snapshot.id).inserted else { return nil }
            return .waiting(current.snapshot, since: current.since)
        }
    }

    mutating func consume(_ events: [ActivityDataRecord], source: ActivityEventSource) -> [ActivityTransition] {
        var transitions: [ActivityTransition] = []
        var waiting: [ActivityTaskKey] = []
        for event in events {
            if let key = apply(event, source: source, into: &transitions) {
                waiting.append(key)
            }
        }
        if source == .live {
            transitions += waitingApprovalTransitions(waiting)
        }
        return transitions
    }

    mutating func reconcile(_ states: [TurnLifecycleState]) -> [ActivityTransition] {
        unavailableTurns = Set(states.filter { $0.readStatus != .complete }.map { ActivityTaskKey(thread: $0.requestedThreadID, turn: $0.turnID) })
        var transitions: [ActivityTransition] = []
        for state in states {
            applySubagentLifecycle(state)
            applyLifecycleState(state, into: &transitions)
        }
        let waiting = replayAssociatedSubagentEvents(into: &transitions)
        mergeExecutionLifecycles(states)
        transitions += waitingApprovalTransitions(waiting)
        reconcileSubagentCounts(states)
        applyActiveTokenUsage(states)
        applyTerminalTokenUsage(states)
        prune(now: Date())
        return transitions
    }

    mutating func lifecycleReferences() -> [ActivityTurnReference] {
        Array(Set(activeTokenUsageReferences() + subagentLifecycleReferences() + terminalTokenUsageReferences()
                + pendingTerminalTasks.values.map(\.task.turnReference)))
    }

    mutating func prune(now: Date) {
        pendingTerminalTasks = pendingTerminalTasks.filter { $0.value.expiresAt > now }
        let cutoff = now.addingTimeInterval(-ActivityRetention.terminalDisplayWindow)
        completions.removeAll { $0.completedAt <= cutoff }
        terminations.removeAll { $0.terminatedAt <= cutoff }
        let retained = Set(completions.map(\.id)).union(terminations.map(\.id))
        terminalTokenUsageRequests = terminalTokenUsageRequests.filter { retained.contains($0.key) }
        recentlyEndedTaskAt = recentlyEndedTaskAt.filter { $0.value > now.addingTimeInterval(-86400) }
        let childCutoff = now.addingTimeInterval(-ActivityRetention.window)
        pendingSubagentEvents.removeAll { $0.event.timestamp <= childCutoff }
        subagentTurnLinks = subagentTurnLinks.filter { $0.value.retainedAt > childCutoff }
    }

    mutating func apply(_ event: ActivityDataRecord, source: ActivityEventSource, into transitions: inout [ActivityTransition]) -> ActivityTaskKey? {
        guard event.origin == .main || event.origin == .auxiliary else { return nil }
        if deferUnassociatedSubagentEvent(event, source: source) {
            return nil
        }
        switch event.eventKind {
        case .turnStarted:
            if event.agentThreadID == nil {
                startTask(from: event)
            }
        case .toolStarted, .toolCompleted, .compactionStarted, .compactionCompleted, .approvalRequested:
            return resumeTask(from: event)
        case .subagentStarted, .subagentEnded:
            updateSubagentActivity(from: event)
        case .turnCompleted, .turnAborted:
            if event.agentThreadID == nil {
                finishTask(from: event, source: source, into: &transitions)
            }
        case .none: break
        }
        return nil
    }

    private mutating func startTask(from event: ActivityDataRecord) {
        guard let key = ActivityTaskKey(event: event), pendingTerminalTasks[key] == nil,
              recentEndedDate(for: key) == nil else { return }
        let existing = tasks[key]
        if let existing, event.timestamp < existing.lastMainEventAt {
            return
        }
        for task in tasks.values where task.key != key && task.key.threadID == key.threadID {
            pendingTerminalTasks[task.key] = PendingTerminalTask(task: task, supersededAt: event.timestamp)
        }
        tasks = tasks.filter { $0.key == key || $0.key.threadID != key.threadID }
        if var task = existing {
            task.resumeExecution(from: event)
            task.mergeMetadata(from: event)
            task.recordProgress(at: event.timestamp)
            task.startedAt = task.startedAt ?? event.context?.turnStartedAt
            tasks[key] = task
        } else {
            tasks[key] = ActivityTask(displayID: UUID(), key: key, event: event, state: .running, startedAt: event.context?.turnStartedAt, progressGeneration: 1)
        }
    }

    private mutating func resumeTask(from event: ActivityDataRecord) -> ActivityTaskKey? {
        guard let eventKey = ActivityTaskKey(event: event) else { return nil }
        let matchedKey = event.agentThreadID == nil ? eventKey : matchingSubagentParentTaskKey(for: event)
        guard let key = matchedKey, recentEndedDate(for: key) == nil, pendingTerminalTasks[key] == nil, tasks[key] != nil || event.agentThreadID == nil else { return nil }
        var task = tasks[key] ?? ActivityTask(displayID: UUID(), key: key, event: event, state: .running, startedAt: nil, progressGeneration: 0)
        guard task.acceptsExecutionEvent(event) else { return nil }
        task.mergeMetadata(from: event)
        task.recordProgress(at: event.timestamp)
        let waiting: Bool
        if event.eventKind == .approvalRequested {
            waiting = task.recordApprovalRequest(from: event)
        } else {
            task.resumeExecution(from: event)
            waiting = false
        }
        tasks[key] = task
        return waiting ? key : nil
    }

    private mutating func updateSubagentActivity(from event: ActivityDataRecord) {
        guard let agentThreadID = event.agentThreadID, let rootThread = event.context?.rootThreadID, let rootTurn = event.context?.rootTurnID else { return }
        let key = ActivityTaskKey(thread: rootThread, turn: rootTurn)
        guard recentEndedDate(for: key) == nil, pendingTerminalTasks[key] == nil, var task = tasks[key],
              task.startedAt.map({ event.timestamp >= $0 }) ?? true else { return }
        let executions = task.executions.filter { $0.key.agentThreadID == agentThreadID }
        task.recordSubagentActivity(
            agentThreadID: agentThreadID,
            isStarting: event.eventKind == .subagentStarted,
            hasEnded: !executions.isEmpty && executions.values.allSatisfy(\.isTerminal),
            at: event.timestamp
        )
        task.mergeMetadata(from: event)
        task.recordProgress(at: event.timestamp)
        tasks[key] = task
    }

    private mutating func applyLifecycleState(_ state: TurnLifecycleState, into transitions: inout [ActivityTransition]) {
        let key = ActivityTaskKey(thread: state.requestedThreadID, turn: state.turnID)
        if var pending = pendingTerminalTasks[key] {
            Self.mergeLifecycleBackfill(from: state, into: &pending.task)
            if state.readStatus == .complete, let terminal = state.terminal {
                pendingTerminalTasks.removeValue(forKey: key)
                resolveTerminal(
                    terminal,
                    task: pending.task,
                    key: key,
                    abortFallback: state.terminalObservedAt ?? state.contextObservedAt ?? pending.supersededAt,
                    publishesEvents: !state.isHistoricalTerminal,
                    into: &transitions
                )
            } else {
                pendingTerminalTasks[key] = pending
            }
            return
        }
        guard var task = tasks[key] else { return }
        let hadCoverage = task.lifecycleCoverageCheckedAt != nil
        task.recordLifecycleRead(state, at: Date())
        Self.mergeLifecycleBackfill(from: state, into: &task)
        let progressed = mergeLifecycleProgress(from: state, key: key, into: &task)
        if state.readStatus == .complete, let terminal = state.terminal {
            tasks.removeValue(forKey: key)
            resolveTerminal(
                terminal,
                task: task,
                key: key,
                abortFallback: state.terminalObservedAt ?? state.contextObservedAt ?? Date(),
                publishesEvents: !state.isHistoricalTerminal,
                into: &transitions
            )
            return
        }
        tasks[key] = task
        if progressed || (!hadCoverage && task.lifecycleCoverageCheckedAt != nil) {
            backfilledTasks.insert(key)
        }
    }

    func mergeLifecycleProgress(from state: TurnLifecycleState, key _: ActivityTaskKey, into task: inout ActivityTask) -> Bool {
        guard state.readStatus == .complete, let progress = state.lastProgressAt else { return false }
        return task.recordProgress(at: progress)
    }

    private mutating func mergeExecutionLifecycles(_ states: [TurnLifecycleState]) {
        // 暂存事件补齐后再应用审批状态, 避免已处理的请求恢复等待
        for state in states where state.readStatus == .complete {
            let reference = ActivityTurnReference(threadID: state.requestedThreadID, turnID: state.turnID)
            let key: ActivityTaskKey
            let owner: ActivityExecutionKey
            if state.parentThreadID != nil {
                guard let root = subagentTurnLinks[reference]?.root,
                      root.threadID == state.rootThreadID, root.turnID == state.rootTurnID else { continue }
                key = root
                owner = ActivityExecutionKey(agentThreadID: state.requestedThreadID, turnID: state.turnID)
            } else {
                key = ActivityTaskKey(thread: state.requestedThreadID, turn: state.turnID)
                owner = ActivityExecutionKey(agentThreadID: nil, turnID: state.turnID)
            }
            tasks[key]?.mergeExecutionLifecycle(state, owner: owner)
        }
    }

    static func backfilledStartedAt(for task: ActivityTask, state: TurnLifecycleState) -> Date? {
        guard task.startedAt == nil, let start = state.startedAt, start <= task.lastActivityAt.addingTimeInterval(1) else { return nil }
        return start
    }

    static func mergeLifecycleBackfill(from state: TurnLifecycleState, into task: inout ActivityTask) {
        if state.readStatus == .complete, let status = state.turnStatus {
            task.terminalFailed = status == .failed
        }
        if let start = backfilledStartedAt(for: task, state: state) {
            task.startedAt = start
        }
        task.mergeEffort(state.effort)
    }

    mutating func finishTask(from event: ActivityDataRecord, source: ActivityEventSource, into transitions: inout [ActivityTransition]) {
        guard let key = ActivityTaskKey(event: event) else { return }
        guard recentEndedDate(for: key) == nil else {
            tasks.removeValue(forKey: key)
            pendingTerminalTasks.removeValue(forKey: key)
            return
        }
        var task = pendingTerminalTasks[key]?.task ?? tasks[key] ?? ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running, startedAt: event.context?.turnStartedAt, progressGeneration: 0
        )
        let tolerance: TimeInterval = event.context?.turnCompletedAt == nil ? 0 : 1
        guard event.timestamp.addingTimeInterval(tolerance) >= task.lastMainEventAt else { return }
        task.mergeMetadata(from: event)
        if task.startedAt == nil, let start = event.context?.turnStartedAt, start <= event.timestamp {
            task.startedAt = start
        }
        tasks.removeValue(forKey: key)
        pendingTerminalTasks.removeValue(forKey: key)
        let at = event.context == nil ? event.timestamp : event.context?.turnCompletedAt
        task.terminalFailed = task.terminalFailed || event.context?.turnStatus == .failed
        let terminal: TurnTerminalState = event.eventKind == .turnCompleted
            ? .completed(at: at, duration: event.context?.duration) : .aborted(at: at, duration: event.context?.duration)
        resolveTerminal(terminal, task: task, key: key, abortFallback: event.timestamp, publishesEvents: source == .live, into: &transitions)
        recordEndedTask(key, at: event.timestamp)
    }

    mutating func resolveTerminal(
        _ terminal: TurnTerminalState,
        task: ActivityTask,
        key: ActivityTaskKey,
        abortFallback: Date,
        publishesEvents: Bool = true,
        into transitions: inout [ActivityTransition]
    ) {
        guard recentEndedDate(for: key) == nil else { return }
        switch terminal {
        case let .completed(at, duration):
            let completedAt = max(at ?? abortFallback, task.lastActivityAt)
            let completion = ActivityCompletion(
                id: UUID(),
                taskID: task.displayID,
                projectName: task.projectName,
                modelName: task.modelName,
                effort: task.effort,
                completedAt: completedAt,
                duration: duration ?? at.flatMap { task.preciseDuration(until: $0) },
                threadID: task.key.threadID
            )
            completions.append(completion)
            registerTerminalTokenUsage(id: completion.id, task: task)
            recordEndedTask(key, at: completedAt)
            if publishesEvents {
                terminalEvents.append(.completed(completion))
                transitions.append(.completed(completion))
            }
        case let .aborted(at, duration):
            let terminatedAt = max(at ?? abortFallback, task.lastActivityAt)
            let termination = ActivityTermination(
                id: UUID(),
                taskID: task.displayID,
                projectName: task.projectName,
                modelName: task.modelName,
                effort: task.effort,
                terminatedAt: terminatedAt,
                duration: duration ?? at.flatMap { task.preciseDuration(until: $0) },
                isFailure: task.terminalFailed,
                threadID: task.key.threadID
            )
            terminations.append(termination)
            registerTerminalTokenUsage(id: termination.id, task: task)
            recordEndedTask(key, at: terminatedAt)
            if publishesEvents {
                terminalEvents.append(.terminated(termination))
            }
        }
    }

    mutating func recentEndedDate(for key: ActivityTaskKey, now: Date = Date()) -> Date? {
        guard let date = recentlyEndedTaskAt[key] else { return nil }
        guard date > now.addingTimeInterval(-86400) else { recentlyEndedTaskAt.removeValue(forKey: key)
            return nil
        }
        return date
    }

    mutating func recordEndedTask(_ key: ActivityTaskKey, at date: Date) {
        recentlyEndedTaskAt[key] = max(recentlyEndedTaskAt[key] ?? .distantPast, date)
    }

    func waitingApprovalTransitions(_ keys: [ActivityTaskKey]) -> [ActivityTransition] {
        var seen = Set<ActivityTaskKey>()
        return keys.reversed().compactMap { key in
            guard seen.insert(key).inserted, let task = tasks[key], task.state == .waitingApproval else { return nil }
            return .waiting(task.snapshot, since: task.blockingWaitStartedAt ?? task.stateChangedAt)
        }.reversed()
    }
}
