import Foundation

/// 只解码展示所需的协议元数据, 不保留回答, 命令, 路径, 表单或认证正文
nonisolated struct ActivityLivePayload: Decodable {
    var threadId: String?
    var turnId: String?
    var reviewId: String?
    var targetItemId: String?
    var mode: String?
    var isBlocking: Bool?
    var plan: [Status]?
    var review: Status?
    var run: Hook?
    var status: String?
    var server: String?
    var name: String?
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

    private enum CodingKeys: String, CodingKey {
        case threadId, turnId, reviewId, targetItemId, mode, isBlocking, plan, review, run, status, server, name
        case showBufferingUi, willRetry, fromModel, toModel, verifications
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threadId = try values.decodeIfPresent(String.self, forKey: .threadId)
        turnId = try values.decodeIfPresent(String.self, forKey: .turnId)
        reviewId = try values.decodeIfPresent(String.self, forKey: .reviewId)
        targetItemId = try values.decodeIfPresent(String.self, forKey: .targetItemId)
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
        isBlocking = try values.decodeIfPresent(Bool.self, forKey: .isBlocking)
        plan = try values.decodeIfPresent([Status].self, forKey: .plan)
        review = try values.decodeIfPresent(Status.self, forKey: .review)
        run = try values.decodeIfPresent(Hook.self, forKey: .run)
        // thread/status/changed 使用对象, MCP 启动状态使用字符串
        status = try? values.decode(String.self, forKey: .status)
        server = try values.decodeIfPresent(String.self, forKey: .server)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        showBufferingUi = try values.decodeIfPresent(Bool.self, forKey: .showBufferingUi)
        willRetry = try values.decodeIfPresent(Bool.self, forKey: .willRetry)
        fromModel = try values.decodeIfPresent(String.self, forKey: .fromModel)
        toModel = try values.decodeIfPresent(String.self, forKey: .toModel)
        verifications = try values.decodeIfPresent([String].self, forKey: .verifications)
    }
}

nonisolated struct ActivityLiveLabel: Equatable {
    let key: String
    var detail: String?

    init(_ key: String, detail: String? = nil) {
        self.key = key
        self.detail = detail.map { String($0.prefix(160)) }
    }
}

nonisolated struct ActivityLiveEvent: Equatable {
    let label: ActivityLiveLabel
    let at: Date
}

nonisolated struct ActivityLiveWait: Equatable {
    let label: ActivityLiveLabel
    let since: Date?
}

nonisolated struct ActivityLiveSummary: Equatable {
    var current: ActivityLiveLabel
    var waiting: ActivityLiveWait?
    var recent: ActivityLiveEvent?
    var toolCount: Int?
    var planCompleted: Int?
    var planTotal: Int?
    var isReviewing = false
    var updatedAt: Date = .distantPast
}

