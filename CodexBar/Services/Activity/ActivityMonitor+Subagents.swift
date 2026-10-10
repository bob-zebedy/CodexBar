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
              let rootKey = subagentTurnLinks[reference]?.root, rootKey.threadID == event.threadID else { return nil }
        return tasks[rootKey] == nil ? nil : rootKey
    }

    func subagentReference(for event: ActivityRecord) -> ActivityTurnReference? {
        guard let agentID = event.agentID, let turnID = event.turnID else { return nil }
        return ActivityTurnReference(threadID: agentID, turnID: turnID)
    }

    func deferUnassociatedSubagentEvent(_ event: ActivityRecord, source: ActivityEventSource) -> Bool {
        guard let reference = subagentReference(for: event), subagentTurnLinks[reference] == nil else { return false }
        guard event.threadID != nil else { return true }
        if !pendingSubagentEvents.contains(where: { $0.event == event }) {
            pendingSubagentEvents.append(PendingSubagentEvent(event: event, source: source))
        }
        return true
    }

    func subagentLifecycleReferences() -> [ActivityTurnReference] {
        let cutoff = Date().addingTimeInterval(-ActivityRetention.window)
        pendingSubagentEvents.removeAll { $0.event.timestamp <= cutoff }
        // 结束后的关联也保留一个回放窗口, 用于拒绝旧 Agent 的迟到生命周期事件
        subagentTurnLinks = subagentTurnLinks.filter { $0.value.retainedAt > cutoff }
        var references = pendingSubagentEvents.compactMap { subagentReference(for: $0.event) }
        for task in tasks.values {
            for (owner, execution) in task.executions where !execution.isTerminal {
                guard let agentID = owner.agentID, let turnID = owner.turnID else { continue }
                references.append(ActivityTurnReference(threadID: agentID, turnID: turnID))
            }
        }
        return Array(Set(references))
    }

    func applySubagentLifecycle(
        _ state: SessionLifecycleState,
        terminalOnly: Bool
    ) -> Bool {
        guard state.readStatus == .complete,
              let rootTurnID = state.rootTurnID,
              let rootThreadID = state.rootThreadID,
              let parentThreadID = state.parentThreadID, parentThreadID != state.requestedThreadID else { return false }
        let reference = ActivityTurnReference(threadID: state.requestedThreadID, turnID: state.turnID)
        let eventThreads = Set(pendingSubagentEvents.compactMap { pending -> String? in
            subagentReference(for: pending.event) == reference ? pending.event.threadID : nil
        })
        guard rootThreadID != state.requestedThreadID,
              eventThreads.isEmpty || eventThreads == [rootThreadID] else { return false }
        let rootKey = ActivityTaskKey(thread: rootThreadID, turn: rootTurnID)
        guard subagentTurnLinks[reference].map({ $0.root == rootKey }) ?? true else { return false }
        subagentTurnLinks[reference] = (rootKey, state.startedAt ?? subagentTurnLinks[reference]?.retainedAt ?? Date())
        guard !terminalOnly || state.terminal != nil,
              var task = tasks[rootKey] else { return false }
        let key = rootKey
        let owner = ActivityExecutionKey(agentID: state.requestedThreadID, turnID: state.turnID)
        let wasWaiting = task.state == .waitingApproval
        task.mergeEffort(state.effort)
        task.mergeExecutionLifecycle(state, owner: owner)
        if !terminalOnly {
            _ = mergeLifecycleProgress(from: state, key: key, into: &task)
        }
        tasks[key] = task
        if !terminalOnly, wasWaiting != (task.state == .waitingApproval) {
            clearProtection(for: key, taskID: task.displayID, reason: .progress)
        }
        return true
    }

    @discardableResult
    func reconcileSubagentCounts(_ states: [SessionLifecycleState]) -> Bool {
        var changed = false
        for (key, var task) in tasks {
            let root = task.turnReference
            let children = SessionLifecycleState.subagentStates(for: [root], in: states)
            let references = Set(children.map { ActivityTurnReference(threadID: $0.requestedThreadID, turnID: $0.turnID) })
            let agentIDs = Set(children.map(\.requestedThreadID))
            let hasRoot = states.contains { $0.requestedThreadID == root.threadID && $0.turnID == root.turnID && $0.readStatus == .complete }
            let hasChildren = children.allSatisfy {
                $0.readStatus == .complete && $0.rootThreadID == root.threadID && $0.rootTurnID == root.turnID
                    && subagentTurnLinks[ActivityTurnReference(threadID: $0.requestedThreadID, turnID: $0.turnID)]?.root == key
            }
            let hasExecutions = task.executions.keys.allSatisfy { owner in
                guard !owner.isUnattributed else { return false }
                guard let agent = owner.agentID else { return true }
                guard let turn = owner.turnID else { return false }
                return references.contains(ActivityTurnReference(threadID: agent, turnID: turn))
            }
            let hasPendingEvents = pendingSubagentEvents.contains { $0.event.threadID == root.threadID }
            let previousCount = task.snapshot.activeSubagentCount
            task.hasCompleteSubagentCoverage = hasRoot && hasChildren && hasExecutions && !hasPendingEvents
                && Set(task.subagentsByID.keys).isSubset(of: agentIDs)
            if task.hasCompleteSubagentCoverage {
                task.subagentsByID = Dictionary(grouping: children, by: \.requestedThreadID).mapValues { turns in
                    SubagentObservation(
                        isRunning: turns.contains { $0.terminal == nil },
                        timestamp: turns.compactMap { $0.lastProgressAt ?? $0.startedAt }.max() ?? .distantPast
                    )
                }
            }
            changed = previousCount != task.snapshot.activeSubagentCount || changed
            tasks[key] = task
        }
        return changed
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
                  subagentTurnLinks[reference]?.root.threadID == pending.event.threadID else { continue }
            if let key = apply(pending.event, source: pending.source, into: &transitions), pending.source == .live {
                waitingKeys.append(key)
            }
        }
        transitions.append(contentsOf: waitingApprovalTransitions(waitingKeys))
        return !ready.isEmpty
    }
}
