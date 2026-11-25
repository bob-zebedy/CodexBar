import Foundation

nonisolated struct PendingSubagentEvent {
    let event: ActivityDataRecord
    let source: ActivityEventSource
}

nonisolated extension ActivityTaskGraph {
    /// 生命周期和工具事件都携带子轮次, 已结束或未确认的归属不回退到当前根任务
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
        let references = pendingSubagentEvents.compactMap { subagentReference(for: $0.event) }
        return Array(Set(references))
    }

    mutating func applySubagentLifecycle(_ state: TurnLifecycleState) {
        guard state.readStatus == .complete || state.tracking != .live,
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
        // 已退出实时跟踪的子轮次仍需保留确认的归属, 用于汇总已知用量
        subagentTurnLinks[reference] = (rootKey, state.startedAt ?? subagentTurnLinks[reference]?.retainedAt ?? Date())
        guard state.tracking == .live, var task = tasks[rootKey] else { return }
        let key = rootKey
        let owner = ActivityExecutionKey(agentThreadID: state.requestedThreadID, turnID: state.turnID)
        task.mergeEffort(state.effort)
        if state.terminal != nil {
            task.finishExecution(owner, at: state.lastProgressAt ?? task.lastProgressAt)
        }
        _ = mergeLifecycleProgress(from: state, key: key, into: &task)
        tasks[key] = task
    }

    mutating func reconcileTaskCoverage(_ states: [TurnLifecycleState]) {
        for (key, var task) in tasks {
            let root = task.turnReference
            let children = TurnLifecycleState.subagentStates(for: [root], in: states)
            let references = Set(children.map { ActivityTurnReference(threadID: $0.requestedThreadID, turnID: $0.turnID) })
            let agentThreadIDs = Set(children.map(\.requestedThreadID))
            let rootState = states.first { $0.requestedThreadID == root.threadID && $0.turnID == root.turnID }
            func isLinkedChild(_ child: TurnLifecycleState) -> Bool {
                let reference = ActivityTurnReference(threadID: child.requestedThreadID, turnID: child.turnID)
                return child.rootThreadID == root.threadID && child.rootTurnID == root.turnID && subagentTurnLinks[reference]?.root == key
            }
            let hasChildren = children.allSatisfy {
                ($0.readStatus == .complete || $0.tracking != .live) && isLinkedChild($0)
            }
            let hasExecutions = task.executions.keys.allSatisfy { owner in
                guard !owner.isUnattributed else { return false }
                guard let agentThreadID = owner.agentThreadID else { return true }
                guard let turn = owner.turnID else { return false }
                return references.contains(ActivityTurnReference(threadID: agentThreadID, turnID: turn))
            }
            let hasPendingEvents = pendingSubagentEvents.contains { pending in
                guard pending.event.threadID == root.threadID else { return false }
                // 子事件的 turnID 属于子轮次, 缺少根轮次时只能按会话等待核验
                guard let rootTurnID = pending.event.context?.rootTurnID, !rootTurnID.isEmpty else { return true }
                return rootTurnID == root.turnID
            }
            let hasRoot = rootState.map { $0.readStatus == .complete || $0.tracking != .live } ?? false
            task.hasCompleteSubagentCoverage = hasRoot && hasChildren && hasExecutions && !hasPendingEvents
                && Set(task.subagentsByThreadID.keys).isSubset(of: agentThreadIDs)
            let hadCoverage = task.lifecycleCoverageCheckedAt != nil
            if let rootState, task.hasCompleteSubagentCoverage {
                task.subagentsByThreadID = Dictionary(grouping: children, by: \.requestedThreadID).mapValues { turns in
                    SubagentObservation(
                        isRunning: turns.contains { $0.tracking == .live && $0.terminal == nil },
                        timestamp: turns.compactMap { $0.lastProgressAt ?? $0.startedAt }.max() ?? .distantPast
                    )
                }
                if rootState.tracking == .live {
                    task.recordLifecycleRead(rootState, at: Date())
                } else {
                    task.lifecycleCoverageCheckedAt = children.filter { $0.tracking == .live && $0.terminal == nil }.compactMap(\.verifiedAt).min()
                }
            } else {
                // 异常会话判定需要整项任务的进展, 子轮次待核验时暂停判定
                task.lifecycleCoverageCheckedAt = nil
            }
            if !hadCoverage, task.lifecycleCoverageCheckedAt != nil {
                backfilledTasks.insert(key)
            }
            // 主轮次退出跟踪后, 只有已核验且仍在运行的子轮次可以维持任务可见
            if let rootState, rootState.tracking != .live, !children.contains(where: {
                $0.tracking == .live && $0.terminal == nil && $0.readStatus == .complete && isLinkedChild($0)
            }) {
                unavailableTurns.insert(key)
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
