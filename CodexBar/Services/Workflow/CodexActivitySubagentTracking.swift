import Foundation

struct CodexPendingSubagentEvent {
    let event: WorkflowHookEvent
    let source: CodexActivityEventSource
}

extension CodexActivityMonitor {
    /// 生命周期和工具 Hook 都携带子轮次, 已结束或未确认的归属不回退到当前根任务
    func matchingSubagentParentTaskKey(
        for event: WorkflowHookEvent
    ) -> CodexActivityTaskKey? {
        guard let reference = subagentReference(for: event),
              let rootKey = subagentTurnLinks[reference], rootKey.sessionId == event.sessionId else { return nil }
        return tasks.first(where: { $0.value.resolvedTurnKey == rootKey })?.key
    }

    func subagentReference(for event: WorkflowHookEvent) -> CodexActivityTurnReference? {
        guard let agentId = event.agentId, let turnId = event.turnId else { return nil }
        // 引用的相等性只由线程和轮次决定, 时间只用于文件定位
        return CodexActivityTurnReference(sessionId: agentId, turnId: turnId, startedAt: event.timestamp)
    }

    func deferUnassociatedSubagentEvent(_ event: WorkflowHookEvent, source: CodexActivityEventSource) -> Bool {
        guard let reference = subagentReference(for: event), subagentTurnLinks[reference] == nil else { return false }
        guard event.sessionId != nil else { return true }
        if !pendingSubagentEvents.contains(where: { $0.event == event }) {
            pendingSubagentEvents.append(CodexPendingSubagentEvent(event: event, source: source))
        }
        return true
    }

    func subagentLifecycleReferences() -> [CodexActivityTurnReference] {
        let cutoff = Date().addingTimeInterval(-CodexActivityRetention.window)
        pendingSubagentEvents.removeAll { $0.event.timestamp <= cutoff }
        // 结束后的关联也保留一个回放窗口, 用于拒绝旧 Agent 的迟到生命周期 Hook
        subagentTurnLinks = subagentTurnLinks.filter { $0.key.startedAt > cutoff }
        var references = pendingSubagentEvents.compactMap { subagentReference(for: $0.event) }
        for task in tasks.values {
            for (owner, execution) in task.executions where !execution.isTerminal {
                guard let agentId = owner.agentId, let turnId = owner.turnId else { continue }
                references.append(CodexActivityTurnReference(sessionId: agentId, turnId: turnId, startedAt: execution.lastHookEventAt))
            }
        }
        return Array(Set(references))
    }

    func applySubagentLifecycle(
        _ state: CodexSessionTaskLifecycleState,
        terminalOnly: Bool,
        into transitions: inout [CodexActivityTransition]
    ) -> Bool {
        guard state.readStatus == .complete,
              state.threadId == state.sessionId,
              let rootTurnId = state.rootTurnId,
              let parentThreadId = state.parentThreadId, parentThreadId != state.sessionId else { return false }
        let reference = CodexActivityTurnReference(sessionId: state.sessionId, turnId: state.turnId, startedAt: state.startedAt ?? Date())
        let hookSessions = Set(pendingSubagentEvents.compactMap { pending -> String? in
            subagentReference(for: pending.event) == reference ? pending.event.sessionId : nil
        })
        let rootSessionId = state.rootSessionId ?? subagentTurnLinks[reference]?.sessionId
            ?? (hookSessions.count == 1 ? hookSessions.first : nil)
        guard let rootSessionId, rootSessionId != state.sessionId,
              hookSessions.isEmpty || hookSessions == [rootSessionId] else { return false }
        let rootKey = CodexActivityTaskKey.turn(session: rootSessionId, turn: rootTurnId)
        guard subagentTurnLinks[reference].map({ $0 == rootKey }) ?? true else { return false }
        subagentTurnLinks[reference] = rootKey
        guard !terminalOnly || state.terminal != nil,
              let key = tasks.first(where: { $0.value.resolvedTurnKey == rootKey })?.key,
              var task = tasks[key] else { return false }
        let owner = CodexActivityExecutionKey(agentId: state.sessionId, turnId: state.turnId)
        let wasWaiting = task.state == .waitingApproval
        task.mergeExecutionLifecycle(state, owner: owner)
        _ = resolvePendingApprovalIfPossible(for: &task, into: &transitions)
        if !terminalOnly {
            _ = mergeLifecycleProgress(from: state, key: key, into: &task)
        }
        tasks[key] = task
        if !terminalOnly, wasWaiting != (task.state == .waitingApproval) {
            clearActivityProtection(for: key, taskID: task.displayID, reason: .progress)
        }
        return true
    }

    func replayAssociatedSubagentEvents(into transitions: inout [CodexActivityTransition]) -> Bool {
        var remaining: [CodexPendingSubagentEvent] = []
        var ready: [CodexPendingSubagentEvent] = []
        for pending in pendingSubagentEvents {
            if let reference = subagentReference(for: pending.event), subagentTurnLinks[reference] != nil {
                ready.append(pending)
            } else {
                remaining.append(pending)
            }
        }
        pendingSubagentEvents = remaining
        var waitingKeys: [CodexActivityTaskKey] = []
        for pending in ready {
            guard let reference = subagentReference(for: pending.event),
                  subagentTurnLinks[reference]?.sessionId == pending.event.sessionId else { continue }
            if let key = apply(pending.event, source: pending.source), pending.source == .live {
                waitingKeys.append(key)
            }
        }
        transitions.append(contentsOf: waitingApprovalTransitions(waitingKeys))
        return !ready.isEmpty
    }
}
