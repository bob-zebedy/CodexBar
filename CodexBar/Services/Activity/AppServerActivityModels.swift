import Foundation

private nonisolated struct WireActivityThread: Decodable {
    let id: String
    var cwd: String?
    var model: String?
    var reasoningEffort: String?
    var status: WireActivityThreadStatus?
    var source: WireActivityThreadSource?
    var parentThreadId: String?
    var createdAt: Double?
    var threadSource: String?

    var origin: ActivityDataOrigin {
        source?.origin ?? .unknown
    }

    var parentThreadID: String? {
        parentThreadId ?? source?.parentThreadID
    }
}

private nonisolated struct WireActivityThreadStatus: Decodable {
    let type: String
    var activeFlags: [String]?
}

private nonisolated struct WireActivityThreadSource: Decodable {
    let origin: ActivityDataOrigin
    let parentThreadID: String?

    init(from decoder: Decoder) throws {
        let value = try ActivityJSONValue(from: decoder)
        if let name = value.string {
            origin = ["cli", "vscode", "exec", "appServer"].contains(name) ? .main : .unknown
            parentThreadID = nil
        } else if let subagent = value["subAgent"] ?? value["subagent"] {
            let other = subagent["other"]?.string
            origin = other == "guardian" ? .autoReview : .auxiliary
            parentThreadID = (subagent["thread_spawn"] ?? subagent["threadSpawn"])?["parent_thread_id"]?.string
        } else {
            origin = value["custom"] == nil ? .unknown : .main
            parentThreadID = nil
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

private nonisolated struct WireActivityTurn: Decodable {
    let id: String
    let status: String
    var rootTurnId: String?
    var items: [WireActivityItem]?
    var startedAt: Double?
    var completedAt: Double?
    var durationMs: Double?
}

private nonisolated struct WireActivityItem: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, type, status, tool, server, agentThreadId, kind, model, reasoningEffort
        case commandActions, phase, action, success, agentsStates, delivery, questions, content
    }

    private enum CommandActionCodingKeys: String, CodingKey { case type, command }

    struct CommandAction: Decodable {
        let type: String
        var command: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CommandActionCodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            // 展示字段异常不能影响已有的活动分类和生命周期
            command = try? container.decodeIfPresent(String.self, forKey: .command)
        }
    }

    let id: String
    let type: String
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
    var delivery: String?
    var questions: [Question]?
    var content: [Content]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        agentThreadId = try container.decodeIfPresent(String.self, forKey: .agentThreadId)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        commandActions = try container.decodeIfPresent([CommandAction].self, forKey: .commandActions)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        action = try container.decodeIfPresent(WebAction.self, forKey: .action)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        agentsStates = try container.decodeIfPresent([String: AgentState].self, forKey: .agentsStates)
        delivery = try container.decodeIfPresent(String.self, forKey: .delivery)
        questions = try container.decodeIfPresent([Question].self, forKey: .questions)
        // 同名 content 字段随事件类型改变结构, 这里只读取用户消息中的问题回复
        content = type == "userMessage" ? try container.decodeIfPresent([Content].self, forKey: .content) : nil
    }

    struct WebAction: Decodable { var type: String? }
    struct AgentState: Decodable { var status: String? }
    struct Question: Decodable { let title: String }
    struct Content: Decodable {
        let type: String
        var text: String?
    }

    struct QuestionReply: Decodable { let questionItemId: String }
}

private nonisolated struct WireTokenUsageBreakdown: Decodable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    var cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens, cachedInputTokens: cachedInputTokens, cacheWriteInputTokens: cacheWriteInputTokens ?? 0,
            outputTokens: outputTokens, reasoningOutputTokens: reasoningOutputTokens, totalTokens: totalTokens
        )
    }
}

private nonisolated struct WireTokenUsageUpdate: Decodable {
    let total: WireTokenUsageBreakdown
    let last: WireTokenUsageBreakdown
    var modelContextWindow: Int64?
}

