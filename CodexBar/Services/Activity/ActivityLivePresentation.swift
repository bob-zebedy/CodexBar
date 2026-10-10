import Foundation

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
        guard let status, [.active, .idle].contains(status.type) else { return }
        guard let flags = status.type == .idle ? [] : status.activeFlags else { return }
        let label: ActivityLiveLabel? = if flags.contains(.waitingOnApproval) {
            ActivityLiveLabel("waiting-approval")
        } else if flags.contains(.waitingOnUserInput) {
            ActivityLiveLabel("waiting-input")
        } else {
            nil
        }
        if let label {
            flagWait = ActivityLiveWait(label: label, since: flagWait?.label == label ? flagWait?.since : observedAt)
        } else {
            flagWait = nil
            requests.removeAll()
        }
    }

    mutating func consume(_ notification: ActivityInput, at date: Date) {
        let params = notification.params
        switch notification.kind {
        case .turnStarted:
            inventoryKnown = true
        case .threadStatusChanged:
            reconcile(status: params.status, observedAt: date)
        case .itemStarted, .itemFinished:
            if let item = params.item, ActivityItem.isObservedType(item.type) {
                consume(item, starting: notification.kind == .itemStarted, at: date)
            }
        case .replyProgress, .reasoningProgress, .reasoningSummaryProgress:
            let label = if notification.kind == .replyProgress {
                params.itemId.flatMap { items[$0]?.label } ?? ActivityLiveLabel("replying")
            } else {
                ActivityLiveLabel("thinking")
            }
            phase = Entry(label: label, at: date)
            phaseItemID = params.itemId
            operations.removeValue(forKey: "retry")
        case .commandProgress:
            if let id = params.itemId {
                // 中途接入可能没有 started, 输出类型足以恢复通用状态, 但不能补全工具清单
                let label = items[id]?.label ?? ActivityLiveLabel("command")
                items[id] = Entry(label: label, at: date, isTool: true)
            }
        case .commandApprovalRequested, .fileApprovalRequested, .permissionsRequested,
             .inputRequested:
            consumeRequest(notification, at: date)
        case .requestResolved:
            if let id = params.requestId, requests.removeValue(forKey: id) != nil {
                record("request-ended", at: date)
            }
        default:
            consumeSupplement(notification, at: date)
        }
        boundStorage()
    }

    private mutating func consumeRequest(_ notification: ActivityInput, at date: Date) {
        guard let id = notification.id else { return }
        let key: String
        switch notification.kind {
        case .inputRequested:
            guard notification.live.inputMode != .verification else { return }
            key = switch notification.live.inputMode {
            case .form: "waiting-form"
            case .external: "waiting-external"
            default: "waiting-service"
            }
        default:
            key = "waiting-approval"
        }
        requests[id] = requests[id] ?? ActivityLiveWait(label: ActivityLiveLabel(key), since: date)
    }

    private mutating func consume(_ item: ActivityItem, starting: Bool, at date: Date) {
        if item.type == .enteredReviewMode {
            isReviewing = true
        }
        if item.type == .exitedReviewMode {
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

    private mutating func consumeSupplement(_ notification: ActivityInput, at date: Date) {
        let live = notification.live
        switch notification.kind {
        case .planChanged:
            guard let completed = live.planCompleted, let total = live.planTotal else { return }
            record(completed > (planCompleted ?? completed) ? "plan-step-completed" : "plan-updated", at: date)
            planCompleted = completed
            planTotal = total
        case .diffChanged: record("diff-updated", at: date)
        case .modelChanged:
            let detail = [live.fromModel, live.toModel].compactMap(\.self).joined(separator: " → ")
            record("model-changed", detail: detail.isEmpty ? nil : detail, at: date)
        case .verificationRequested:
            if live.requiresVerification {
                record("verification-needed", at: date)
            }
        case .errorReported:
            setOperation("retry", label: "retrying", active: live.willRetry == true, at: date)
        case .authRecoveryStarted:
            setOperation("auth", label: "recovering-auth", active: true, at: date)
        case .authRecoveryFinished:
            setOperation("auth", label: "recovering-auth", active: false, at: date)
            record("auth-recovery-ended", at: date)
        case .safetyBufferingChanged:
            setOperation("buffer", label: "buffering", active: live.isSafetyBuffering, at: date)
        case .hookStarted, .hookFinished:
            consumeHook(notification, at: date)
        default: break
        }
    }

    private mutating func consumeHook(_ notification: ActivityInput, at date: Date) {
        guard let run = notification.live.run else { return }
        let starting = notification.kind == .hookStarted
        if !starting || run.isSynchronous {
            setOperation("hook:" + run.id, label: "running-hook", active: starting, at: date)
        }
        let outcomes = ["completed": "hook-completed", "failed": "hook-failed", "blocked": "hook-blocked", "stopped": "hook-stopped"]
        if !starting, let status = run.status, let key = outcomes[status.rawValue] {
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
