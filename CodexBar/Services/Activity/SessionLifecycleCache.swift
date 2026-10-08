import Foundation

nonisolated struct ActivityTurnReference: Hashable {
    let threadID: String
    let turnID: String
    let startedAt: Date

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID && lhs.turnID == rhs.turnID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(threadID)
        hasher.combine(turnID)
    }
}

/// 运行状态按线程验证有效期, 已确认终态不随连接或刷新期限失效
actor SessionLifecycleCache {
    private var states: [ActivityTurnReference: SessionLifecycleState] = [:]
    private var verifiedThreads: [String: Date] = [:]

    func replace(_ states: [ActivityTurnReference: SessionLifecycleState], verifiedThreads: [String: Date]) {
        self.states = states
        self.verifiedThreads = verifiedThreads
    }

    func invalidate() {
        verifiedThreads.removeAll()
    }

    func lifecycleStates(for references: [ActivityTurnReference], now: Date = Date()) -> [SessionLifecycleState] {
        let requested = Set(references)
        let childReferences = states.keys.filter { reference in
            guard let state = states[reference], state.parentThreadID != nil,
                  let root = state.rootSessionID, let turn = state.rootTurnID else { return false }
            return requested.contains(ActivityTurnReference(threadID: root, turnID: turn, startedAt: now))
        }
        var result = Array(requested.union(childReferences)).map { reference in
            var state = states[reference] ?? SessionLifecycleState(
                requestedThreadID: reference.threadID, turnID: reference.turnID, startedAt: nil,
                approvalReviewer: nil, effort: nil, lastProgressAt: nil, terminal: nil, readStatus: .notFound
            )
            let verified = verifiedThreads[reference.threadID] ?? .distantPast
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
                guard let root = child.rootSessionID, let turn = child.rootTurnID else { continue }
                for index in result.indices {
                    let parent = result[index]
                    let isRoot = parent.requestedThreadID == root && parent.turnID == turn
                    let isAncestor = parent.requestedThreadID == child.parentThreadID
                        && parent.rootSessionID == root && parent.rootTurnID == turn
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
    var approvalReviewer: ApprovalReviewer?
    var effort: String?
    var lastProgressAt: Date?
    let terminal: SessionTerminalState?
    var readStatus: SessionReadStatus = .complete
    var contextObservedAt: Date?
    var rootTurnID: String?
    var rootSessionID: String?
    var parentThreadID: String?
    var lastExecutionProgressAt: Date?
    var tokenUsage: TokenUsage?
    var isHistoricalTerminal = false
    var isWaitingApproval: Bool?
    var approvalChangedAt: Date?
    var terminalObservedAt: Date?
    var presentation: ActivityLivePresentation?
    var turnStatus: String?
}

nonisolated enum SessionReadStatus {
    case complete
    case unavailable
    case notFound
}

nonisolated enum SessionTerminalState {
    case completed(at: Date?, duration: TimeInterval?)
    case aborted(at: Date?)
}
