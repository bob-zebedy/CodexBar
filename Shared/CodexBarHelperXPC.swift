import Foundation

nonisolated enum CodexBarHelperIPC {
    static let helperBundleIdentifierSuffix = ".helper"
    static let machServiceName = bundleIdentifier.hasSuffix(helperBundleIdentifierSuffix)
        ? bundleIdentifier
        : bundleIdentifier + helperBundleIdentifierSuffix
    static let daemonPlistName = machServiceName + ".plist"
    static let watchdogGraceSeconds: TimeInterval = 15
    static let externalCheckIntervalSeconds: TimeInterval = 5
    static let ownedCheckIntervalSeconds: TimeInterval = 5
    static let recoveryCheckIntervalSeconds: TimeInterval = 60
    static let checkLeewaySeconds: TimeInterval = 1
    /// App 侧等回复的上限, 与 watchdog 宽限是一对: 必须更小, 这样 App 先放手 helper 再自行兜底
    /// helper 冷启动加一次 pmset 通常一秒内完成, 留这么宽只为排除偶发的调度抖动
    static let requestTimeoutSeconds: TimeInterval = 10

    private static let bundleIdentifier: String = {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else {
            preconditionFailure("CodexBar bundle identifier 缺失")
        }
        return identifier
    }()
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

@objc nonisolated protocol CodexBarHelperProtocol: AnyObject {
    /// reply 依次返回 pmset 退出码, 本轮防睡眠来源与操作后实测的 SleepDisabled
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

    /// helper 更新完成后对同一指纹只执行一次 SleepDisabled 0
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
