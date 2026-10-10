import Foundation

struct TaskTokenRequest {
    let root: ActivityTurnReference
    let expectedAgentIDs: Set<String>
    var references: Set<ActivityTurnReference>

    func usage(from states: [SessionLifecycleState], requiresFinalUsage: Bool = true) -> TokenUsage? {
        let agentIDs = Set(references.filter { $0 != root }.map(\.threadID))
        guard !requiresFinalUsage || expectedAgentIDs.isSubset(of: agentIDs) else { return nil }
        var total: TokenUsage?
        for reference in references {
            guard let state = states.first(where: { $0.requestedThreadID == reference.threadID && $0.turnID == reference.turnID }),
                  state.readStatus == .complete,
                  state.rootTurnID == root.turnID,
                  (state.rootThreadID ?? state.requestedThreadID) == root.threadID,
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
        id: UUID, task: ActivityTask
    ) {
        // 缺少子 Agent 身份时不能把主线程小计展示为整项任务总量
        guard !task.executions.keys.contains(where: \.isUnattributed) else { return }
        terminalTokenUsageRequests[id] = tokenUsageRequest(for: task)
    }

    private func tokenUsageRequest(
        for task: ActivityTask
    ) -> TaskTokenRequest {
        let root = task.turnReference
        var references: Set = [root]
        references.formUnion(subagentTurnLinks.filter { $0.value.root == task.key }.map(\.key))
        for owner in task.executions.keys {
            guard let agent = owner.agentID, let turn = owner.turnID else { continue }
            references.insert(ActivityTurnReference(threadID: agent, turnID: turn))
        }
        return TaskTokenRequest(
            root: root, expectedAgentIDs: Set(task.subagentsByID.keys),
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

    @discardableResult
    func applyActiveTokenUsage(_ states: [SessionLifecycleState]) -> Bool {
        var changed = false
        for (key, var task) in tasks {
            let request = tokenUsageRequest(for: task)
            // 运行中汇总已明确归属的累计用量, 尚未产生记录的线程不伪造零值
            let usage = request.usage(from: states, requiresFinalUsage: false)
            guard task.tokenUsage != usage else { continue }
            task.tokenUsage = usage
            tasks[key] = task
            changed = true
        }
        return changed
    }

    /// 完成卡片保留期间继续补齐用量, 轮次终态可能先于最后一条用量更新
    func terminalTokenUsageReferences() -> [ActivityTurnReference] {
        var references: Set<ActivityTurnReference> = []
        for (id, var request) in terminalTokenUsageRequests {
            let rootKey = ActivityTaskKey(thread: request.root.threadID, turn: request.root.turnID)
            request.references.formUnion(subagentTurnLinks.filter { $0.value.root == rootKey }.map(\.key))
            terminalTokenUsageRequests[id] = request
            references.formUnion(request.references)
        }
        return Array(references)
    }

    @discardableResult
    func applyTerminalTokenUsage(_ states: [SessionLifecycleState]) -> Bool {
        var changed = false
        for (id, var request) in terminalTokenUsageRequests {
            guard states.contains(where: { $0.requestedThreadID == request.root.threadID && $0.turnID == request.root.turnID }) else { continue }
            let rootKey = ActivityTaskKey(thread: request.root.threadID, turn: request.root.turnID)
            request.references.formUnion(subagentTurnLinks.filter { $0.value.root == rootKey }.map(\.key))
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
