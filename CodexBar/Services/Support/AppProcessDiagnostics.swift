import Foundation
import os

/// 正常日志无法区分崩溃与退出, ObjC 异常发生时立即记录, Swift trap, kill 或断电在下次启动时补记
/// install 与 recordCleanExit 成对维护正常退出标志
nonisolated enum AppProcessDiagnostics {
    static func install(defaults: UserDefaults = .standard) {
        // 首次运行没有这个键, 不能当成崩溃过
        // kill, 活动监视器强制退出和 Xcode 停止按钮都到不了 recordCleanExit, 与崩溃无法区分
        // 无法确认是故障, 使用 notice 级别记录
        if let didExitCleanly = defaults.object(forKey: didExitCleanlyKey) as? Bool,
           !didExitCleanly {
            AppLog.app.notice("App 上次非正常退出: reason=unknown")
        }
        defaults.set(false, forKey: didExitCleanlyKey)

        // 此处理器仅接收 ObjC 异常, Swift 的 fatalError 和越界触发 trap, 在下次启动时补记
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "-"
            let details = LogFields.joined(
                "name=\(name)",
                "reason=\(reason)"
            )
            AppLog.app.error("未捕获异常: \(details, privacy: .public)")
        }
    }

    static func recordCleanExit(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: didExitCleanlyKey)
    }

    private static let didExitCleanlyKey = "Diagnostics.didExitCleanly"
}
