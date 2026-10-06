import CryptoKit
import Foundation

enum ActivityTaskKey: Hashable {
    case turn(session: String, turn: String)
    case session(String)
    case anonymous(project: String)

    init(event: ActivityRecord) {
        if let sessionID = event.sessionID, let turnID = event.turnID {
            self = .turn(session: sessionID, turn: turnID)
        } else if let sessionID = event.sessionID {
            self = .session(sessionID)
        } else {
            self = .anonymous(project: Self.projectIdentifier(event.projectDisplayName))
        }
    }

    var sessionID: String? {
        switch self {
        case let .turn(session, _), let .session(session): session
        case .anonymous: nil
        }
    }

    var turnID: String? {
        if case let .turn(_, turn) = self {
            return turn
        }
        return nil
    }

    var isAnonymous: Bool {
        if case .anonymous = self {
            return true
        }
        return false
    }

    var isSessionOnly: Bool {
        if case .session = self {
            return true
        }
        return false
    }

    var protectionIdentifier: String? {
        let value: String
        switch self {
        case let .turn(session, turn):
            value = "turn\u{0}\(session)\u{0}\(turn)"
        case let .session(session):
            value = "session\u{0}\(session)"
        case .anonymous:
            return nil
        }
        // 哈希域固定不随代码命名变化, 避免同一任务生成不同的保护标识
        let data = Data("CodexBar.ActivityProtection.v1\u{0}\(value)".utf8)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func projectIdentifier(_ project: String?) -> String {
        project ?? "__codex__"
    }
}

enum ActivityEventSource {
    case bootstrap
    case live
}

enum TerminalTaskMatch {
    case active(ActivityTaskKey)
    case pending(ActivityTaskKey)
    case ambiguous
    case none
}

enum ProtectionClearReason {
    case progress
    case thresholdChange
    case terminal
    case retention
}

struct ProtectionCandidate {
    let key: ActivityTaskKey
    let taskID: UUID
    let projectName: String?
    let lastProgressAt: Date
    let progressGeneration: UInt64
    let inactivityDuration: ProtectionSettings.InactivityDuration
}

struct ProtectionAttempt {
    let id: UUID
    let candidate: ProtectionCandidate
    let markedAt: Date
    let timeoutTask: Task<Void, Never>
}

enum ActivityTaskState: Equatable {
    case running
    case waitingApproval
    case suppressed
}

struct PendingTerminalTask {
    var task: ActivityTask
    let supersededAt: Date
    let deadline: Date
    var nextPollAt: Date = .distantPast
    var expiresAt: Date {
        supersededAt.addingTimeInterval(ActivityRetention.window)
    }
}

struct ActivityTask {
    let displayID: UUID
    let key: ActivityTaskKey
    var associatedTurnID: String?
    var lifecycleCoverageCheckedAt: Date?
    var state: ActivityTaskState
    var latestEvent: ActivityPhase
    var projectName: String?
    var modelName: String?
    var effort: String?
    var toolName: String?
    var itemType: String?
    var startedAt: Date?
    var stateChangedAt: Date
    var lastEventAt: Date
    var lastProgressAt: Date
    var progressGeneration: UInt64
    var executions: [ActivityExecutionKey: ActivityExecution] = [:]
    var subagentsByID: [String: SubagentObservation]
    var isSubagentCountReliable: Bool
    var tokenUsage: TokenUsage?

    init(
        displayID: UUID,
        key: ActivityTaskKey,
        event: ActivityRecord,
        state: ActivityTaskState,
        latestEvent: ActivityPhase,
        startedAt: Date?,
        progressGeneration: UInt64
    ) {
        self.displayID = displayID
        self.key = key
        associatedTurnID = key.turnID
        self.state = state
        self.latestEvent = latestEvent
        projectName = event.projectDisplayName
        modelName = event.model
        effort = Self.normalizedEffort(event.effort)
        toolName = event.tool
        itemType = event.source?.itemType
        self.startedAt = startedAt
        stateChangedAt = event.timestamp
        lastEventAt = event.timestamp
        lastProgressAt = event.timestamp
        self.progressGeneration = progressGeneration
        subagentsByID = [:]
        isSubagentCountReliable = startedAt != nil
        recordExecutionEvent(event)
    }

