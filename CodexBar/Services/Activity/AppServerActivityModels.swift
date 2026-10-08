nonisolated struct ActivityThread: Decodable {
    let id: String
    var cwd: String?
    var model: String?
    var reasoningEffort: String?
    var status: ActivityThreadStatus?
    var source: ActivityThreadSource?
    var parentThreadId: String?
    var createdAt: Double?

    var origin: ActivityOrigin {
        source?.origin ?? .unknown
    }

    var parentID: String? {
        parentThreadId ?? source?.parentID
    }
}

nonisolated struct ActivityThreadStatus: Decodable {
    let type: String
    var activeFlags: [String]?
    var isWaiting: Bool {
        activeFlags?.contains("waitingOnApproval") == true
    }
}

nonisolated struct ActivityThreadSource: Decodable {
    let origin: ActivityOrigin
    let parentID: String?

    init(from decoder: Decoder) throws {
        let value = try ActivityJSONValue(from: decoder)
        if let name = value.string {
            origin = ["cli", "vscode", "exec", "appServer"].contains(name) ? .main : .unknown
            parentID = nil
        } else if let subagent = value["subAgent"] ?? value["subagent"] {
            let other = subagent["other"]?.string
            origin = other == "guardian" ? .autoReview : .auxiliary
            parentID = (subagent["thread_spawn"] ?? subagent["threadSpawn"])?["parent_thread_id"]?.string
        } else {
            origin = value["custom"] == nil ? .unknown : .main
            parentID = nil
        }
    }
}

/// 只在协议边界使用, 不将任意 JSON 正文写入日志或持久化
indirect nonisolated enum ActivityJSONValue: Decodable {
    case object([String: ActivityJSONValue])
    case array([ActivityJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            self = try .array(container.decode([Self].self))
        }
    }

    subscript(_ key: String) -> Self? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    var string: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    var number: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }

    var identifier: String? {
        if let string {
            return string
        }
        if let number {
            return String(number)
        }
        return nil
    }
}

nonisolated struct ActivityTurn: Decodable {
    let id: String
    let status: String
    var startedAt: Double?
    var completedAt: Double?
    var durationMs: Double?
}

nonisolated struct ActivityItem: Decodable {
    struct CommandAction: Decodable {
        let type: String
    }

    let id: String
    let type: String
    var status: String?
    var tool: String?
    var agentThreadId: String?
    var kind: String?
    var commandActions: [CommandAction]?
    var phase: String?
    var action: WebAction?
    var success: Bool?
    var agentsStates: [String: AgentState]?

    struct WebAction: Decodable { var type: String? }
    struct AgentState: Decodable { var status: String? }

    var toolDisplayName: String? {
        guard type == "commandExecution" else { return tool }
        var seen: Set<String> = []
        let types = (commandActions ?? []).map(\.type).filter {
            !$0.isEmpty && $0 != "unknown" && seen.insert($0).inserted
        }
        return types.isEmpty ? nil : types.joined(separator: "/")
    }

    /// 调用类型决定是否计数, 具体工具名缺失不影响分类
    var isToolCall: Bool {
        Self.isToolType(type)
    }

    static func isToolType(_ type: String) -> Bool {
        switch type {
        case "commandExecution", "fileChange", "webSearch", "imageView", "imageGeneration", "sleep",
             "mcpToolCall", "dynamicToolCall", "collabAgentToolCall": true
        default: false
        }
    }
}

nonisolated struct ActivityTokenBreakdown: Decodable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    var cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    var usage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens, cachedInputTokens: cachedInputTokens, cacheWriteInputTokens: cacheWriteInputTokens ?? 0,
            outputTokens: outputTokens, reasoningOutputTokens: reasoningOutputTokens, totalTokens: totalTokens
        )
    }
}

nonisolated struct ActivityTokenUpdate: Decodable {
    let total: ActivityTokenBreakdown
    let last: ActivityTokenBreakdown
}

nonisolated struct ActivityNotification: Decodable {
    enum Category {
        case state
        case progress
        case presentation
        case ignored
    }

    /// 方法名称相似不代表协议含义相同, 采集和日志共用完整名称分类
    static func category(for method: String) -> Category {
        switch method {
        case "thread/started", "thread/status/changed", "thread/settings/updated", "thread/tokenUsage/updated",
             "turn/started", "turn/completed", "item/started", "item/completed", "item/autoApprovalReview/started",
             "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval", "serverRequest/resolved":
            .state
        case "item/agentMessage/delta", "item/plan/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta",
             "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            .progress
        case "item/tool/requestUserInput", "mcpServer/elicitation/request", "item/autoApprovalReview/completed",
             "turn/plan/updated", "turn/diff/updated", "model/rerouted", "model/verification",
             "modelProvider/authRecoveryStarted", "modelProvider/authRecoveryCompleted", "model/safetyBuffering/updated",
             "thread/environment/connected", "thread/environment/disconnected", "hook/started", "hook/completed",
             "mcpServer/startupStatus/updated", "error":
            .presentation
        default:
            .ignored
        }
    }

    let id: ActivityJSONValue?
    let method: String
    let params: Params
    let live: ActivityLivePayload

    private enum CodingKeys: String, CodingKey { case id, method, params }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(ActivityJSONValue.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        live = try container.decode(ActivityLivePayload.self, forKey: .params)
        // 展示通知有不同的 status 类型, 不交给线程生命周期解码器解释
        if Self.category(for: method) == .presentation {
            params = Params(threadId: live.threadId, turnId: live.turnId, targetItemId: live.targetItemId, reviewId: live.reviewId)
        } else {
            params = try container.decode(Params.self, forKey: .params)
        }
    }

    struct Params: Decodable {
        var threadId: String?
        var turnId: String?
        var itemId: String?
        var requestId: ActivityJSONValue?
        var targetItemId: String?
        var reviewId: String?
        var thread: ActivityThread?
        var turn: ActivityTurn?
        var item: ActivityItem?
        var status: ActivityThreadStatus?
        var threadSettings: Settings?
        var startedAtMs: Double?
        var completedAtMs: Double?
        var tokenUsage: ActivityTokenUpdate?
    }

    struct Settings: Decodable {
        var model: String?
        var effort: String?
        var cwd: String?
        var approvalsReviewer: ActivityApprovalReviewer?
    }
}

nonisolated struct ActivityThreadRead: Decodable { let thread: ActivityThread }
nonisolated struct ActivityLoadedPage: Decodable { let data: [String]
    var nextCursor: String?
}

nonisolated struct ActivityTurnsPage: Decodable { let data: [ActivityTurn]
    var nextCursor: String?
}

nonisolated struct ActivityThreadResume: Decodable {
    let thread: ActivityThread
    var model: String?
    var reasoningEffort: String?
    var approvalsReviewer: ActivityApprovalReviewer?
}

/// Codex 协议使用 snake_case, 本地持久化使用业务枚举本身的名称
nonisolated struct ActivityApprovalReviewer: Decodable {
    let value: ApprovalReviewer

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "user": value = .user
        case "auto_review": value = .autoReview
        case "guardian_subagent": value = .guardianSubagent
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown approval reviewer")
        }
    }
}
