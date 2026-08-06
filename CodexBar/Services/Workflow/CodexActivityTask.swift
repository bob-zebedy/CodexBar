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

enum CodexActivityLiveTransition {
    case waitingApproval(CodexActivityTaskKey)
    case completed(CodexActivityCompletion)
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
}

struct CodexActivityTask {
    let displayID: UUID
    let key: CodexActivityTaskKey
    var state: CodexActivityTaskState
    var latestEvent: CodexActivityEvent
    var projectName: String?
    var modelName: String?
    var effort: String?
    var toolName: String?
    var startedAt: Date?
    var stateChangedAt: Date
    var lastActivityAt: Date
    var lastProgressAt: Date
    var progressGeneration: UInt64
    var approvalReviewer: CodexApprovalReviewer?
    var pendingApprovalRequestedAt: Date?
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
        self.state = state
        self.latestEvent = latestEvent
        projectName = event.projectDisplayName
        modelName = event.modelName
        effort = Self.normalizedEffort(event.effort)
        toolName = event.toolName
        self.startedAt = startedAt
        stateChangedAt = event.timestamp
        lastActivityAt = event.timestamp
        lastProgressAt = event.timestamp
        self.progressGeneration = progressGeneration
        approvalReviewer = event.approvalReviewer
        pendingApprovalRequestedAt = nil
        subagentsByID = [:]
        isSubagentCountReliable = startedAt != nil
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
            latestEvent: latestEvent,
            projectName: projectName,
            modelName: modelName,
            effort: effort,
            toolName: toolName,
            startedAt: startedAt,
            stateChangedAt: stateChangedAt,
            showsPreciseDuration: showsPreciseDuration,
            activeSubagentCount: activeSubagentCount
        )
    }

    var turnReference: CodexActivityTurnReference? {
        guard case let .turn(sessionId, turnId) = key else {
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
              case let .turn(sessionId, turnId) = key else {
            return nil
        }
        return CodexActivityPromptReference(sessionId: sessionId, turnId: turnId)
    }

    mutating func mergeMetadata(from event: WorkflowHookEvent) {
        projectName = event.projectDisplayName ?? projectName
        modelName = event.modelName ?? modelName
        _ = mergeEffort(event.effort)
        toolName = event.toolName ?? toolName
        approvalReviewer = event.approvalReviewer ?? approvalReviewer
    }

    mutating func recordProgress(at timestamp: Date) {
        lastActivityAt = max(lastActivityAt, timestamp)
        lastProgressAt = timestamp
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
        at timestamp: Date,
        hasReliableTaskAssociation: Bool
    ) {
        guard hasReliableTaskAssociation, let agentId else {
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
            isRunning: isStarting,
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

    /// 记录审批候选; 返回值只表示任务是否刚刚进入用户等待状态
    mutating func recordApprovalRequest(at requestedAt: Date) -> Bool {
        pendingApprovalRequestedAt = requestedAt
        guard approvalReviewer == .user else {
            return false
        }

        let enteredWaiting = state != .waitingApproval
        confirmPendingApproval()
        return enteredWaiting
    }

    mutating func confirmPendingApproval() {
        guard let requestedAt = pendingApprovalRequestedAt else {
            return
        }
        pendingApprovalRequestedAt = nil
        if state != .waitingApproval {
            state = .waitingApproval
            stateChangedAt = requestedAt
        }
        latestEvent = .approvalRequested
    }
}

struct CodexSubagentObservation {
    let isRunning: Bool
    let timestamp: Date
}
