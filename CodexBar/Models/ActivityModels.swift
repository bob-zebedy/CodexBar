import Foundation

/// 活动状态, 任务历史和子 Agent 关联共用的保留窗口
nonisolated enum ActivityRetention {
    static let window: TimeInterval = 24 * 60 * 60
}

/// 正在运行或等待批准的任务摘要, 不对 UI 暴露原始会话 ID
nonisolated struct ActivityTaskSnapshot: Equatable, Identifiable {
    let id: UUID
    let projectName: String?
    let modelName: String?
    let effort: String?
    let startedAt: Date?
    let stateChangedAt: Date
    /// nil 表示 活动字段不足, 无法可靠统计; 0 表示已确认当前没有活跃子 Agent
    let activeSubagentCount: Int?
    var tokenUsage: TokenUsage?
    var approvalActionText: String?
    var presentation: ActivityLiveSummary?
}

/// 最近确认结束的任务; 完成只表示一轮任务结束, 不代表执行成功
nonisolated struct ActivityCompletion: Equatable, Identifiable {
    let id: UUID
    // 延续运行期间的 UI 状态, 终态记录仍使用独立的 id
    var taskID: UUID?
    let projectName: String?
    let modelName: String?
    let effort: String?
    let completedAt: Date
    let duration: TimeInterval?
    var tokenUsage: TokenUsage?
}

/// 本轮确认的终态和快照一起发布, 历史恢复只发布快照
nonisolated struct ActivityPresentationUpdate {
    let snapshot: ActivitySnapshot
    let terminalEvents: [ActivityTerminalEvent]
}

nonisolated enum ActivityTerminalEvent: Equatable {
    case completed(ActivityCompletion)
    case terminated(ActivityTermination)

    var id: UUID {
        switch self {
        case let .completed(completion): completion.id
        case let .terminated(termination): termination.id
        }
    }

    var endedAt: Date {
        switch self {
        case let .completed(completion): completion.completedAt
        case let .terminated(termination): termination.terminatedAt
        }
    }
}

/// 最近确认终止的任务; 中断和其他终止都不会触发完成提醒
nonisolated struct ActivityTermination: Equatable, Identifiable {
    let id: UUID
    var taskID: UUID?
    let projectName: String?
    let modelName: String?
    let effort: String?
    let terminatedAt: Date
    let duration: TimeInterval?
    var tokenUsage: TokenUsage?
    var isFailure = false
}

/// 实时越过静默阈值时交给通知服务的最小信息, 不包含原始 session 或 turn ID
nonisolated struct ProtectionNotice: Equatable, Sendable {
    let taskID: UUID
    let attemptID: UUID
    let projectName: String?
    let inactivityDurationText: String
}

