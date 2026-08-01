import Foundation

nonisolated enum CodexBarHelperIPC {
    static let helperBundleIdentifierSuffix = ".helper"
    static let machServiceName = bundleIdentifier.hasSuffix(helperBundleIdentifierSuffix)
        ? bundleIdentifier
        : bundleIdentifier + helperBundleIdentifierSuffix
    static let daemonPlistName = machServiceName + ".plist"
    static let watchdogGraceSeconds: TimeInterval = 15
    static let sentinelCheckIntervalSeconds: TimeInterval = 60
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

@objc nonisolated protocol CodexBarHelperProtocol: AnyObject {
    /// reply 的两个参数是 pmset 退出码, 与恢复写回的 SleepDisabled 值
    /// 写回的是接管前的原值, 所以第二个参数不等于请求值: 系统原本就禁用睡眠时恢复后仍是禁用
    /// 但 helper 本轮没接管过或 pmset 操作失败时它只是占位的 true, 并非实测状态
    /// 调用方要先确认退出码为 0, 且自己的接管过程没有被连接中断打断, 才能把它当成实测值
    func setSleepDisabled(
        _ disabled: Bool,
        reply: @escaping @Sendable (Int32, Bool) -> Void
    )
}