    var showsPreciseDuration: Bool {
        startedAt != nil && !key.isAnonymous
    }

    /// 起点可信时返回到 end 的精确耗时, 起点缺失或晚于 end 时为 nil
    func preciseDuration(until end: Date) -> TimeInterval? {
        guard showsPreciseDuration, let startedAt, end >= startedAt else {
            return nil
        }
        return end.timeIntervalSince(startedAt)
    }

    var snapshot: ActivityTaskSnapshot {
        ActivityTaskSnapshot(
            id: displayID,
            isAnonymous: key.isAnonymous,
            latestEvent: displayedApproval == nil ? latestEvent : .approvalRequested,
            projectName: projectName,
            modelName: modelName,
            effort: effort,
            toolName: displayedApproval.map(\.toolName) ?? toolName,
            startedAt: startedAt,
            stateChangedAt: stateChangedAt,
            showsPreciseDuration: showsPreciseDuration,
            activeSubagentCount: activeSubagentCount,
            tokenUsage: tokenUsage,
            itemType: displayedApproval.map(\.itemType) ?? itemType
        )
    }

    var turnReference: ActivityTurnReference? {
        guard let sessionID = key.sessionID, let turnID = associatedTurnID else {
            return nil
        }
        return ActivityTurnReference(
            threadID: sessionID,
            turnID: turnID,
            startedAt: startedAt ?? lastActivityAt
        )
    }

    var promptReference: ActivityPromptReference? {
        guard startedAt == nil,
              let sessionID = key.sessionID, let turnID = associatedTurnID else {
            return nil
        }
        return ActivityPromptReference(sessionID: sessionID, turnID: turnID)
    }

    var resolvedTurnKey: ActivityTaskKey? {
        guard let session = key.sessionID, let turn = associatedTurnID else { return nil }
        return .turn(session: session, turn: turn)
    }

    var lastActivityAt: Date {
        lastProgressAt
    }

    func hasFreshLifecycle(at now: Date) -> Bool {
        lifecycleCoverageCheckedAt.map { now.timeIntervalSince($0) < 5 } == true
    }

    mutating func recordLifecycleRead(_ state: SessionLifecycleState, at now: Date) {
        lifecycleCoverageCheckedAt = state.readStatus == .complete && state.hasContext ? now : nil
    }

    /// 阈值调整与隐藏共用计时起点, 恢复不要求读取结果仍在有效期内
    var protectionReferenceAt: Date {
        lastProgressAt
    }

    /// 隐藏还要求 Codex 后台服务提供的新鲜生命周期覆盖
    func protectionDeadline(at now: Date, inactivityDuration: TimeInterval) -> Date? {
        guard hasFreshLifecycle(at: now) else { return nil }
        return protectionReferenceAt.addingTimeInterval(inactivityDuration)
    }

    mutating func mergeMetadata(from event: ActivityRecord) {
        if associatedTurnID == nil, !key.isAnonymous, event.agentID == nil {
            associatedTurnID = event.turnID
        }
        projectName = event.projectDisplayName ?? projectName
        modelName = event.model ?? modelName
        _ = mergeEffort(event.effort)
        switch event.eventKind {
        case .toolStarted, .toolCompleted, .approvalRequested:
            toolName = event.tool
            itemType = event.source?.itemType
        default:
            break
        }
    }

    /// 业务事件顺序独立于执行进展, 避免用量记录使稍早的状态事件失效
    mutating func recordEvent(at timestamp: Date) {
        lastEventAt = max(lastEventAt, timestamp)
        recordProgress(at: timestamp)
    }

    mutating func recordProgress(at timestamp: Date) {
        lastProgressAt = max(lastProgressAt, timestamp)
        progressGeneration &+= 1
    }

    @discardableResult
    mutating func mergeEffort(_ incomingEffort: String?) -> Bool {
        guard let incomingEffort = Self.normalizedEffort(incomingEffort) else {
            return false
        }
        guard let effort else {
            effort = incomingEffort
            return true
        }
        guard effort != incomingEffort, effort != "mixed" else {
            return false
        }
        self.effort = "mixed"
        return true
    }

