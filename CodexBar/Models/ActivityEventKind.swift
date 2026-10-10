/// app-server 事件映射到业务统计的生命周期阶段, 持久化直接使用枚举名称
nonisolated enum ActivityEventKind: String, CaseIterable, Hashable {
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
