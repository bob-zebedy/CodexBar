nonisolated enum SyncCancellation {
    /// Task 的取消标记不会随开关重新启用而复活
    static func check(isEnabled: () -> Bool) throws {
        try Task.checkCancellation()
        guard isEnabled() else { throw CancellationError() }
    }
}
