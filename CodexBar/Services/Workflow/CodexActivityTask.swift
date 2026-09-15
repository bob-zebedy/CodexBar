import CryptoKit
import Foundation

enum CodexActivityTaskKey: Hashable {
    case turn(session: String, turn: String)
    case session(String)
    case anonymous(project: String)

    init(event: WorkflowHookEvent) {
        if let sessionId = event.sessionId, let turnId = event.turnId {
            self = .turn(session: sessionId, turn: turnId)
        } else if let sessionId = event.sessionId {
            self = .session(sessionId)
        } else {
            self = .anonymous(project: Self.projectIdentifier(event.projectDisplayName))
        }
    }

    var sessionId: String? {
        switch self {
        case let .turn(session, _), let .session(session): session
        case .anonymous: nil
        }
    }

    var turnId: String? {
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

    var activityProtectionIdentifier: String? {
        let value: String
        switch self {
        case let .turn(session, turn):
            value = "turn\u{0}\(session)\u{0}\(turn)"
        case let .session(session):
            value = "session\u{0}\(session)"
        case .anonymous:
            return nil
        }
        let data = Data("CodexBar.ActivityProtection.v1\u{0}\(value)".utf8)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func projectIdentifier(_ project: String?) -> String {
        project ?? "__codex__"
    }
}

enum CodexActivityEventSource {
    case bootstrap
    case live
}

enum CodexTerminalTaskMatch {
    case active(CodexActivityTaskKey)
    case pending(CodexActivityTaskKey)
    case ambiguous
    case none
}

enum ActivityProtectionClearReason {
    case progress
    case thresholdChange
    case terminal
    case retention
}

struct ActivityProtectionCandidate {
    let key: CodexActivityTaskKey
    let taskID: UUID
    let projectName: String?
    let lastProgressAt: Date
    let progressGeneration: UInt64
    let inactivityDuration: ActivityProtectionSettings.InactivityDuration
}

struct ActivityProtectionAttempt {
    let id: UUID
    let candidate: ActivityProtectionCandidate
    let markedAt: Date
    let timeoutTask: Task<Void, Never>
}

enum CodexActivityTaskState: Equatable {
    case running
    case waitingApproval
    case suppressed
}

struct PendingTerminalTask {
    var task: CodexActivityTask
    let supersededAt: Date
    let deadline: Date
    var nextPollAt: Date = .distantPast
    var expiresAt: Date {
        supersededAt.addingTimeInterval(CodexActivityRetention.window)
    }
}

struct CodexActivityTask {
    let displayID: UUID
    let key: CodexActivityTaskKey
    var associatedTurnId: String?
    var lifecycleCoverageCheckedAt: Date?
    var state: CodexActivityTaskState
    var latestEvent: CodexActivityEvent
    var projectName: String?
    var modelName: String?
    var effort: String?
    var toolName: String?
    var startedAt: Date?
    var stateChangedAt: Date
    var lastHookEventAt: Date
    var lastProgressAt: Date
    var progressGeneration: UInt64
    var executions: [CodexActivityExecutionKey: CodexActivityExecution] = [:]
    var subagentsByID: [String: CodexSubagentObservation]
    var isSubagentCountReliable: Bool

    init(
        displayID: UUID,
        key: CodexActivityTaskKey,
        event: WorkflowHookEvent,
        state: CodexActivityTaskState,
        latestEvent: CodexActivityEvent,
        startedAt: Date?,
        progressGeneration: UInt64
    ) {
        self.displayID = displayID
        self.key = key
        associatedTurnId = key.turnId
        self.state = state
        self.latestEvent = latestEvent
        projectName = event.projectDisplayName
        modelName = event.modelName
        effort = Self.normalizedEffort(event.effort)
        toolName = event.toolName
        self.startedAt = startedAt
        stateChangedAt = event.timestamp
        lastHookEventAt = event.timestamp
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

    var snapshot: CodexActivityTaskSnapshot {
        CodexActivityTaskSnapshot(
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
            activeSubagentCount: activeSubagentCount
        )
    }

    var turnReference: CodexActivityTurnReference? {
        guard let sessionId = key.sessionId, let turnId = associatedTurnId else {
            return nil
        }
        return CodexActivityTurnReference(
            sessionId: sessionId,
            turnId: turnId,
            startedAt: startedAt ?? lastActivityAt
        )
    }

    var promptReference: CodexActivityPromptReference? {
        guard startedAt == nil,
              let sessionId = key.sessionId, let turnId = associatedTurnId else {
            return nil
        }
        return CodexActivityPromptReference(sessionId: sessionId, turnId: turnId)
    }

    var resolvedTurnKey: CodexActivityTaskKey? {
        guard let session = key.sessionId, let turn = associatedTurnId else { return nil }
        return .turn(session: session, turn: turn)
    }

    var lastActivityAt: Date {
        lastProgressAt
    }

    func hasFreshLifecycle(at now: Date) -> Bool {
        lifecycleCoverageCheckedAt.map { now.timeIntervalSince($0) < 5 } == true
    }

    mutating func mergeMetadata(from event: WorkflowHookEvent) {
        if associatedTurnId == nil, !key.isAnonymous, event.agentId == nil {
            associatedTurnId = event.turnId
        }
        projectName = event.projectDisplayName ?? projectName
        modelName = event.modelName ?? modelName
        _ = mergeEffort(event.effort)
        toolName = event.toolName ?? toolName
    }

    /// Hook 顺序独立于 rollout 进展, 避免用量记录使稍早的状态事件失效
    mutating func recordHookEvent(at timestamp: Date) {
        lastHookEventAt = max(lastHookEventAt, timestamp)
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
        agentId: String?,
        isStarting: Bool,
        hasEnded: Bool = false,
        at timestamp: Date
    ) {
        guard let agentId else {
            isSubagentCountReliable = false
            return
        }

        let previous = subagentsByID[agentId]
        if let previous, timestamp < previous.timestamp {
            return
        }
        if !isStarting, previous == nil {
            isSubagentCountReliable = false
        }
        subagentsByID[agentId] = CodexSubagentObservation(
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

    var displayedApproval: CodexActivityApproval? {
        executions.values.compactMap { execution -> CodexActivityApproval? in
            guard case let .waiting(approval)? = execution.approval else { return nil }
            return approval
        }.min {
            if $0.requestedAt != $1.requestedAt {
                return $0.requestedAt < $1.requestedAt
            }
            return $0.sequence < $1.sequence
        }
    }

    func executionKey(for event: WorkflowHookEvent) -> CodexActivityExecutionKey {
        CodexActivityExecutionKey(
            agentId: event.agentId,
            turnId: event.turnId,
            isUnattributed: event.agentId == nil && event.origin != .main
        )
    }

    var lastMainHookEventAt: Date {
        executions.filter { $0.key.agentId == nil && !$0.key.isUnattributed }
            .values.map(\.lastHookEventAt).max() ?? startedAt ?? .distantPast
    }

    func acceptsExecutionEvent(_ event: WorkflowHookEvent) -> Bool {
        let execution = executions[executionKey(for: event)]
        return execution?.isTerminal != true && event.timestamp >= (execution?.lastHookEventAt ?? .distantPast)
    }

    mutating func recordExecutionEvent(_ event: WorkflowHookEvent) {
        let owner = executionKey(for: event)
        var execution = executions[owner] ?? CodexActivityExecution()
        execution.lastHookEventAt = max(execution.lastHookEventAt, event.timestamp)
        execution.mergeReviewer(event.approvalReviewer, at: event.timestamp)
        executions[owner] = execution
    }

    mutating func resumeExecution(from event: WorkflowHookEvent, latestEvent: CodexActivityEvent) {
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
    mutating func recordApprovalRequest(from event: WorkflowHookEvent) -> Bool {
        let wasWaiting = state == .waitingApproval
        let owner = executionKey(for: event)
        guard event.timestamp > (executions[owner]?.lastApprovalRequestedAt ?? .distantPast),
              event.timestamp >= (executions[owner]?.lastExecutionProgressAt ?? .distantPast) else { return false }
        recordExecutionEvent(event)
        executions[owner]?.lastApprovalRequestedAt = event.timestamp
        if executions[owner]?.approval == nil {
            executions[owner]?.approval = .pending(CodexActivityApproval(
                requestedAt: event.timestamp, toolName: event.toolName, sequence: progressGeneration
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
        reviewer: CodexApprovalReviewer?, observedAt: Date?, owner: CodexActivityExecutionKey
    ) {
        guard let observedAt else { return }
        var execution = executions[owner] ?? CodexActivityExecution()
        execution.mergeReviewer(reviewer, at: observedAt)
        executions[owner] = execution
    }

    mutating func mergeExecutionLifecycle(_ lifecycle: CodexSessionTaskLifecycleState, owner: CodexActivityExecutionKey) {
        guard lifecycle.readStatus == .complete else { return }
        if lifecycle.terminal != nil {
            finishExecution(owner, at: lifecycle.lastProgressAt ?? lastProgressAt)
        } else {
            mergeApprovalContext(reviewer: lifecycle.approvalReviewer, observedAt: lifecycle.contextObservedAt, owner: owner)
            mergeExecutionProgress(at: lifecycle.lastExecutionProgressAt, owner: owner)
        }
    }

    mutating func mergeExecutionProgress(at timestamp: Date?, owner: CodexActivityExecutionKey) {
        guard owner.isReliable, let timestamp else { return }
        var execution = executions[owner] ?? CodexActivityExecution()
        execution.lastExecutionProgressAt = max(execution.lastExecutionProgressAt ?? .distantPast, timestamp)
        if let approval = execution.approval, timestamp > approval.request.requestedAt {
            execution.approval = nil
        }
        executions[owner] = execution
        refreshApprovalState(at: timestamp)
    }

    mutating func finishExecution(_ owner: CodexActivityExecutionKey, at timestamp: Date) {
        var execution = executions[owner] ?? CodexActivityExecution()
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

struct CodexActivityExecutionKey: Hashable {
    let agentId: String?
    let turnId: String?
    var isUnattributed = false

    var isReliable: Bool {
        turnId != nil && !isUnattributed
    }
}

struct CodexActivityApproval {
    let requestedAt: Date
    let toolName: String?
    let sequence: UInt64
}

enum CodexActivityApprovalState {
    case pending(CodexActivityApproval)
    case waiting(CodexActivityApproval)

    var request: CodexActivityApproval {
        switch self {
        case let .pending(request), let .waiting(request): request
        }
    }
}

struct CodexActivityExecution {
    var lastHookEventAt: Date = .distantPast
    var approvalReviewer: CodexApprovalReviewer?
    var approvalContextObservedAt: Date?
    var lastExecutionProgressAt: Date?
    var lastApprovalRequestedAt: Date?
    var approval: CodexActivityApprovalState?
    var isTerminal = false

    mutating func mergeReviewer(_ reviewer: CodexApprovalReviewer?, at timestamp: Date) {
        guard let reviewer, timestamp >= (approvalContextObservedAt ?? .distantPast) else { return }
        approvalReviewer = reviewer
        approvalContextObservedAt = timestamp
    }
}

struct CodexSubagentObservation {
    let isRunning: Bool
    let timestamp: Date
}