private nonisolated struct WireActivityInput: Decodable {
    struct Params: Decodable {
        var threadId: String?
        var turnId: String?
        var itemId: String?
        var approvalId: String?
        var requestId: ActivityJSONValue?
        var thread: WireActivityThread?
        var turn: WireActivityTurn?
        var item: WireActivityItem?
        var status: WireActivityThreadStatus?
        var startedAtMs: Double?
        var completedAtMs: Double?
        var tokenUsage: WireTokenUsageUpdate?
        var commandActions: [WireActivityItem.CommandAction]?
    }

    let id: ActivityJSONValue?
    let kind: ActivityInput.Kind
    let provenanceMethod: String
    let params: Params
    let live: WireActivityLivePayload

    private enum CodingKeys: String, CodingKey { case id, method, params }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(ActivityJSONValue.self, forKey: .id)
        provenanceMethod = try container.decode(String.self, forKey: .method)
        kind = AppServerActivityProtocol.kind(for: provenanceMethod)
        live = try container.decode(WireActivityLivePayload.self, forKey: .params)
        // 展示通知有不同的 status 类型, 不交给会话生命周期解码器解释
        if kind.category == .presentation {
            params = Params(threadId: live.threadId, turnId: live.turnId)
        } else {
            params = try container.decode(Params.self, forKey: .params)
            switch kind {
            case .itemStarted, .itemFinished, .usageUpdated,
                 .commandApprovalRequested, .fileApprovalRequested, .permissionsRequested,
                 .replyProgress, .reasoningProgress, .reasoningSummaryProgress, .commandProgress:
                guard let turnID = params.turnId, !turnID.isEmpty else {
                    throw DecodingError.dataCorruptedError(forKey: .params, in: container, debugDescription: "Missing turn identity")
                }
            default: break
            }
            if kind == .usageUpdated,
               params.tokenUsage == nil || params.threadId?.isEmpty != false {
                throw DecodingError.dataCorruptedError(forKey: .params, in: container, debugDescription: "Missing token tokenUsage or thread identity")
            }
            if [.commandApprovalRequested, .fileApprovalRequested, .permissionsRequested].contains(kind),
               params.itemId == nil || params.startedAtMs == nil {
                throw DecodingError.dataCorruptedError(forKey: .params, in: container, debugDescription: "Missing approval identity")
            }
        }
    }
}

nonisolated struct ActivityThreadRead: Decodable { let thread: ActivityThread }
nonisolated struct ActivityLoadedPage: Decodable { let data: [String]
    var nextCursor: String?
}

nonisolated struct ActivityTurnsPage: Decodable { let data: [ActivityTurn]
    var nextCursor: String?
}

nonisolated struct ActivityItemsPage: Decodable {
    let data: [ActivityItemEntry]
    var nextCursor: String?
}

