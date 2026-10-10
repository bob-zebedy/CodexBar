import Foundation

/// 协议适配后的输入, 状态处理只依赖 kind, 原方法名称只用于来源诊断
nonisolated struct ActivityInput {
    enum Category { case state, progress, presentation, ignored }

    enum Kind: String {
        case threadDiscovered
        case threadStatusChanged
        case usageUpdated
        case turnStarted
        case turnFinished
        case itemStarted
        case itemFinished
        case commandApprovalRequested
        case fileApprovalRequested
        case permissionsRequested
        case requestResolved
        case replyProgress
        case reasoningProgress
        case reasoningSummaryProgress
        case commandProgress
        case inputRequested
        case planChanged
        case diffChanged
        case modelChanged
        case verificationRequested
        case authRecoveryStarted
        case authRecoveryFinished
        case safetyBufferingChanged
        case hookStarted
        case hookFinished
        case errorReported
        case ignored

        var category: Category {
            switch self {
            case .threadDiscovered, .threadStatusChanged, .usageUpdated, .turnStarted, .turnFinished, .itemStarted, .itemFinished,
                 .commandApprovalRequested, .fileApprovalRequested, .permissionsRequested, .requestResolved: .state
            case .replyProgress, .reasoningProgress, .reasoningSummaryProgress, .commandProgress: .progress
            case .inputRequested, .planChanged, .diffChanged, .modelChanged, .verificationRequested,
                 .authRecoveryStarted, .authRecoveryFinished, .safetyBufferingChanged, .hookStarted, .hookFinished, .errorReported: .presentation
            case .ignored: .ignored
            }
        }
    }

    let id: String?
    let kind: Kind
    let provenanceMethod: String
    let params: Params
    let live: ActivityLiveContext

    struct Params {
        var threadId: String?
        var turnId: String?
        var itemId: String?
        var approvalId: String?
        var requestId: String?
        var thread: ActivityThread?
        var turn: ActivityTurn?
        var item: ActivityItem?
        var status: ActivityThreadStatus?
        var startedAt: Date?
        var completedAt: Date?
        var tokenUsage: ActivityTokenUpdate?
        var commandActions: [ActivityItem.CommandAction]?
    }
}

nonisolated enum ActivityTurnStatus: String, Codable {
    case running, completed, failed, interrupted, unknown
    var isTerminal: Bool {
        self == .completed || self == .failed || self == .interrupted
    }
}

nonisolated struct ActivityThread {
    let id: String
    var cwd: String?
    var model: String?
    var reasoningEffort: String?
    var status: ActivityThreadStatus?
    var origin: ActivityOrigin = .unknown
    var parentID: String?
    var createdAt: Date?
}

nonisolated struct ActivityThreadStatus {
    enum State: String { case active, idle, notLoaded, unknown }
    enum Flag: String { case waitingOnApproval, waitingOnUserInput, unknown }
    let type: State
    var activeFlags: [Flag]?
    var isWaiting: Bool {
        activeFlags?.contains(.waitingOnApproval) == true
    }
}

nonisolated struct ActivityTurn {
    let id: String
    let status: ActivityTurnStatus
    var rootTurnId: String?
    var items: [ActivityItem]?
    var startedAt: Date?
    var completedAt: Date?
    var duration: TimeInterval?
}

nonisolated struct ActivityItem {
    enum ItemType: String, Codable {
        case commandExecution, fileChange, webSearch, imageView, imageGeneration, sleep
        case mcpToolCall, dynamicToolCall, collabAgentToolCall, contextCompaction, subAgentActivity
        case agentMessage, reasoning, enteredReviewMode, exitedReviewMode, unknown
    }

    struct CommandAction { let type: String }
    struct WebAction { var type: String? }
    struct AgentState { var status: String? }
    let id: String
    let type: ItemType
    var status: String?
    var tool: String?
    var server: String?
    var agentThreadId: String?
    var kind: String?
    var model: String?
    var reasoningEffort: String?
    var commandActions: [CommandAction]?
    var phase: String?
    var action: WebAction?
    var success: Bool?
    var agentsStates: [String: AgentState]?
    var isToolCall: Bool {
        Self.isToolType(type)
    }

    static func isToolType(_ type: ItemType) -> Bool {
        switch type {
        case .commandExecution, .fileChange, .webSearch, .imageView, .imageGeneration, .sleep,
             .mcpToolCall, .dynamicToolCall, .collabAgentToolCall: true
        default: false
        }
    }
}

nonisolated struct ActivityTokenUpdate {
    let total: TokenUsage
    let last: TokenUsage
}

nonisolated struct ActivityLiveContext {
    enum InputMode { case form, external, verification, service }
    enum HookOutcome: String { case completed, failed, blocked, stopped, unknown }
    struct Hook {
        let id: String
        let status: HookOutcome?
        let isSynchronous: Bool
    }

    let inputMode: InputMode
    let planCompleted: Int?
    let planTotal: Int?
    let run: Hook?
    let isSafetyBuffering: Bool
    let willRetry: Bool?
    let fromModel: String?
    let toModel: String?
    let requiresVerification: Bool
}

nonisolated extension ActivityItem {
    static func isObservedType(_ type: ItemType) -> Bool {
        isToolType(type) || [
            .contextCompaction, .subAgentActivity, .agentMessage, .reasoning, .enteredReviewMode, .exitedReviewMode
        ].contains(type)
    }
}
