import CryptoKit
import Foundation

struct ActivityTaskKey: Hashable {
    let threadID: String
    let turnID: String

    init(thread: String, turn: String) {
        threadID = thread
        turnID = turn
    }

    init?(event: ActivityRecord) {
        guard let threadID = event.threadID, !threadID.isEmpty,
              let turnID = event.turnID, !turnID.isEmpty else { return nil }
        self.init(thread: threadID, turn: turnID)
    }

    var protectionIdentifier: String {
        let value = "turn\u{0}\(threadID)\u{0}\(turnID)"
        // 哈希域固定不随代码命名变化, 避免同一任务生成不同的保护标识
        let data = Data("CodexBar.ActivityProtection.v1\u{0}\(value)".utf8)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum ActivityEventSource {
    case bootstrap
    case live
}

enum ProtectionClearReason {
    case progress
    case thresholdChange
    case terminal
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
    var expiresAt: Date {
        supersededAt.addingTimeInterval(ActivityRetention.window)
    }
}

struct ActivityTask {
    let displayID: UUID
    let key: ActivityTaskKey
    var lifecycleCoverageCheckedAt: Date?
    var terminalFailed = false
    var state: ActivityTaskState
    var projectName: String?
    var modelName: String?
    var effort: String?
    var startedAt: Date?
    var stateChangedAt: Date
    var lastProgressAt: Date
    var progressGeneration: UInt64
    var executions: [ActivityExecutionKey: ActivityExecution] = [:]
    var subagentsByID: [String: SubagentObservation]
    var hasCompleteSubagentCoverage = false
    var tokenUsage: TokenUsage?

    init(
        displayID: UUID,
        key: ActivityTaskKey,
        event: ActivityRecord,
        state: ActivityTaskState,
        startedAt: Date?,
        progressGeneration: UInt64
    ) {
        self.displayID = displayID
        self.key = key
        self.state = state
        projectName = event.projectDisplayName
        modelName = event.model
        effort = Self.normalizedEffort(event.effort)
        self.startedAt = startedAt
        stateChangedAt = event.timestamp
        lastProgressAt = event.timestamp
        self.progressGeneration = progressGeneration
        subagentsByID = [:]
        recordExecutionEvent(event)
    }

    /// 起点可信时返回到 end 的精确耗时, 起点缺失或晚于 end 时为 nil
    func preciseDuration(until end: Date) -> TimeInterval? {
        guard let startedAt, end >= startedAt else {
            return nil
        }
        return end.timeIntervalSince(startedAt)
    }

    var snapshot: ActivityTaskSnapshot {
        ActivityTaskSnapshot(
            id: displayID,
            projectName: projectName,
            modelName: modelName,
            effort: effort,
            startedAt: startedAt,
            stateChangedAt: stateChangedAt,
            activeSubagentCount: activeSubagentCount,
            tokenUsage: tokenUsage,
            approvalActionText: displayedApproval?.actionText,
            presentation: livePresentation
        )
    }

    private var livePresentation: ActivityLiveSummary? {
        let live = executions.filter { !$0.value.isTerminal }.compactMap { key, value in
            value.presentation.map { (key, $0.summary) }
        }
        guard !live.isEmpty else { return nil }
        let waiting = live.filter { $0.1.waiting != nil }.min { ($0.1.waiting?.since ?? .distantFuture) < ($1.1.waiting?.since ?? .distantFuture) }
        let root = live.first { $0.0.agentID == nil }
        var result = (waiting ?? root ?? live.max { $0.1.updatedAt < $1.1.updatedAt })!.1
        result.recent = live.compactMap(\.1.recent).max { $0.at < $1.at }
        result.toolCount = live.allSatisfy { $0.1.toolCount != nil } ? live.reduce(0) { $0 + ($1.1.toolCount ?? 0) } : nil
        return result
    }

    var turnReference: ActivityTurnReference {
        ActivityTurnReference(
            threadID: key.threadID,
            turnID: key.turnID
        )
    }

    var lastActivityAt: Date {
        lastProgressAt
    }

    func hasFreshLifecycle(at now: Date) -> Bool {
        lifecycleCoverageCheckedAt.map { now.timeIntervalSince($0) < 5 } == true
    }

    mutating func recordLifecycleRead(_ state: SessionLifecycleState, at now: Date) {
        lifecycleCoverageCheckedAt = state.readStatus == .complete ? now : nil
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
        if event.agentID == nil {
            projectName = event.projectDisplayName ?? projectName
            modelName = event.model ?? modelName
        }
        _ = mergeEffort(event.effort)
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
            hasCompleteSubagentCoverage = false
            return
        }

        let previous = subagentsByID[agentID]
        if let previous, timestamp < previous.timestamp {
            return
        }
        if !isStarting, previous == nil {
            hasCompleteSubagentCoverage = false
        }
        subagentsByID[agentID] = SubagentObservation(
            isRunning: isStarting && !hasEnded,
            timestamp: timestamp
        )
    }

    private var activeSubagentCount: Int? {
        guard hasCompleteSubagentCoverage else {
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
        executions.values.compactMap(\.approval).min {
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
        executions[owner] = execution
    }

    mutating func resumeExecution(from event: ActivityRecord) {
        recordExecutionEvent(event)
        refreshApprovalState(at: event.timestamp, restoresRunning: true)
    }

    mutating func recordApprovalRequest(from event: ActivityRecord) -> Bool {
        let wasWaiting = state == .waitingApproval
        let owner = executionKey(for: event)
        recordExecutionEvent(event)
        if executions[owner]?.approval == nil {
            executions[owner]?.approval = ActivityApproval(
                requestedAt: event.timestamp, toolName: event.toolName, sequence: progressGeneration,
                itemType: event.context?.itemType, commandActionTypes: event.commandActionTypes
            )
        }
        refreshApprovalState(at: event.timestamp)
        return !wasWaiting && state == .waitingApproval
    }

    mutating func mergeExecutionLifecycle(_ lifecycle: SessionLifecycleState, owner: ActivityExecutionKey) {
        guard lifecycle.readStatus == .complete else { return }
        var execution = executions[owner] ?? ActivityExecution()
        execution.presentation = lifecycle.presentation
        executions[owner] = execution
        if lifecycle.terminal != nil {
            finishExecution(owner, at: lifecycle.lastProgressAt ?? lastProgressAt)
        } else {
            if let waiting = lifecycle.isWaitingApproval, let changedAt = lifecycle.approvalChangedAt {
                var execution = executions[owner] ?? ActivityExecution()
                if waiting {
                    let approval = lifecycle.pendingApprovals.min {
                        if $0.value.requestedAt != $1.value.requestedAt {
                            return $0.value.requestedAt < $1.value.requestedAt
                        }
                        return $0.key < $1.key
                    }?.value ?? ActivityApproval(
                        requestedAt: changedAt, toolName: nil, sequence: progressGeneration
                    )
                    execution.approval = approval
                } else {
                    execution.approval = nil
                }
                executions[owner] = execution
                refreshApprovalState(at: changedAt)
            }
        }
    }

    mutating func finishExecution(_ owner: ActivityExecutionKey, at timestamp: Date) {
        var execution = executions[owner] ?? ActivityExecution()
        execution.approval = nil
        execution.isTerminal = true
        execution.presentation = nil
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
}

nonisolated struct ActivityApproval {
    let requestedAt: Date
    let toolName: String?
    let sequence: UInt64
    var itemType: String?
    var commandActionTypes: [String]?

    var actionText: String? {
        ActivityDisplayFormat.toolActionText(itemType: itemType, toolName: toolName, commandActionTypes: commandActionTypes)
    }
}

struct ActivityExecution {
    var lastEventAt: Date = .distantPast
    var approval: ActivityApproval?
    var isTerminal = false
    var presentation: ActivityLivePresentation?
}

struct SubagentObservation {
    let isRunning: Bool
    let timestamp: Date
}