/// UI 只消费该快照, 不直接读取或解释 活动事件
nonisolated struct ActivitySnapshot: Equatable {
    let waitingTasks: [ActivityTaskSnapshot]
    let runningTasks: [ActivityTaskSnapshot]
    let recentCompletions: [ActivityCompletion]
    let recentTerminations: [ActivityTermination]

    static let empty = ActivitySnapshot(
        waitingTasks: [],
        runningTasks: [],
        recentCompletions: [],
        recentTerminations: []
    )

    var panelWaitingTasks: [ActivityTaskSnapshot] {
        waitingTasks + runningTasks.filter { $0.presentation?.waiting != nil }
    }

    var panelRunningTasks: [ActivityTaskSnapshot] {
        runningTasks.filter { $0.presentation?.waiting == nil }
    }

    var panelPrimaryActivity: CodexPrimaryActivity {
        if let task = panelWaitingTasks.first {
            return .waiting(task)
        }
        if let task = panelRunningTasks.first {
            return .running(task)
        }
        return primaryActivity
    }

    var primaryWaitingTask: ActivityTaskSnapshot? {
        waitingTasks.first
    }

    var primaryRunningTask: ActivityTaskSnapshot? {
        runningTasks.first
    }

    var mostRecentCompletion: ActivityCompletion? {
        recentCompletions.first
    }

    var mostRecentTermination: ActivityTermination? {
        recentTerminations.first
    }

    var latestTerminalEvent: ActivityTerminalEvent? {
        if let termination = mostRecentTermination,
           mostRecentCompletion.map({ termination.terminatedAt >= $0.completedAt }) ?? true {
            return .terminated(termination)
        }
        return mostRecentCompletion.map(ActivityTerminalEvent.completed)
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

    /// 活动卡片优先展示等待批准和运行中任务, 空闲时保留最近完成或终止记录
    var primaryActivity: CodexPrimaryActivity {
        if let task = primaryWaitingTask {
            return .waiting(task)
        }
        if let task = primaryRunningTask {
            return .running(task)
        }
        switch latestTerminalEvent {
        case let .terminated(termination):
            return .terminated(termination)
        case let .completed(completion):
            return .completed(completion)
        case nil:
            return .idle
        }
    }

    /// 菜单栏只短暂显示最新终态, 不改变活动卡片的历史展示规则
    func statusItemActivity(at now: Date) -> CodexPrimaryActivity {
        let activity = primaryActivity
        switch activity {
        case .completed, .terminated:
            guard let expiration = statusItemActivityExpiration, now < expiration else {
                return .idle
            }
            return activity
        case .waiting, .running, .idle:
            return activity
        }
    }

    var statusItemActivityExpiration: Date? {
        guard !hasActiveTasks else { return nil }
        return latestTerminalEvent?.endedAt.addingTimeInterval(10)
    }
}

/// 快照归一后的主活动状态
nonisolated enum CodexPrimaryActivity: Equatable {
    case waiting(ActivityTaskSnapshot)
    case running(ActivityTaskSnapshot)
    case completed(ActivityCompletion)
    case terminated(ActivityTermination)
    case idle
}

/// 只有 live 事件 或 session 生命周期会发布 transition, bootstrap 永远不会触发历史通知
nonisolated enum ActivityTransition: Equatable {
    case waitingApproval(ActivityTaskSnapshot)
    case completed(ActivityCompletion)
}

nonisolated enum CodexDurationFormat {
    static func activityText(for interval: TimeInterval, locale: Locale = .current) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let duration = Duration.seconds(Double(totalSeconds))
        let allowedUnits: Set<Duration.UnitsFormatStyle.Unit> = if totalSeconds >= 3600 {
            [.hours, .minutes]
        } else if totalSeconds >= 60 {
            [.minutes, .seconds]
        } else {
            [.seconds]
        }
        return abbreviated(duration, allowedUnits: allowedUnits, locale: locale)
    }

    static func abbreviated(
        _ duration: Duration,
        allowedUnits: Set<Duration.UnitsFormatStyle.Unit>,
        locale: Locale = .current
    ) -> String {
        let formatted = duration.formatted(
            .units(
                allowed: allowedUnits,
                width: .abbreviated,
                zeroValueUnits: .show(length: 1),
                fractionalPart: .hide(rounded: .down)
            )
            .locale(locale)
            .attributed
        )
        var result = ""
        var previousPart: AttributeScopes.FoundationAttributes.MeasurementAttribute.Value?
        // 按系统标记的数字和单位补空格, 保留各语言原有的分隔符和单位名称
        for (part, range) in formatted.runs[\.measurement] {
            let text = String(formatted[range].characters)
            if let part, let previousPart, part != previousPart,
               result.last?.isWhitespace == false, text.first?.isWhitespace == false {
                result += " "
            }
            result += text
            previousPart = part
        }
        return result
    }
}

nonisolated enum ActivityDisplayFormat {
    static func modelMetadata(modelName: String?, effort: String?) -> String? {
        let components = [modelName, effort].compactMap(normalizedText)
        return components.isEmpty ? nil : components.joined(separator: " • ")
    }

    static func completionRelativeText(_ completedAt: Date, now: Date) -> String {
        relativeText(since: completedAt, now: now, action: .completed)
    }

    static func terminationRelativeText(_ terminatedAt: Date, now: Date) -> String {
        relativeText(since: terminatedAt, now: now, action: .terminated)
    }

    static func elapsedDurationFragment(for duration: TimeInterval) -> String {
        let durationText = CodexDurationFormat.activityText(for: duration)
        return String(localized: "activity.duration.elapsed", defaultValue: "\(durationText)")
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
            return String(localized: "activity.relative.just-completed")
        case (.terminated, ..<10):
            return String(localized: "activity.relative.just-stopped")
        case (.completed, ..<60):
            return String(localized: "activity.relative.completed-seconds-ago", defaultValue: "\(seconds, specifier: "%lld")")
        case (.terminated, ..<60):
            return String(localized: "activity.relative.stopped-seconds-ago", defaultValue: "\(seconds, specifier: "%lld")")
        case (.completed, _):
            return String(localized: "activity.relative.completed-minutes-ago", defaultValue: "\(seconds / 60, specifier: "%lld")")
        case (.terminated, _):
            return String(localized: "activity.relative.stopped-minutes-ago", defaultValue: "\(seconds / 60, specifier: "%lld")")
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