    mutating func recordSubagentActivity(
        agentID: String?,
        isStarting: Bool,
        hasEnded: Bool = false,
        at timestamp: Date
    ) {
        guard let agentID else {
            isSubagentCountReliable = false
            return
        }

        let previous = subagentsByID[agentID]
        if let previous, timestamp < previous.timestamp {
            return
        }
        if !isStarting, previous == nil {
            isSubagentCountReliable = false
        }
        subagentsByID[agentID] = SubagentObservation(
            isRunning: isStarting && !hasEnded,
            timestamp: timestamp
        )
    }

    private var activeSubagentCount: Int? {
        guard isSubagentCountReliable else {
            return nil
        }
        return subagentsByID.values.reduce(into: 0) { count, observation in
            if observation.isRunning {
                count += 1
            }
        }
    }

    private static func normalizedEffort(_ effort: String?) -> String? {
        guard let effort else {
            return nil
        }
        let value = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var displayedApproval: ActivityApproval? {
        executions.values.compactMap { execution -> ActivityApproval? in
            guard case let .waiting(approval)? = execution.approval else { return nil }
            return approval
        }.min {
            if $0.requestedAt != $1.requestedAt {
                return $0.requestedAt < $1.requestedAt
            }
            return $0.sequence < $1.sequence
        }
    }

    func executionKey(for event: ActivityRecord) -> ActivityExecutionKey {
        ActivityExecutionKey(
            agentID: event.agentID,
            turnID: event.turnID,
            isUnattributed: event.agentID == nil && event.origin != .main
        )
    }

    var lastMainEventAt: Date {
        executions.filter { $0.key.agentID == nil && !$0.key.isUnattributed }
            .values.map(\.lastEventAt).max() ?? startedAt ?? .distantPast
    }

    func acceptsExecutionEvent(_ event: ActivityRecord) -> Bool {
        let execution = executions[executionKey(for: event)]
        return execution?.isTerminal != true && event.timestamp >= (execution?.lastEventAt ?? .distantPast)
    }

    mutating func recordExecutionEvent(_ event: ActivityRecord) {
        let owner = executionKey(for: event)
        var execution = executions[owner] ?? ActivityExecution()
        execution.lastEventAt = max(execution.lastEventAt, event.timestamp)
        execution.mergeReviewer(event.approvalReviewer, at: event.timestamp)
        executions[owner] = execution
    }

    mutating func resumeExecution(from event: ActivityRecord, latestEvent: ActivityPhase) {
        recordExecutionEvent(event)
        let owner = executionKey(for: event)
        if owner.isReliable, var execution = executions[owner] {
            execution.approval = nil
            execution.lastExecutionProgressAt = max(execution.lastExecutionProgressAt ?? .distantPast, event.timestamp)
            executions[owner] = execution
        }
        self.latestEvent = latestEvent
        refreshApprovalState(at: event.timestamp, restoresRunning: true)
    }

    /// 审批路由未知时只保存候选, 后续上下文只能确认同一执行归属
    mutating func recordApprovalRequest(from event: ActivityRecord) -> Bool {
        let wasWaiting = state == .waitingApproval
        let owner = executionKey(for: event)
        guard event.timestamp > (executions[owner]?.lastApprovalRequestedAt ?? .distantPast),
              event.timestamp >= (executions[owner]?.lastExecutionProgressAt ?? .distantPast) else { return false }
        recordExecutionEvent(event)
        executions[owner]?.lastApprovalRequestedAt = event.timestamp
        if executions[owner]?.approval == nil {
            executions[owner]?.approval = .pending(ActivityApproval(
                requestedAt: event.timestamp, toolName: event.tool, sequence: progressGeneration,
                itemType: event.source?.itemType
            ))
        }
        _ = resolvePendingApprovals()
        return !wasWaiting && state == .waitingApproval
    }

    @discardableResult
    mutating func resolvePendingApprovals() -> Bool {
        var changed = false
        for owner in executions.keys {
            guard var execution = executions[owner], case let .pending(pending)? = execution.approval,
                  let reviewer = execution.approvalReviewer else { continue }
            execution.approval = reviewer == .user ? .waiting(pending) : nil
            executions[owner] = execution
            changed = true
        }
        if changed {
            refreshApprovalState(at: displayedApproval?.requestedAt ?? lastProgressAt)
        }
        return changed
    }

    mutating func mergeApprovalContext(
        reviewer: ApprovalReviewer?, observedAt: Date?, owner: ActivityExecutionKey
    ) {
        guard let observedAt else { return }
        var execution = executions[owner] ?? ActivityExecution()
        execution.mergeReviewer(reviewer, at: observedAt)
        executions[owner] = execution
    }

    mutating func mergeExecutionLifecycle(_ lifecycle: SessionLifecycleState, owner: ActivityExecutionKey) {
        guard lifecycle.readStatus == .complete else { return }
        if lifecycle.terminal != nil {
            finishExecution(owner, at: lifecycle.lastProgressAt ?? lastProgressAt)
        } else {
            mergeApprovalContext(reviewer: lifecycle.approvalReviewer, observedAt: lifecycle.contextObservedAt, owner: owner)
            mergeExecutionProgress(at: lifecycle.lastExecutionProgressAt, owner: owner)
            if let waiting = lifecycle.isWaitingApproval, let changedAt = lifecycle.approvalChangedAt {
                var execution = executions[owner] ?? ActivityExecution()
                if waiting {
                    let approval = execution.approval?.request ?? ActivityApproval(
                        requestedAt: changedAt, toolName: nil, sequence: progressGeneration
                    )
                    execution.approval = .waiting(approval)
                } else {
                    execution.approval = nil
                }
                executions[owner] = execution
                refreshApprovalState(at: changedAt)
            }
        }
    }

    mutating func mergeExecutionProgress(at timestamp: Date?, owner: ActivityExecutionKey) {
        guard owner.isReliable, let timestamp else { return }
        var execution = executions[owner] ?? ActivityExecution()
        execution.lastExecutionProgressAt = max(execution.lastExecutionProgressAt ?? .distantPast, timestamp)
        if let approval = execution.approval, timestamp > approval.request.requestedAt {
            execution.approval = nil
        }
        executions[owner] = execution
        refreshApprovalState(at: timestamp)
    }

    mutating func finishExecution(_ owner: ActivityExecutionKey, at timestamp: Date) {
        var execution = executions[owner] ?? ActivityExecution()
        execution.approval = nil
        execution.isTerminal = true
        executions[owner] = execution
        refreshApprovalState(at: timestamp)
    }

    private mutating func refreshApprovalState(at timestamp: Date, restoresRunning: Bool = false) {
        if let approval = displayedApproval {
            if state != .waitingApproval {
                state = .waitingApproval
                stateChangedAt = approval.requestedAt
            }
        } else if state == .waitingApproval || restoresRunning {
            if state != .running {
                state = .running
                stateChangedAt = timestamp
            }
        }
    }
}

struct ActivityExecutionKey: Hashable {
    let agentID: String?
    let turnID: String?
    var isUnattributed = false

    var isReliable: Bool {
        turnID != nil && !isUnattributed
    }
}

struct ActivityApproval {
    let requestedAt: Date
    let toolName: String?
    let sequence: UInt64
    var itemType: String?
}

enum ActivityApprovalState {
    case pending(ActivityApproval)
    case waiting(ActivityApproval)

    var request: ActivityApproval {
        switch self {
        case let .pending(request), let .waiting(request): request
        }
    }
}

struct ActivityExecution {
    var lastEventAt: Date = .distantPast
    var approvalReviewer: ApprovalReviewer?
    var approvalContextObservedAt: Date?
    var lastExecutionProgressAt: Date?
    var lastApprovalRequestedAt: Date?
    var approval: ActivityApprovalState?
    var isTerminal = false

    mutating func mergeReviewer(_ reviewer: ApprovalReviewer?, at timestamp: Date) {
        guard let reviewer, timestamp >= (approvalContextObservedAt ?? .distantPast) else { return }
        approvalReviewer = reviewer
        approvalContextObservedAt = timestamp
    }
}

struct SubagentObservation {
    let isRunning: Bool
    let timestamp: Date
}