nonisolated struct ActivityItemEntry: Decodable {
    let turnId: String
    let item: ActivityItem
    var startedAtMs: Double?
    var completedAtMs: Double?

    var startedAt: Date? {
        startedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    var completedAt: Date? {
        completedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}

nonisolated extension ActivityItem: Decodable {
    init(from decoder: Decoder) throws {
        self = try WireActivityItem(from: decoder).normalized
    }
}

nonisolated struct ActivityThreadResume: Decodable {
    let thread: ActivityThread
}

nonisolated enum AppServerActivityProtocol {
    static func observes(itemType: String) -> Bool {
        ActivityItem.isObservedType(.init(rawValue: itemType) ?? .unknown)
    }

    static func kind(for method: String) -> ActivityInput.Kind {
        switch method {
        case "thread/started": .threadDiscovered
        case "thread/status/changed": .threadStatusChanged
        case "thread/tokenUsage/updated": .usageUpdated
        case "turn/started": .turnStarted
        case "turn/completed": .turnFinished
        case "item/started": .itemStarted
        case "item/completed": .itemFinished
        case "item/commandExecution/requestApproval": .commandApprovalRequested
        case "item/fileChange/requestApproval": .fileApprovalRequested
        case "item/permissions/requestApproval": .permissionsRequested
        case "serverRequest/resolved": .requestResolved
        case "item/agentMessage/delta": .replyProgress
        case "item/reasoning/textDelta": .reasoningProgress
        case "item/reasoning/summaryTextDelta": .reasoningSummaryProgress
        case "item/commandExecution/outputDelta": .commandProgress
        case "mcpServer/elicitation/request": .inputRequested
        case "item/tool/requestUserInput": .userInputRequested
        case "turn/plan/updated": .planChanged
        case "turn/diff/updated": .diffChanged
        case "model/rerouted": .modelChanged
        case "model/verification": .verificationRequested
        case "modelProvider/authRecoveryStarted": .authRecoveryStarted
        case "modelProvider/authRecoveryCompleted": .authRecoveryFinished
        case "model/safetyBuffering/updated": .safetyBufferingChanged
        case "hook/started": .hookStarted
        case "hook/completed": .hookFinished
        case "error": .errorReported
        default: .ignored
        }
    }
}

nonisolated extension ActivityThread: Decodable {
    init(from decoder: Decoder) throws {
        self = try WireActivityThread(from: decoder).normalized
    }

    fileprivate static func status(_ value: WireActivityThreadStatus) -> ActivityThreadStatus {
        ActivityThreadStatus(
            type: .init(rawValue: value.type) ?? .unknown,
            activeFlags: value.activeFlags?.map { .init(rawValue: $0) ?? .unknown }
        )
    }
}

private nonisolated extension WireActivityThread {
    var normalized: ActivityThread {
        ActivityThread(
            id: id,
            cwd: cwd,
            model: model,
            reasoningEffort: reasoningEffort,
            status: status.map(ActivityThread.status),
            origin: origin,
            parentThreadID: parentThreadID,
            createdAt: createdAt.map(Date.init(timeIntervalSince1970:)),
            threadSource: threadSource
        )
    }
}

nonisolated extension ActivityTurn: Decodable {
    init(from decoder: Decoder) throws {
        self = try WireActivityTurn(from: decoder).normalized
    }
}

private nonisolated extension WireActivityTurn {
    var normalized: ActivityTurn {
        ActivityTurn(
            id: id,
            status: status == "inProgress" ? .running : ActivityTurnStatus(rawValue: status) ?? .unknown,
            rootTurnId: rootTurnId,
            items: items?.map(\.normalized),
            startedAt: startedAt.map(Date.init(timeIntervalSince1970:)),
            completedAt: completedAt.map(Date.init(timeIntervalSince1970:)),
            duration: durationMs.map { $0 / 1000 }
        )
    }
}

private nonisolated extension WireActivityItem {
    var normalized: ActivityItem {
        ActivityItem(
            id: id,
            type: .init(rawValue: type) ?? .unknown,
            status: status,
            tool: tool,
            server: server,
            agentThreadId: agentThreadId,
            kind: kind,
            model: model,
            reasoningEffort: reasoningEffort,
            commandActions: commandActions?.map { .init(type: $0.type) },
            commandSummary: commandSummary,
            phase: phase,
            action: action.map { .init(type: $0.type) },
            success: success,
            agentsStates: agentsStates?.mapValues { .init(status: $0.status) },
            asyncQuestionCount: type == "agentMessage" && delivery == "async" ? questions?.count ?? 0 : 0,
            questionReplies: questionReplies
        )
    }

    private var commandSummary: ActivityItem.CommandSummary? {
        guard type == "commandExecution", let commandActions, !commandActions.isEmpty,
              !commandActions.contains(where: { ["read", "listFiles", "search"].contains($0.type) }),
              commandActions.allSatisfy({ $0.command != nil }) else { return nil }
        return ActivityCommandParser.summarize(commandActions.compactMap(\.command))
    }

    private var questionReplies: [ActivityItem.QuestionReply]? {
        guard type == "userMessage" else { return nil }
        let opening = "<send_user_message_question_reply>"
        let closing = "</send_user_message_question_reply>"
        var result: [ActivityItem.QuestionReply]?
        for content in content ?? [] where content.type == "text" {
            let text = content.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 普通消息也可能讨论这些标签, 仅识别完整且问题标识格式正确的回应
            guard text.hasPrefix(opening), text.hasSuffix(closing), text.count >= opening.count + closing.count,
                  let replies = try? JSONDecoder().decode(
                      [QuestionReply].self, from: Data(text.dropFirst(opening.count).dropLast(closing.count).utf8)
                  ) else { continue }
            let parsedReplies: [ActivityItem.QuestionReply] = replies.compactMap { reply in
                guard let value = try? JSONDecoder().decode(ActivityJSONValue.self, from: Data(reply.questionItemId.utf8)),
                      case let .array(parts) = value, parts.count == 3,
                      parts[0].string == "request_user_input_async", let itemID = parts[1].string, !itemID.isEmpty,
                      let number = parts[2].number, let index = Int(exactly: number), index >= 0 else { return nil }
                return .init(itemID: itemID, index: index)
            }
            guard parsedReplies.count == replies.count else { continue }
            if result == nil {
                result = []
            }
            result?.append(contentsOf: parsedReplies)
        }
        return result
    }
}

nonisolated extension ActivityInput: Decodable {
    init(from decoder: Decoder) throws {
        let wire = try WireActivityInput(from: decoder)
        let raw = wire.params
        self.init(
            id: wire.id?.identifier,
            kind: wire.kind,
            provenanceMethod: wire.provenanceMethod,
            params: Params(
                threadId: raw.threadId,
                turnId: raw.turnId,
                itemId: raw.itemId,
                approvalId: raw.approvalId,
                requestId: raw.requestId?.identifier,
                thread: raw.thread?.normalized,
                turn: raw.turn?.normalized,
                item: raw.item?.normalized,
                status: raw.status.map(ActivityThread.status),
                startedAt: raw.startedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                completedAt: raw.completedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                tokenUsage: raw.tokenUsage.map {
                    TokenUsageUpdate(total: $0.total.tokenUsage, last: $0.last.tokenUsage, modelContextWindow: $0.modelContextWindow)
                },
                commandActions: raw.commandActions?.map { .init(type: $0.type) }
            ),
            live: wire.live.normalized
        )
    }
}

/// 只解码展示所需的协议元数据, 不保留回答, 命令, 路径, 表单或认证正文
private nonisolated struct WireActivityLivePayload: Decodable {
    var threadId: String?
    var turnId: String?
    var mode: String?
    var isBlocking: Bool?
    var plan: [Status]?
    var run: Hook?
    var showBufferingUi: Bool?
    var willRetry: Bool?
    var fromModel: String?
    var toModel: String?
    var verifications: [String]?

    struct Status: Decodable { var status: String? }
    struct Hook: Decodable {
        let id: String
        var status: String?
        var executionMode: String?
    }
}

private nonisolated extension WireActivityLivePayload {
    var normalized: ActivityLiveContext {
        let inputMode: ActivityLiveContext.InputMode = switch mode {
        case "form", "openai/form", "openaiForm": .form
        case "url": .external
        case "openai/userVerification": .verification
        default: .service
        }
        return ActivityLiveContext(
            inputMode: inputMode,
            isBlocking: isBlocking,
            planCompleted: plan.map { $0.filter { $0.status == "completed" }.count },
            planTotal: plan?.count,
            run: run.map { .init(id: $0.id, status: $0.status.map { .init(rawValue: $0) ?? .unknown }, isSynchronous: $0.executionMode == "sync") },
            isSafetyBuffering: showBufferingUi == true,
            willRetry: willRetry,
            fromModel: fromModel,
            toModel: toModel,
            requiresVerification: verifications?.isEmpty == false
        )
    }
}

nonisolated extension AppServerActivityProtocol {
    static func recoveryThreadID(from data: Data) -> String? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let params = envelope["params"] as? [String: Any],
              let thread = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String,
              !thread.isEmpty else { return nil }
        return thread
    }
}