/// 与历史统计和审批策略独立的内存状态, 连接失效时整体丢弃
nonisolated struct ActivityLivePresentation {
    struct Entry {
        let label: ActivityLiveLabel
        let at: Date
        var isTool = false
    }

    private var items: [String: Entry] = [:]
    private var operations: [String: Entry] = [:]
    private(set) var requests: [String: ActivityLiveWait] = [:]
    private var flagWait: ActivityLiveWait?
    private var phase = Entry(label: ActivityLiveLabel("processing"), at: .distantPast)
    private var phaseItemID: String?
    private var recent: ActivityLiveEvent?
    private var planCompleted: Int?
    private var planTotal: Int?
    private var isReviewing = false
    private var inventoryKnown = false

    var summary: ActivityLiveSummary {
        let waiting = requests.min { lhs, rhs in
            let left = lhs.value.since ?? .distantFuture
            let right = rhs.value.since ?? .distantFuture
            return left == right ? lhs.key < rhs.key : left < right
        }?.value ?? flagWait
        let current = operations.values.max { $0.at < $1.at }
            ?? (Array(items.values) + [phase]).max { $0.at < $1.at } ?? phase
        return ActivityLiveSummary(
            current: waiting?.label ?? current.label, waiting: waiting, recent: recent,
            toolCount: inventoryKnown ? items.values.filter(\.isTool).count : nil,
            planCompleted: planCompleted, planTotal: planTotal, isReviewing: isReviewing, updatedAt: current.at
        )
    }

    mutating func reconcile(status: ActivityThreadStatus?, observedAt: Date? = nil) {
        guard let status, ["active", "idle"].contains(status.type) else { return }
        guard let flags = status.type == "idle" ? [] : status.activeFlags else { return }
        let label: ActivityLiveLabel? = if flags.contains("waitingOnApproval") {
            ActivityLiveLabel("waiting-approval")
        } else if flags.contains("waitingOnUserInput") {
            ActivityLiveLabel("waiting-input")
        } else {
            nil
        }
        if let label {
            flagWait = ActivityLiveWait(label: label, since: flagWait?.since ?? observedAt)
        } else {
            flagWait = nil
            requests.removeAll()
        }
    }

    mutating func consume(_ notification: ActivityNotification, at date: Date) {
        let params = notification.params
        switch notification.method {
        case "turn/started":
            inventoryKnown = true
        case "thread/status/changed":
            reconcile(status: params.status, observedAt: date)
        case "item/started", "item/completed":
            if let item = params.item {
                consume(item, starting: notification.method == "item/started", at: date)
            }
        case "item/agentMessage/delta", "item/plan/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            let label = if notification.method == "item/agentMessage/delta" {
                params.itemId.flatMap { items[$0]?.label } ?? ActivityLiveLabel("replying")
            } else {
                ActivityLiveLabel(notification.method == "item/plan/delta" ? "planning" : "thinking")
            }
            phase = Entry(label: label, at: date)
            phaseItemID = params.itemId
            operations.removeValue(forKey: "retry")
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            if let id = params.itemId {
                // 中途接入可能没有 started, 输出类型足以恢复通用状态, 但不能补全工具清单
                let label = items[id]?.label ?? ActivityLiveLabel(notification.method == "item/commandExecution/outputDelta" ? "command" : "editing")
                items[id] = Entry(label: label, at: date, isTool: true)
            }
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval",
             "item/tool/requestUserInput", "mcpServer/elicitation/request":
            consumeRequest(notification, at: date)
        case "serverRequest/resolved":
            if let id = params.requestId?.identifier, requests.removeValue(forKey: id) != nil {
                record("request-ended", at: date)
                if requests.isEmpty {
                    flagWait = nil
                }
            }
        default:
            consumeSupplement(notification, at: date)
        }
        boundStorage()
    }

    private mutating func consumeRequest(_ notification: ActivityNotification, at date: Date) {
        guard let id = notification.id?.identifier else { return }
        let key: String
        switch notification.method {
        case "item/tool/requestUserInput":
            guard notification.live.isBlocking == true else { return }
            key = "waiting-input"
        case "mcpServer/elicitation/request":
            key = switch notification.live.mode {
            case "form", "openai/form", "openaiForm": "waiting-form"
            case "url": "waiting-external"
            case "openai/userVerification": "waiting-verification"
            default: "waiting-service"
            }
        default:
            key = "waiting-approval"
        }
        requests[id] = requests[id] ?? ActivityLiveWait(label: ActivityLiveLabel(key), since: date)
    }

    private mutating func consume(_ item: ActivityItem, starting: Bool, at date: Date) {
        if item.type == "enteredReviewMode" {
            isReviewing = true
        }
        if item.type == "exitedReviewMode" {
            isReviewing = false
        }
        if starting, let label = item.liveLabel {
            items[item.id] = Entry(label: label, at: date, isTool: item.isToolCall)
            operations.removeValue(forKey: "retry")
        } else if !starting {
            let removed = items.removeValue(forKey: item.id)
            // 完成是最近事件, 不能覆盖已经到达的回答增量
            if phaseItemID == item.id || removed.map({ phase.at <= $0.at }) == true {
                phase = Entry(label: ActivityLiveLabel("processing"), at: items.isEmpty ? date : .distantPast)
                phaseItemID = nil
            }
            if let label = item.liveCompletionLabel {
                recent = ActivityLiveEvent(label: label, at: date)
            }
        }
    }

    private mutating func consumeSupplement(_ notification: ActivityNotification, at date: Date) {
        let live = notification.live
        switch notification.method {
        case "turn/plan/updated":
            guard let plan = live.plan else { return }
            let completed = plan.filter { $0.status == "completed" }.count
            record(completed > (planCompleted ?? completed) ? "plan-step-completed" : "plan-updated", at: date)
            planCompleted = completed
            planTotal = plan.count
        case "turn/diff/updated": record("diff-updated", at: date)
        case "model/rerouted":
            let detail = [live.fromModel, live.toModel].compactMap(\.self).joined(separator: " → ")
            record("model-changed", detail: detail.isEmpty ? nil : detail, at: date)
        case "model/verification":
            if live.verifications?.isEmpty == false {
                record("verification-needed", at: date)
            }
        case "thread/environment/connected": record("environment-connected", at: date)
        case "thread/environment/disconnected": record("environment-disconnected", at: date)
        case "error":
            setOperation("retry", label: "retrying", active: live.willRetry == true, at: date)
        case "modelProvider/authRecoveryStarted":
            setOperation("auth", label: "recovering-auth", active: true, at: date)
        case "modelProvider/authRecoveryCompleted":
            setOperation("auth", label: "recovering-auth", active: false, at: date)
            record("auth-recovery-ended", at: date)
        case "model/safetyBuffering/updated":
            setOperation("buffer", label: "buffering", active: live.showBufferingUi == true, at: date)
        case "mcpServer/startupStatus/updated":
            if let name = live.name ?? live.server {
                setOperation("mcp:" + name, label: "connecting-tool", active: live.status == "starting", at: date)
            }
        case "item/autoApprovalReview/started", "item/autoApprovalReview/completed":
            consumeReview(notification, at: date)
        case "hook/started", "hook/completed":
            consumeHook(notification, at: date)
        default: break
        }
    }

    private mutating func consumeReview(_ notification: ActivityNotification, at date: Date) {
        guard let id = notification.params.reviewId ?? notification.params.targetItemId else { return }
        let starting = notification.method == "item/autoApprovalReview/started"
        setOperation("review:" + id, label: "auto-approval", active: starting, at: date)
        let outcomes = ["approved": "approval-approved", "denied": "approval-denied", "timedOut": "approval-timeout", "aborted": "approval-aborted"]
        if !starting, let status = notification.live.review?.status, let key = outcomes[status] {
            record(key, at: date)
        }
    }

    private mutating func consumeHook(_ notification: ActivityNotification, at date: Date) {
        guard let run = notification.live.run else { return }
        let starting = notification.method == "hook/started"
        if !starting || run.executionMode == "sync" {
            setOperation("hook:" + run.id, label: "running-hook", active: starting, at: date)
        }
        let outcomes = ["completed": "hook-completed", "failed": "hook-failed", "blocked": "hook-blocked", "stopped": "hook-stopped"]
        if !starting, let status = run.status, let key = outcomes[status] {
            record(key, at: date)
        }
    }

    private mutating func setOperation(_ id: String, label: String, active: Bool, at date: Date) {
        if active {
            operations[id] = Entry(label: ActivityLiveLabel(label), at: date)
        } else {
            operations.removeValue(forKey: id)
        }
    }

    private mutating func record(_ key: String, detail: String? = nil, at date: Date) {
        recent = ActivityLiveEvent(label: ActivityLiveLabel(key, detail: detail), at: date)
    }

    private mutating func boundStorage() {
        // 异常服务端不能通过无限未结束的 item 或 request 扩大内存
        if items.count > 128 {
            items = Dictionary(uniqueKeysWithValues: items.sorted { $0.value.at > $1.value.at }.prefix(128).map { ($0.key, $0.value) })
            inventoryKnown = false
        }
        if operations.count > 128 {
            operations = Dictionary(uniqueKeysWithValues: operations.sorted { $0.value.at > $1.value.at }.prefix(128).map { ($0.key, $0.value) })
        }
        if requests.count > 128 {
            flagWait = ActivityLiveWait(label: ActivityLiveLabel("waiting-user"), since: nil)
            requests = Dictionary(uniqueKeysWithValues: requests.sorted { $0.key < $1.key }.prefix(128).map { ($0.key, $0.value) })
        }
    }
}
