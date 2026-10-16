import Foundation

nonisolated enum CodexBarPowerHelperIPC {
    #if DEBUG
        static let clientAppBundleIdentifier = "app.zabrian.codexbar.debug"
        static let serviceIdentifier = "app.zabrian.codexbar.helper.power.debug"
        static let daemonPlistName = "CodexBarPowerHelper.Debug.plist"
    #else
        static let clientAppBundleIdentifier = "app.zabrian.codexbar"
        static let serviceIdentifier = "app.zabrian.codexbar.helper.power"
        static let daemonPlistName = "CodexBarPowerHelper.plist"
    #endif
    static let watchdogGraceSeconds: TimeInterval = 15
    static let externalCheckIntervalSeconds: TimeInterval = 5
    static let ownedCheckIntervalSeconds: TimeInterval = 5
    static let recoveryCheckIntervalSeconds: TimeInterval = 60
    static let checkLeewaySeconds: TimeInterval = 1
    /// App 等待 XPC 回复的上限, 超时后断开连接并进入失败恢复
    static let requestTimeoutSeconds: TimeInterval = 10
}

nonisolated enum CodexBarSleepPreventionSource: Int, Sendable {
    case none
    case external
    case codexBar
}

nonisolated enum CodexBarSleepOwnershipState: Int, Sendable {
    case idle
    case owned
    case restoring
}

@objc nonisolated protocol CodexBarPowerHelperProtocol: AnyObject {
    /// clientSessionID 跨重连保持租约身份, generation 防止旧请求覆盖新状态
    /// reply 依次返回操作状态码, 防睡眠来源和 SleepDisabled 状态, 后两项可能来自缓存
    func setSleepPreventionRequested(
        _ requested: Bool,
        clientSessionID: String,
        generation: UInt64,
        reply: @escaping @Sendable (Int32, Int, Bool) -> Void
    )

    /// reply 依次返回状态码, 所有权状态, 活跃客户端数与最近一次实测的 SleepDisabled
    func getSleepPreventionStatus(
        reply: @escaping @Sendable (Int32, Int, Int, Bool) -> Void
    )

    /// Power Helper 更新后按租约和所有权核对, 同一指纹只完成一次
    func resetSleepAfterUpdate(
        _ updateIdentifier: String,
        reply: @escaping @Sendable (Int32) -> Void
    )

    /// 时间戳为 0 时取消 CodexBar 自己的重置次数唤醒计划
    func setAutoResetWakeSchedule(
        _ unixTimestamp: TimeInterval,
        reply: @escaping @Sendable (Int32) -> Void
    )
}
