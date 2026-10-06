import Foundation

struct TaskTokenRequest {
    let root: ActivityTurnReference
    let expectedAgentIDs: Set<String>
    var references: Set<ActivityTurnReference>
    let deadline: Date
    var nextReadAt = Date.distantPast

    func usage(from states: [SessionLifecycleState], requiresFinalUsage: Bool = true) -> TokenUsage? {
        let agentIDs = Set(references.filter { $0 != root }.map(\.threadID))
        guard !requiresFinalUsage || expectedAgentIDs.isSubset(of: agentIDs) else { return nil }
        var total: TokenUsage?
        for reference in references {
            guard let state = states.first(where: { $0.requestedThreadID == reference.threadID && $0.turnID == reference.turnID }),
                  state.readStatus == .complete, state.recordedThreadID == reference.threadID,
                  state.rootTurnID == root.turnID,
                  (state.rootSessionID ?? state.recordedThreadID) == root.threadID,
                  !requiresFinalUsage || reference == root || state.terminal != nil,
                  let usage = state.tokenUsage else {
                if requiresFinalUsage {
                    return nil
                }
                continue
            }
            if let previous = total {
                guard let sum = previous.adding(usage) else { return nil }
                total = sum
            } else {
                total = usage
            }
        }
        return total
    }
}

extension ActivityMonitor {
    func registerTerminalTokenUsage(
        id: UUID, key: ActivityTaskKey, task: ActivityTask?, endedAt: Date, now: Date = Date()
    ) {
        guard let session = key.sessionID, let turn = task?.associatedTurnID ?? key.turnID else { return }
        // 缺少子 Agent 身份时不能把主线程小计展示为整项任务总量
        guard task?.executions.keys.contains(where: \.isUnattributed) != true else { return }
        let root = ActivityTurnReference(threadID: session, turnID: turn, startedAt: task?.startedAt ?? endedAt)
        terminalTokenUsageRequests[id] = tokenUsageRequest(root: root, task: task, deadline: now.addingTimeInterval(30))
    }

    private func tokenUsageRequest(
        root: ActivityTurnReference, task: ActivityTask?, deadline: Date
    ) -> TaskTokenRequest {
        var references: Set = [root]
        let rootKey = ActivityTaskKey.turn(session: root.threadID, turn: root.turnID)
        references.formUnion(subagentTurnLinks.filter { $0.value == rootKey }.map(\.key))
        if let task {
            for owner in task.executions.keys {
                guard let agent = owner.agentID, let turn = owner.turnID else { continue }
                references.insert(ActivityTurnReference(threadID: agent, turnID: turn, startedAt: root.startedAt))
            }
        }
        return TaskTokenRequest(
            root: root, expectedAgentIDs: Set(task?.subagentsByID.keys.map(\.self) ?? []),
            references: references, deadline: deadline
        )
    }

    func activeTokenUsageReferences() -> [ActivityTurnReference] {
        var references: Set<ActivityTurnReference> = []
        for task in tasks.values {
            guard let root = task.turnReference else { continue }
            references.formUnion(tokenUsageRequest(root: root, task: task, deadline: .distantFuture).references)
        }
        return Array(references)
    }

    @discardableResult
    func applyActiveTokenUsage(_ states: [SessionLifecycleState]) -> Bool {
        var changed = false
        for (key, var task) in tasks {
            guard let root = task.turnReference else { continue }
            let request = tokenUsageRequest(root: root, task: task, deadline: .distantFuture)
            // 运行中汇总已明确归属的累计用量, 尚未产生记录的线程不伪造零值
            let usage = request.usage(from: states, requiresFinalUsage: false)
            guard task.tokenUsage != usage else { continue }
            task.tokenUsage = usage
            tasks[key] = task
            changed = true
        }
        return changed
    }

    /// 结束后有界重读, 轮次终态可能先于最后一条用量更新
    func prepareTerminalTokenUsageReadBatch(now: Date) -> [ActivityTurnReference] {
        terminalTokenUsageRequests = terminalTokenUsageRequests.filter { $0.value.deadline > now }
        let due = terminalTokenUsageRequests.filter { $0.value.nextReadAt <= now }
            .sorted { $0.value.nextReadAt < $1.value.nextReadAt }.prefix(16)
        var references: Set<ActivityTurnReference> = []
        for (id, var request) in due {
            let rootKey = ActivityTaskKey.turn(session: request.root.threadID, turn: request.root.turnID)
            request.references.formUnion(subagentTurnLinks.filter { $0.value == rootKey }.map(\.key))
            request.nextReadAt = now.addingTimeInterval(2)
            terminalTokenUsageRequests[id] = request
            references.formUnion(request.references)
        }
        return references.map {
            var reference = $0
            reference.isTerminalUsageOnly = true
            return reference
        }
    }

    @discardableResult
    func applyTerminalTokenUsage(_ states: [SessionLifecycleState]) -> Bool {
        var changed = false
        for (id, var request) in terminalTokenUsageRequests {
            guard states.contains(where: { $0.requestedThreadID == request.root.threadID && $0.turnID == request.root.turnID }) else { continue }
            let rootKey = ActivityTaskKey.turn(session: request.root.threadID, turn: request.root.turnID)
            request.references.formUnion(subagentTurnLinks.filter { $0.value == rootKey }.map(\.key))
            terminalTokenUsageRequests[id] = request
            // 仅汇总已确认属于本轮的线程, 临时读取不完整时保留上次结果
            guard let usage = request.usage(from: states) else { continue }
            if let index = completions.firstIndex(where: { $0.id == id }), completions[index].tokenUsage != usage {
                completions[index].tokenUsage = usage
                changed = true
            }
            if let index = terminations.firstIndex(where: { $0.id == id }), terminations[index].tokenUsage != usage {
                terminations[index].tokenUsage = usage
                changed = true
            }
        }
        return changed
    }
}
