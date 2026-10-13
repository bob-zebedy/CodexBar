import Foundation

nonisolated struct TaskTokenUsageRequest {
    let root: ActivityTurnReference
    let expectedAgentThreadIDs: Set<String>
    var references: Set<ActivityTurnReference>

    func tokenUsage(from states: [TurnLifecycleState], requiresFinalTokenUsage: Bool = true) -> TokenUsage? {
        let agentThreadIDs = Set(references.filter { $0 != root }.map(\.threadID))
        guard !requiresFinalTokenUsage || expectedAgentThreadIDs.isSubset(of: agentThreadIDs) else { return nil }
        var total: TokenUsage?
        for reference in references {
            guard let state = states.first(where: { $0.requestedThreadID == reference.threadID && $0.turnID == reference.turnID }),
                  state.readStatus == .complete,
                  state.rootTurnID == root.turnID,
                  (state.rootThreadID ?? state.requestedThreadID) == root.threadID,
                  !requiresFinalTokenUsage || reference == root || state.terminal != nil,
                  let tokenUsage = state.tokenUsage else {
                if requiresFinalTokenUsage {
                    return nil
                }
                continue
            }
            if let previous = total {
                guard let sum = previous.adding(tokenUsage) else { return nil }
                total = sum
            } else {
                total = tokenUsage
            }
        }
        return total
    }
}

nonisolated extension ActivityTaskGraph {
    mutating func registerTerminalTokenUsage(
        id: UUID, task: ActivityTask
    ) {
        // 缺少子 Agent 身份时不能把主会话小计展示为整项任务总量
        guard !task.executions.keys.contains(where: \.isUnattributed) else { return }
        terminalTokenUsageRequests[id] = tokenUsageRequest(for: task)
    }

    private func tokenUsageRequest(
        for task: ActivityTask
    ) -> TaskTokenUsageRequest {
        let root = task.turnReference
        var references: Set = [root]
        references.formUnion(subagentTurnLinks.filter { $0.value.root == task.key }.map(\.key))
        for owner in task.executions.keys {
            guard let agentThreadID = owner.agentThreadID, let turn = owner.turnID else { continue }
            references.insert(ActivityTurnReference(threadID: agentThreadID, turnID: turn))
        }
        return TaskTokenUsageRequest(
            root: root, expectedAgentThreadIDs: Set(task.subagentsByThreadID.keys),
            references: references
        )
    }

    func activeTokenUsageReferences() -> [ActivityTurnReference] {
        var references: Set<ActivityTurnReference> = []
        for task in tasks.values {
            references.formUnion(tokenUsageRequest(for: task).references)
        }
        return Array(references)
    }

    mutating func applyActiveTokenUsage(_ states: [TurnLifecycleState]) {
        for (key, var task) in tasks {
            let request = tokenUsageRequest(for: task)
            // 运行中汇总已明确归属的累计用量, 尚未产生记录的会话不伪造零值
            let tokenUsage = request.tokenUsage(from: states, requiresFinalTokenUsage: false)
            guard task.tokenUsage != tokenUsage else { continue }
            task.tokenUsage = tokenUsage
            tasks[key] = task
        }
    }

    /// 完成卡片保留期间继续补齐用量, 轮次终态可能先于最后一条用量更新
    mutating func terminalTokenUsageReferences() -> [ActivityTurnReference] {
        var references: Set<ActivityTurnReference> = []
        for (id, var request) in terminalTokenUsageRequests {
            let rootKey = ActivityTaskKey(thread: request.root.threadID, turn: request.root.turnID)
            request.references.formUnion(subagentTurnLinks.filter { $0.value.root == rootKey }.map(\.key))
            terminalTokenUsageRequests[id] = request
            references.formUnion(request.references)
        }
        return Array(references)
    }

    mutating func applyTerminalTokenUsage(_ states: [TurnLifecycleState]) {
        for (id, var request) in terminalTokenUsageRequests {
            guard states.contains(where: { $0.requestedThreadID == request.root.threadID && $0.turnID == request.root.turnID }) else { continue }
            let rootKey = ActivityTaskKey(thread: request.root.threadID, turn: request.root.turnID)
            request.references.formUnion(subagentTurnLinks.filter { $0.value.root == rootKey }.map(\.key))
            terminalTokenUsageRequests[id] = request
            // 仅汇总已确认属于本轮的会话, 临时读取不完整时保留上次结果
            guard let tokenUsage = request.tokenUsage(from: states) else { continue }
            if let index = completions.firstIndex(where: { $0.id == id }), completions[index].tokenUsage != tokenUsage {
                completions[index].tokenUsage = tokenUsage
            }
            if let index = terminations.firstIndex(where: { $0.id == id }), terminations[index].tokenUsage != tokenUsage {
                terminations[index].tokenUsage = tokenUsage
            }
        }
    }
}
