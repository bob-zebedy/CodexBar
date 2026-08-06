import Foundation

/// 实时活动管道的共享保留窗口
/// tail reader 的 bootstrap 回放范围与任务中心的历史保留期是同一个不变量, 必须相等
nonisolated enum CodexActivityRetention {
    static let window: TimeInterval = 24 * 60 * 60
}

/// 活跃任务最近收到的 Hook 事件, 供活动卡片展示当前执行阶段
nonisolated enum CodexActivityEvent: Equatable {
    case promptSubmitted
    case toolStarted
    case toolFinished
    case compactionStarted
    case compactionFinished
    case subagentStarted
    case subagentFinished
    case approvalRequested
}

/// bootstrap 后需要向更早日期定向查找 Prompt 起点的精确任务引用
nonisolated struct CodexActivityPromptReference: Hashable {
    let sessionId: String
    let turnId: String
}

/// 正在运行或等待批准的任务摘要, 不对 UI 暴露原始会话 ID
nonisolated struct CodexActivityTaskSnapshot: Equatable, Identifiable {
    let id: UUID
    let isAnonymous: Bool
    let latestEvent: CodexActivityEvent
    let projectName: String?
    let modelName: String?
    let effort: String?
    let toolName: String?
    let startedAt: Date?
    let stateChangedAt: Date
    let showsPreciseDuration: Bool
    /// nil 表示 Hook 字段不足, 无法可靠统计; 0 表示已确认当前没有活跃子 Agent
    let activeSubagentCount: Int?
}

/// 最近确认结束的任务; 完成只表示一轮任务结束, 不代表执行成功
nonisolated struct CodexActivityCompletion: Equatable, Identifiable {
    let id: UUID
    let isAnonymous: Bool
    let projectName: String?
    let modelName: String?
    let effort: String?
    let completedAt: Date
    let duration: TimeInterval?
}

/// 最近确认终止的任务; 终止不会被视为完成, 也不会触发完成提醒
nonisolated struct CodexActivityTermination: Equatable, Identifiable {
    let id: UUID
    let isAnonymous: Bool
    let projectName: String?
    let modelName: String?
    let effort: String?
    let terminatedAt: Date
    let duration: TimeInterval?
}

/// 实时越过静默阈值时交给通知服务的最小信息, 不包含原始 session 或 turn ID
nonisolated struct CodexActivityProtectionNotice: Equatable, Sendable {
    let taskID: UUID
    let attemptID: UUID
    let projectName: String?
    let inactivityDurationText: String
    let inactivityDurationSeconds: Int
    let progressGeneration: UInt64
}

