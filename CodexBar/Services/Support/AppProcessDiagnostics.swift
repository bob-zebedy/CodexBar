import Foundation
import os

/// 崩溃时进程直接消失, 日志会停在最后一条正常记录上, 事后分不清是崩了还是被退出
/// 这里补两条线索: ObjC 异常当场留痕, 其余终止方式 (Swift trap, kill, 断电) 靠下次启动补记
/// 干净退出标志由 install 与 recordCleanExit 成对维护, 两侧都在这里, 不散到调用方
nonisolated enum AppProcessDiagnostics {
    static func install(defaults: UserDefaults = .standard) {
        // 首次运行没有这个键, 不能当成崩溃过
        // kill, 活动监视器强制退出和 Xcode 停止按钮都到不了 recordCleanExit, 与崩溃无法区分
        // 因此只记 notice: 这条是线索不是结论, 用 error 会让按级别筛的排查开局就追一个不存在的故障
        if let didExitCleanly = defaults.object(forKey: didExitCleanlyKey) as? Bool,
           !didExitCleanly {
            AppLog.app.notice("App 上次非正常退出: reason=unknown")
        }
        defaults.set(false, forKey: didExitCleanlyKey)

        // 只兜得住 ObjC 异常; Swift 的 fatalError 与越界是 trap, 到不了这里, 由上面那条补记
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
