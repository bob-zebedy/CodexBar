import Foundation

struct PendingSubagentEvent {
    let event: ActivityRecord
    let source: ActivityEventSource
}

extension ActivityMonitor {
    /// 生命周期和工具事件 都携带子轮次, 已结束或未确认的归属不回退到当前根任务
    func matchingSubagentParentTaskKey(
        for event: ActivityRecord
    ) -> ActivityTaskKey? {
        guard let reference = subagentReference(for: event),
              let rootKey = subagentTurnLinks[reference], rootKey.sessionID == event.sessionID else { return nil }
        return tasks.first(where: { $0.value.resolvedTurnKey == rootKey })?.key
    }

    func subagentReference(for event: ActivityRecord) -> ActivityTurnReference? {
        guard let agentID = event.agentID, let turnID = event.turnID else { return nil }
        // 引用的相等性只由线程和轮次决定, 时间用于保留窗口
        return ActivityTurnReference(threadID: agentID, turnID: turnID, startedAt: event.timestamp)
    }

    func deferUnassociatedSubagentEvent(_ event: ActivityRecord, source: ActivityEventSource) -> Bool {
        guard let reference = subagentReference(for: event), subagentTurnLinks[reference] == nil else { return false }
        guard event.sessionID != nil else { return true }
        if !pendingSubagentEvents.contains(where: { $0.event == event }) {
            pendingSubagentEvents.append(PendingSubagentEvent(event: event, source: source))
        }
        return true
    }

    func subagentLifecycleReferences() -> [ActivityTurnReference] {
        let cutoff = Date().addingTimeInterval(-ActivityRetention.window)
        pendingSubagentEvents.removeAll { $0.event.timestamp <= cutoff }
        // 结束后的关联也保留一个回放窗口, 用于拒绝旧 Agent 的迟到生命周期事件
        subagentTurnLinks = subagentTurnLinks.filter { $0.key.startedAt > cutoff }
        var references = pendingSubagentEvents.compactMap { subagentReference(for: $0.event) }
        for task in tasks.values {
            for (owner, execution) in task.executions where !execution.isTerminal {
                guard let agentID = owner.agentID, let turnID = owner.turnID else { continue }
                references.append(ActivityTurnReference(threadID: agentID, turnID: turnID, startedAt: execution.lastEventAt))
            }
        }
        return Array(Set(references))
    }

    func applySubagentLifecycle(
        _ state: SessionLifecycleState,
        terminalOnly: Bool,
        into transitions: inout [ActivityTransition]
    ) -> Bool {
        guard state.readStatus == .complete,
              state.recordedThreadID == state.requestedThreadID,
              let rootTurnID = state.rootTurnID,
              let parentThreadID = state.parentThreadID, parentThreadID != state.requestedThreadID else { return false }
        let reference = ActivityTurnReference(threadID: state.requestedThreadID, turnID: state.turnID, startedAt: state.startedAt ?? Date())
        let eventSessions = Set(pendingSubagentEvents.compactMap { pending -> String? in
            subagentReference(for: pending.event) == reference ? pending.event.sessionID : nil
        })
        let rootSessionID = state.rootSessionID ?? subagentTurnLinks[reference]?.sessionID
            ?? (eventSessions.count == 1 ? eventSessions.first : nil)
        guard let rootSessionID, rootSessionID != state.requestedThreadID,
              eventSessions.isEmpty || eventSessions == [rootSessionID] else { return false }
        let rootKey = ActivityTaskKey.turn(session: rootSessionID, turn: rootTurnID)
        guard subagentTurnLinks[reference].map({ $0 == rootKey }) ?? true else { return false }
        subagentTurnLinks[reference] = rootKey
        guard !terminalOnly || state.terminal != nil,
              let key = tasks.first(where: { $0.value.resolvedTurnKey == rootKey })?.key,
              var task = tasks[key] else { return false }
        let owner = ActivityExecutionKey(agentID: state.requestedThreadID, turnID: state.turnID)
        let wasWaiting = task.state == .waitingApproval
        task.mergeExecutionLifecycle(state, owner: owner)
        let wasRunning = task.subagentsByID[state.requestedThreadID]?.isRunning
        let isRunning = state.terminal == nil
        if wasRunning != isRunning {
            let observedAt = state.lastProgressAt ?? state.startedAt ?? Date()
            task.recordSubagentActivity(agentID: state.requestedThreadID, isStarting: isRunning, at: observedAt)
            task.latestEvent = isRunning ? .subagentStarted : .subagentFinished
        }
        _ = resolvePendingApprovalIfPossible(for: &task, into: &transitions)
        if !terminalOnly {
            _ = mergeLifecycleProgress(from: state, key: key, into: &task)
        }
        tasks[key] = task
        if !terminalOnly, wasWaiting != (task.state == .waitingApproval) {
            clearProtection(for: key, taskID: task.displayID, reason: .progress)
        }
        return true
    }

    func replayAssociatedSubagentEvents(into transitions: inout [ActivityTransition]) -> Bool {
        var remaining: [PendingSubagentEvent] = []
        var ready: [PendingSubagentEvent] = []
        for pending in pendingSubagentEvents {
            if let reference = subagentReference(for: pending.event), subagentTurnLinks[reference] != nil {
                ready.append(pending)
            } else {
                remaining.append(pending)
            }
        }
        pendingSubagentEvents = remaining
        var waitingKeys: [ActivityTaskKey] = []
        for pending in ready {
            guard let reference = subagentReference(for: pending.event),
                  subagentTurnLinks[reference]?.sessionID == pending.event.sessionID else { continue }
            if let key = apply(pending.event, source: pending.source), pending.source == .live {
                waitingKeys.append(key)
            }
        }
        transitions.append(contentsOf: waitingApprovalTransitions(waitingKeys))
        return !ready.isEmpty
    }
}
