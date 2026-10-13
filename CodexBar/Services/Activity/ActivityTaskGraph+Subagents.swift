import Foundation

nonisolated struct PendingSubagentEvent {
    let event: ActivityDataRecord
    let source: ActivityEventSource
}

nonisolated extension ActivityTaskGraph {
    /// 生命周期和工具事件 都携带子轮次, 已结束或未确认的归属不回退到当前根任务
    func matchingSubagentParentTaskKey(
        for event: ActivityDataRecord
    ) -> ActivityTaskKey? {
        guard let reference = subagentReference(for: event),
              let rootKey = subagentTurnLinks[reference]?.root, rootKey.threadID == event.threadID else { return nil }
        return tasks[rootKey] == nil ? nil : rootKey
    }

    func subagentReference(for event: ActivityDataRecord) -> ActivityTurnReference? {
        guard let agentThreadID = event.agentThreadID, let turnID = event.turnID else { return nil }
        return ActivityTurnReference(threadID: agentThreadID, turnID: turnID)
    }

    mutating func deferUnassociatedSubagentEvent(_ event: ActivityDataRecord, source: ActivityEventSource) -> Bool {
        guard let reference = subagentReference(for: event), subagentTurnLinks[reference] == nil else { return false }
        guard event.threadID != nil else { return true }
        if !pendingSubagentEvents.contains(where: { $0.event == event }) {
            pendingSubagentEvents.append(PendingSubagentEvent(event: event, source: source))
        }
        return true
    }

    mutating func subagentLifecycleReferences() -> [ActivityTurnReference] {
        let cutoff = Date().addingTimeInterval(-ActivityRetention.window)
        pendingSubagentEvents.removeAll { $0.event.timestamp <= cutoff }
        // 结束后的关联也保留一个回放窗口, 用于拒绝旧 Agent 的迟到生命周期事件
        subagentTurnLinks = subagentTurnLinks.filter { $0.value.retainedAt > cutoff }
        var references = pendingSubagentEvents.compactMap { subagentReference(for: $0.event) }
        for task in tasks.values {
            for (owner, execution) in task.executions where !execution.isTerminal {
                guard let agentThreadID = owner.agentThreadID, let turnID = owner.turnID else { continue }
                references.append(ActivityTurnReference(threadID: agentThreadID, turnID: turnID))
            }
        }
        return Array(Set(references))
    }

    mutating func applySubagentLifecycle(_ state: TurnLifecycleState) {
        guard state.readStatus == .complete,
              let rootTurnID = state.rootTurnID,
              let rootThreadID = state.rootThreadID,
              let parentThreadID = state.parentThreadID, parentThreadID != state.requestedThreadID else { return }
        let reference = ActivityTurnReference(threadID: state.requestedThreadID, turnID: state.turnID)
        let eventThreads = Set(pendingSubagentEvents.compactMap { pending -> String? in
            subagentReference(for: pending.event) == reference ? pending.event.threadID : nil
        })
        guard rootThreadID != state.requestedThreadID,
              eventThreads.isEmpty || eventThreads == [rootThreadID] else { return }
        let rootKey = ActivityTaskKey(thread: rootThreadID, turn: rootTurnID)
        guard subagentTurnLinks[reference].map({ $0.root == rootKey }) ?? true else { return }
        subagentTurnLinks[reference] = (rootKey, state.startedAt ?? subagentTurnLinks[reference]?.retainedAt ?? Date())
        guard var task = tasks[rootKey] else { return }
        let key = rootKey
        let owner = ActivityExecutionKey(agentThreadID: state.requestedThreadID, turnID: state.turnID)
        task.mergeEffort(state.effort)
        if state.terminal != nil {
            task.finishExecution(owner, at: state.lastProgressAt ?? task.lastProgressAt)
        }
        _ = mergeLifecycleProgress(from: state, key: key, into: &task)
        tasks[key] = task
    }

    mutating func reconcileSubagentCounts(_ states: [TurnLifecycleState]) {
        for (key, var task) in tasks {
            let root = task.turnReference
            let children = TurnLifecycleState.subagentStates(for: [root], in: states)
            let references = Set(children.map { ActivityTurnReference(threadID: $0.requestedThreadID, turnID: $0.turnID) })
            let agentThreadIDs = Set(children.map(\.requestedThreadID))
            let hasRoot = states.contains { $0.requestedThreadID == root.threadID && $0.turnID == root.turnID && $0.readStatus == .complete }
            let hasChildren = children.allSatisfy {
                $0.readStatus == .complete && $0.rootThreadID == root.threadID && $0.rootTurnID == root.turnID
                    && subagentTurnLinks[ActivityTurnReference(threadID: $0.requestedThreadID, turnID: $0.turnID)]?.root == key
            }
            let hasExecutions = task.executions.keys.allSatisfy { owner in
                guard !owner.isUnattributed else { return false }
                guard let agentThreadID = owner.agentThreadID else { return true }
                guard let turn = owner.turnID else { return false }
                return references.contains(ActivityTurnReference(threadID: agentThreadID, turnID: turn))
            }
            let hasPendingEvents = pendingSubagentEvents.contains { $0.event.threadID == root.threadID }
            task.hasCompleteSubagentCoverage = hasRoot && hasChildren && hasExecutions && !hasPendingEvents
                && Set(task.subagentsByThreadID.keys).isSubset(of: agentThreadIDs)
            if task.hasCompleteSubagentCoverage {
                task.subagentsByThreadID = Dictionary(grouping: children, by: \.requestedThreadID).mapValues { turns in
                    SubagentObservation(
                        isRunning: turns.contains { $0.terminal == nil },
                        timestamp: turns.compactMap { $0.lastProgressAt ?? $0.startedAt }.max() ?? .distantPast
                    )
                }
            }
            tasks[key] = task
        }
    }

    mutating func replayAssociatedSubagentEvents(into transitions: inout [ActivityTransition]) -> [ActivityTaskKey] {
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
        return waitingKeys
    }
}
