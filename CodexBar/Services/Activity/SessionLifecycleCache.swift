import Foundation

nonisolated struct ActivityTurnReference: Hashable {
    let threadID: String
    let turnID: String
}

/// 运行状态按轮次验证有效期, 已确认终态不随连接或刷新期限失效
actor SessionLifecycleCache {
    private var states: [ActivityTurnReference: SessionLifecycleState] = [:]
    private var verifiedTurns: [ActivityTurnReference: Date] = [:]

    func replace(_ states: [ActivityTurnReference: SessionLifecycleState], verifiedTurns: [ActivityTurnReference: Date]) {
        self.states = states
        self.verifiedTurns = verifiedTurns
    }

    func invalidate() {
        verifiedTurns.removeAll()
    }

    func lifecycleStates(for references: [ActivityTurnReference], now: Date = Date()) -> [SessionLifecycleState] {
        let requested = Set(references)
        let childReferences = SessionLifecycleState.subagentStates(for: requested, in: Array(states.values)).map {
            ActivityTurnReference(threadID: $0.requestedThreadID, turnID: $0.turnID)
        }
        var result = Array(requested.union(childReferences)).map { reference in
            var state = states[reference] ?? SessionLifecycleState(
                requestedThreadID: reference.threadID, turnID: reference.turnID, startedAt: nil,
                effort: nil, lastProgressAt: nil, terminal: nil, readStatus: .notFound
            )
            let verified = verifiedTurns[reference] ?? .distantPast
            // 已确认终态是事实, 不依赖运行状态的刷新期限
            if state.terminal == nil, now.timeIntervalSince(verified) > 15 {
                state.readStatus = .unavailable
            }
            return state
        }
        var changed = true
        while changed {
            changed = false
            for child in result where child.terminal == nil && child.readStatus != .complete {
                guard let root = child.rootThreadID, let turn = child.rootTurnID else { continue }
                for index in result.indices {
                    let parent = result[index]
                    let isRoot = parent.requestedThreadID == root && parent.turnID == turn
                    let isAncestor = parent.requestedThreadID == child.parentThreadID
                        && parent.rootThreadID == root && parent.rootTurnID == turn
                    if isRoot || isAncestor, parent.terminal == nil, parent.readStatus == .complete {
                        result[index].readStatus = .unavailable
                        changed = true
                    }
                }
            }
        }
        return result
    }
}

nonisolated struct SessionLifecycleState {
    let requestedThreadID: String
    let turnID: String
    let startedAt: Date?
    var effort: String?
    var lastProgressAt: Date?
    let terminal: SessionTerminalState?
    var readStatus: SessionReadStatus = .complete
    var contextObservedAt: Date?
    var rootTurnID: String?
    var rootThreadID: String?
    var parentThreadID: String?
    var tokenUsage: TokenUsage?
    var isHistoricalTerminal = false
    var isWaitingApproval: Bool?
    var approvalChangedAt: Date?
    var pendingApprovals: [String: ActivityApproval] = [:]
    var terminalObservedAt: Date?
    var presentation: ActivityLivePresentation?
    var turnStatus: ActivityTurnStatus?

    /// 保留父线程已知但根轮次尚未确定的子任务, 不能把这部分缺口当成零
    static func subagentStates(for roots: Set<ActivityTurnReference>, in states: [Self]) -> [Self] {
        var result: [ActivityTurnReference: Self] = [:]
        for root in roots {
            let matching = states.filter { state in
                state.parentThreadID != nil && state.rootThreadID == root.threadID && state.rootTurnID == root.turnID
            }
            var threads = Set(matching.map(\.requestedThreadID)).union([root.threadID])
            var unresolved = states.filter { state in
                (state.rootThreadID == nil || state.rootTurnID == nil)
                    && (state.rootThreadID == nil || state.rootThreadID == root.threadID)
                    && (state.rootTurnID == nil || state.rootTurnID == root.turnID)
            }
            for state in matching {
                result[ActivityTurnReference(threadID: state.requestedThreadID, turnID: state.turnID)] = state
            }
            while true {
                let children = unresolved.filter { $0.parentThreadID.map(threads.contains) == true }
                guard !children.isEmpty else { break }
                for state in children {
                    result[ActivityTurnReference(threadID: state.requestedThreadID, turnID: state.turnID)] = state
                }
                let parents = threads
                unresolved.removeAll { $0.parentThreadID.map(parents.contains) == true }
                threads.formUnion(children.map(\.requestedThreadID))
            }
        }
        return Array(result.values)
    }
}

nonisolated enum SessionReadStatus {
    case complete
    case unavailable
    case notFound
}

nonisolated enum SessionTerminalState {
    case completed(at: Date?, duration: TimeInterval?)
    case aborted(at: Date?, duration: TimeInterval?)
}
