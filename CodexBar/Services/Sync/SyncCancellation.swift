nonisolated enum SyncCancellation {
    /// 重新开启同步不会清除 Task 已有的取消标记
    static func check(isEnabled: () -> Bool) throws {
        try Task.checkCancellation()
        guard isEnabled() else { throw CancellationError() }
    }
}
