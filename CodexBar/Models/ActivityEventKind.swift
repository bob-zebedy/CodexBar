import Foundation

/// app-server 事件映射到业务统计的生命周期阶段, 持久化直接使用枚举名称
nonisolated enum ActivityEventKind: String, CaseIterable, Hashable {
    case sessionStarted
    case sessionEnded
    case turnStarted
    case toolStarted
    case toolCompleted
    case approvalRequested
    case compactionStarted
    case compactionCompleted
    case turnCompleted
    case turnAborted
    case subagentStarted
    case subagentEnded

    init?(eventName: String) {
        self.init(rawValue: eventName)
    }
}

/// 审批路由的文件值直接使用成员名称, 协议解码在 app-server 边界完成
nonisolated enum ApprovalReviewer: String, Codable, CaseIterable {
    case user
    case autoReview
    case guardianSubagent
}