/// UI 只消费该快照, 不直接读取或解释 Hook 事件
nonisolated struct CodexActivitySnapshot: Equatable {
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

    /// 等待批准 > 运行中 > 最近完成 > 最近终止 > 空闲; 菜单栏图标, tooltip 和活动卡片共用同一判定
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

/// 快照归一后的主活动状态, highlighted 表示完成仍处于高亮时间窗内
nonisolated enum CodexPrimaryActivity: Equatable {
    case waiting(CodexActivityTaskSnapshot)
    case running(CodexActivityTaskSnapshot)
    case completed(CodexActivityCompletion, highlighted: Bool)
    case terminated(CodexActivityTermination)
    case idle
}

/// 只有 live Hook 或 session 生命周期会发布 transition, bootstrap 永远不会触发历史通知
nonisolated enum CodexActivityTransition: Equatable {
    case waitingApproval(CodexActivityTaskSnapshot)
    case completed(CodexActivityCompletion)

    var isAnonymous: Bool {
        switch self {
        case let .waitingApproval(task): task.isAnonymous
        case let .completed(completion): completion.isAnonymous
        }
    }
}

nonisolated enum CodexDurationFormat {
    static func activityText(for interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let duration = Duration.seconds(Double(totalSeconds))
        let allowedUnits: Set<Duration.UnitsFormatStyle.Unit> = if totalSeconds >= 3600 {
            [.hours, .minutes]
        } else if totalSeconds >= 60 {
            [.minutes, .seconds]
        } else {
            [.seconds]
        }
        return abbreviated(duration, allowedUnits: allowedUnits)
    }

    static func abbreviated(
        _ duration: Duration,
        allowedUnits: Set<Duration.UnitsFormatStyle.Unit>
    ) -> String {
        duration.formatted(
            .units(
                allowed: allowedUnits,
                width: .abbreviated,
                zeroValueUnits: .show(length: 1),
                fractionalPart: .hide(rounded: .down)
            )
        )
    }
}

nonisolated enum CodexActivityDisplayFormat {
    static func modelMetadata(modelName: String?, effort: String?) -> String? {
        let components = [modelName, effort].compactMap(normalizedText)
        return components.isEmpty ? nil : components.joined(separator: " • ")
    }

    static func eventText(for task: CodexActivityTaskSnapshot) -> String {
        switch task.latestEvent {
        case .promptSubmitted:
            String(localized: "正在思考")
        case .toolStarted:
            task.toolName.map { String(localized: "调用工具 \($0)") }
                ?? String(localized: "调用工具")
        case .toolFinished:
            task.toolName.map { String(localized: "调用工具 \($0) 完成") }
                ?? String(localized: "调用工具完成")
        case .compactionStarted:
            String(localized: "压缩上下文")
        case .compactionFinished:
            String(localized: "上下文压缩完成")
        case .subagentStarted:
            String(localized: "启动子智能体")
        case .subagentFinished:
            String(localized: "子智能体完成")
        case .approvalRequested:
            String(localized: "等待批准")
        }
    }

    static func completionRelativeText(_ completedAt: Date, now: Date) -> String {
        relativeText(since: completedAt, now: now, action: .completed)
    }

    static func terminationRelativeText(_ terminatedAt: Date, now: Date) -> String {
        relativeText(since: terminatedAt, now: now, action: .terminated)
    }

    /// 活动卡片, 任务中心, 菜单栏 tooltip 和系统通知共用的时长片段
    static func waitingDurationFragment(since stateChangedAt: Date, now: Date) -> String {
        let duration = CodexDurationFormat.activityText(for: now.timeIntervalSince(stateChangedAt))
        return String(localized: "已等待 \(duration)")
    }

    static func runningDurationFragment(since startedAt: Date, now: Date) -> String {
        let duration = CodexDurationFormat.activityText(for: now.timeIntervalSince(startedAt))
        return String(localized: "已运行 \(duration)")
    }

    static func elapsedDurationFragment(for duration: TimeInterval) -> String {
        let durationText = CodexDurationFormat.activityText(for: duration)
        return String(localized: "耗时 \(durationText)")
    }

    /// 活动卡片和任务中心共用同一份文案片段
    static func waitingDetailComponents(
        for task: CodexActivityTaskSnapshot,
        now: Date
    ) -> [String] {
        [
            task.toolName ?? String(localized: "等待下一步操作"),
            waitingDurationFragment(since: task.stateChangedAt, now: now)
        ]
    }

    static func runningDetailComponents(
        for task: CodexActivityTaskSnapshot,
        now: Date
    ) -> [String] {
        let duration = if task.showsPreciseDuration, let startedAt = task.startedAt {
            runningDurationFragment(since: startedAt, now: now)
        } else {
            String(localized: "正在运行")
        }
        return [duration, eventText(for: task)]
    }

    static func historyDetailComponents(
        duration: TimeInterval?,
        relativeText: String
    ) -> [String] {
        var components = [String]()
        if let duration {
            components.append(elapsedDurationFragment(for: duration))
        }
        components.append(relativeText)
        return components
    }

    private static func relativeText(since date: Date, now: Date, action: RelativeAction) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch (action, seconds) {
        case (.completed, ..<10):
            return String(localized: "刚刚完成")
        case (.terminated, ..<10):
            return String(localized: "刚刚终止")
        case (.completed, ..<60):
            return String(localized: "\(seconds) 秒前完成")
        case (.terminated, ..<60):
            return String(localized: "\(seconds) 秒前终止")
        case (.completed, _):
            return String(localized: "\(seconds / 60) 分钟前完成")
        case (.terminated, _):
            return String(localized: "\(seconds / 60) 分钟前终止")
        }
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private enum RelativeAction {
        case completed
        case terminated
    }
}
