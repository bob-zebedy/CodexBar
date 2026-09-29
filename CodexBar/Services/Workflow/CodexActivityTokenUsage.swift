import Foundation

struct CodexTaskTokenUsageRequest {
    let root: CodexActivityTurnReference
    let expectedAgentIDs: Set<String>
    var references: Set<CodexActivityTurnReference>
    let deadline: Date
    var nextReadAt = Date.distantPast

    func usage(from states: [CodexSessionTaskLifecycleState], requiresFinalUsage: Bool = true) -> CodexTokenUsage? {
        let agentIDs = Set(references.filter { $0 != root }.map(\.sessionId))
        guard !requiresFinalUsage || expectedAgentIDs.isSubset(of: agentIDs) else { return nil }
        var total: CodexTokenUsage?
        for reference in references {
            guard let state = states.first(where: { $0.sessionId == reference.sessionId && $0.turnId == reference.turnId }),
                  state.readStatus == .complete, state.threadId == reference.sessionId,
                  state.rootTurnId == root.turnId,
                  (state.rootSessionId ?? state.threadId) == root.sessionId,
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

extension CodexActivityMonitor {
    func registerTerminalTokenUsage(
        id: UUID, key: CodexActivityTaskKey, task: CodexActivityTask?, endedAt: Date, now: Date = Date()
    ) {
        guard let session = key.sessionId, let turn = task?.associatedTurnId ?? key.turnId else { return }
        // 缺少子 Agent 身份时不能把主线程小计展示为整项任务总量
        guard task?.executions.keys.contains(where: \.isUnattributed) != true else { return }
        let root = CodexActivityTurnReference(sessionId: session, turnId: turn, startedAt: task?.startedAt ?? endedAt)
        terminalTokenUsageRequests[id] = tokenUsageRequest(root: root, task: task, deadline: now.addingTimeInterval(30))
    }

    private func tokenUsageRequest(
        root: CodexActivityTurnReference, task: CodexActivityTask?, deadline: Date
    ) -> CodexTaskTokenUsageRequest {
        var references: Set = [root]
        let rootKey = CodexActivityTaskKey.turn(session: root.sessionId, turn: root.turnId)
        references.formUnion(subagentTurnLinks.filter { $0.value == rootKey }.map(\.key))
        if let task {
            for owner in task.executions.keys {
                guard let agent = owner.agentId, let turn = owner.turnId else { continue }
                references.insert(CodexActivityTurnReference(sessionId: agent, turnId: turn, startedAt: root.startedAt))
            }
        }
        return CodexTaskTokenUsageRequest(
            root: root, expectedAgentIDs: Set(task?.subagentsByID.keys.map(\.self) ?? []),
            references: references, deadline: deadline
        )
    }

    func activeTokenUsageReferences() -> [CodexActivityTurnReference] {
        var references: Set<CodexActivityTurnReference> = []
        for task in tasks.values {
            guard let root = task.turnReference else { continue }
            references.formUnion(tokenUsageRequest(root: root, task: task, deadline: .distantFuture).references)
        }
        return Array(references)
    }

    @discardableResult
    func applyActiveTokenUsage(_ states: [CodexSessionTaskLifecycleState]) -> Bool {
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

    /// 结束后有界重读, Interrupt Hook 可能先于最后一条用量落盘
    func terminalTokenUsageReferences(now: Date) -> [CodexActivityTurnReference] {
        terminalTokenUsageRequests = terminalTokenUsageRequests.filter { $0.value.deadline > now }
        let due = terminalTokenUsageRequests.filter { $0.value.nextReadAt <= now }
            .sorted { $0.value.nextReadAt < $1.value.nextReadAt }.prefix(16)
        var references: Set<CodexActivityTurnReference> = []
        for (id, var request) in due {
            let rootKey = CodexActivityTaskKey.turn(session: request.root.sessionId, turn: request.root.turnId)
            request.references.formUnion(subagentTurnLinks.filter { $0.value == rootKey }.map(\.key))
            request.nextReadAt = now.addingTimeInterval(2)
            terminalTokenUsageRequests[id] = request
            references.formUnion(request.references)
        }
        return Array(references)
    }

    @discardableResult
    func applyTerminalTokenUsage(_ states: [CodexSessionTaskLifecycleState]) -> Bool {
        var changed = false
        for (id, var request) in terminalTokenUsageRequests {
            guard states.contains(where: { $0.sessionId == request.root.sessionId && $0.turnId == request.root.turnId }) else { continue }
            let rootKey = CodexActivityTaskKey.turn(session: request.root.sessionId, turn: request.root.turnId)
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
