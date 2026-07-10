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
nonisolated struct CodexActivityTaskSnapshot: Equatable, Sendable {
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
    let id: String
    let projectName: String?
    let completedAt: Date
    let duration: TimeInterval?
}

/// UI 只消费该快照，不直接读取或解释 Hook 事件。
nonisolated struct CodexActivitySnapshot: Equatable, Sendable {
    let primaryWaitingTask: CodexActivityTaskSnapshot?
    let primaryRunningTask: CodexActivityTaskSnapshot?
    let mostRecentCompletion: CodexActivityCompletion?
    let waitingCount: Int
    let runningCount: Int
    let isCompletionHighlighted: Bool

    static let empty = CodexActivitySnapshot(
        primaryWaitingTask: nil,
        primaryRunningTask: nil,
        mostRecentCompletion: nil,
        waitingCount: 0,
        runningCount: 0,
        isCompletionHighlighted: false
    )

    var activeCount: Int {
        waitingCount + runningCount
    }

    var hasActiveTasks: Bool {
        activeCount > 0
    }

    /// 等待批准 > 运行中 > 最近完成 > 空闲；菜单栏图标、tooltip 和活动卡片共用同一判定。
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
        return .idle
    }
}

/// 快照归一后的主活动状态，highlighted 表示完成仍处于高亮时间窗内。
nonisolated enum CodexPrimaryActivity: Equatable, Sendable {
    case waiting(CodexActivityTaskSnapshot)
    case running(CodexActivityTaskSnapshot)
    case completed(CodexActivityCompletion, highlighted: Bool)
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
