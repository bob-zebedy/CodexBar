import Foundation

/// 活跃任务最近收到的 Hook 事件，供活动卡片展示当前执行阶段。
nonisolated enum CodexActivityEvent: Equatable, Sendable {
    case promptSubmitted
    case toolStarted
    case toolFinished
    case compactionStarted
    case compactionFinished
    case subagentStarted
    case subagentFinished
    case approvalRequested
}

/// bootstrap 后需要向更早日期定向查找 Prompt 起点的精确任务引用。
nonisolated struct CodexActivityPromptReference: Hashable, Sendable {
    let sessionId: String
    let turnId: String
}

/// 正在运行或等待批准的任务摘要，不对 UI 暴露原始会话 ID。
nonisolated struct CodexActivityTaskSnapshot: Equatable, Identifiable, Sendable {
    let id: UUID
    let latestEvent: CodexActivityEvent
    let projectName: String?
    let modelName: String?
    let toolName: String?
    let startedAt: Date?
    let stateChangedAt: Date
    let showsPreciseDuration: Bool
}

/// 最近确认结束的任务。完成只表示一轮任务结束，不代表执行成功。
nonisolated struct CodexActivityCompletion: Equatable, Identifiable, Sendable {
    let id: UUID
    let projectName: String?
    let modelName: String?
    let completedAt: Date
    let duration: TimeInterval?
}

/// 最近确认终止的任务。终止不会被视为完成，也不会触发完成提醒。
nonisolated struct CodexActivityTermination: Equatable, Identifiable, Sendable {
    let id: UUID
    let projectName: String?
    let modelName: String?
    let terminatedAt: Date
    let duration: TimeInterval?
}

/// UI 只消费该快照，不直接读取或解释 Hook 事件。
nonisolated struct CodexActivitySnapshot: Equatable, Sendable {
    let waitingTasks: [CodexActivityTaskSnapshot]
    let runningTasks: [CodexActivityTaskSnapshot]
    let recentCompletions: [CodexActivityCompletion]
    let recentTerminations: [CodexActivityTermination]
    let isCompletionHighlighted: Bool

    static let empty = CodexActivitySnapshot(
        waitingTasks: [],
        runningTasks: [],
        recentCompletions: [],
        recentTerminations: [],
        isCompletionHighlighted: false
    )

    var primaryWaitingTask: CodexActivityTaskSnapshot? {
        waitingTasks.first
    }

    var primaryRunningTask: CodexActivityTaskSnapshot? {
        runningTasks.first
    }

    var mostRecentCompletion: CodexActivityCompletion? {
        recentCompletions.first
    }

    var mostRecentTermination: CodexActivityTermination? {
        recentTerminations.first
    }

    var waitingCount: Int {
        waitingTasks.count
    }

    var runningCount: Int {
        runningTasks.count
    }

    var activeCount: Int {
        waitingCount + runningCount
    }

    var hasActiveTasks: Bool {
        activeCount > 0
    }

    var hasTaskCenterContent: Bool {
        hasActiveTasks || !recentCompletions.isEmpty || !recentTerminations.isEmpty
    }

    /// 等待批准 > 运行中 > 最近完成 > 最近终止 > 空闲；菜单栏图标、tooltip 和活动卡片共用同一判定。
    var primaryActivity: CodexPrimaryActivity {
        if let task = primaryWaitingTask {
            return .waiting(task)
        }
        if let task = primaryRunningTask {
            return .running(task)
        }
        if let completion = mostRecentCompletion {
            return .completed(completion, highlighted: isCompletionHighlighted)
        }
        if let termination = mostRecentTermination {
            return .terminated(termination)
        }
        return .idle
    }
}

/// 快照归一后的主活动状态，highlighted 表示完成仍处于高亮时间窗内。
nonisolated enum CodexPrimaryActivity: Equatable, Sendable {
    case waiting(CodexActivityTaskSnapshot)
    case running(CodexActivityTaskSnapshot)
    case completed(CodexActivityCompletion, highlighted: Bool)
    case terminated(CodexActivityTermination)
    case idle
}

/// 只有 live Hook 或 session 生命周期会发布 transition，bootstrap 永远不会触发历史通知。
nonisolated enum CodexActivityTransition: Equatable, Sendable {
    case waitingApproval(CodexActivityTaskSnapshot)
    case completed(CodexActivityCompletion)
}

nonisolated enum CodexActivityDurationFormat {
    static func text(for interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            return "\(minutes / 60) 小时 \(minutes % 60) 分"
        }
        if minutes > 0 {
            return "\(minutes) 分 \(seconds) 秒"
        }
        return "\(seconds) 秒"
    }
}

nonisolated enum CodexActivityDisplayFormat {
    static func eventText(for task: CodexActivityTaskSnapshot) -> String {
        switch task.latestEvent {
        case .promptSubmitted:
            "正在思考"
        case .toolStarted:
            task.toolName.map { "调用工具 \($0)" } ?? "调用工具"
        case .toolFinished:
            task.toolName.map { "调用工具 \($0) 完成" } ?? "调用工具完成"
        case .compactionStarted:
            "压缩上下文"
        case .compactionFinished:
            "上下文压缩完成"
        case .subagentStarted:
            "启动子智能体"
        case .subagentFinished:
            "子智能体完成"
        case .approvalRequested:
            "等待批准"
        }
    }

    static func completionRelativeText(_ completedAt: Date, now: Date) -> String {
        relativeText(since: completedAt, now: now, action: "完成")
    }

    static func terminationRelativeText(_ terminatedAt: Date, now: Date) -> String {
        relativeText(since: terminatedAt, now: now, action: "终止")
    }

    /// 活动卡片和任务中心共用同一份文案片段，各自决定连接符。
    static func waitingDetailComponents(
        for task: CodexActivityTaskSnapshot,
        now: Date
    ) -> [String] {
        [
            task.toolName ?? "等待下一步操作",
            "已等待 \(CodexActivityDurationFormat.text(for: now.timeIntervalSince(task.stateChangedAt)))"
        ]
    }

    static func runningDetailComponents(
        for task: CodexActivityTaskSnapshot,
        now: Date
    ) -> [String] {
        let duration = if task.showsPreciseDuration, let startedAt = task.startedAt {
            "已运行 \(CodexActivityDurationFormat.text(for: now.timeIntervalSince(startedAt)))"
        } else {
            "正在运行"
        }
        return [duration, eventText(for: task)]
    }

    static func historyDetailComponents(
        duration: TimeInterval?,
        relativeText: String
    ) -> [String] {
        var components = [String]()
        if let duration {
            components.append("耗时 \(CodexActivityDurationFormat.text(for: duration))")
        }
        components.append(relativeText)
        return components
    }

    private static func relativeText(since date: Date, now: Date, action: String) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 {
            return "刚刚\(action)"
        }
        if seconds < 60 {
            return "\(seconds) 秒前\(action)"
        }
        return "\(seconds / 60) 分钟前\(action)"
    }
}
