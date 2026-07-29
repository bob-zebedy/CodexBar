import Foundation
import os

/// App 侧统一的系统日志出口, 与 app-server 链路的日志窗口分工明确
/// 用户可见的错误文案只留步骤名, 定位问题需要的细节写到这里
/// subsystem 取 bundle identifier, Debug 与 Release 两套装置的日志因此天然分开
nonisolated enum AppLog {
    /// App 生命周期, Sparkle 更新, 额度刷新结果与重置次数查询
    static let app = Logger(subsystem: subsystem, category: "app")
    static let keepAlive = Logger(subsystem: subsystem, category: "keepalive")
    /// 本地 Hook 事件聚合与维护
    static let workflow = Logger(subsystem: subsystem, category: "workflow")
    /// CloudKit 同步
    static let sync = Logger(subsystem: subsystem, category: "sync")
    /// 改写用户 ~/.codex 下的 Hook 配置与信任状态
    static let hooks = Logger(subsystem: subsystem, category: "hooks")
    /// 实时任务监控, 只记低频的生命周期节点, 逐事件与逐快照的路径一律不记
    static let activity = Logger(subsystem: subsystem, category: "activity")
    /// 开机启动, 全局快捷键, Codex 自身通知配置这类用户设置
    static let settings = Logger(subsystem: subsystem, category: "settings")
    /// codex 可执行文件检测与版本读取
    static let codexCLI = Logger(subsystem: subsystem, category: "codexcli")
    /// 本地通知
    static let notification = Logger(subsystem: subsystem, category: "notification")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.zabrian.codexbar"
}

/// 一次操作的触发来源, 作为日志里的 trigger 字段
/// 同一条链路可能被用户动作 定时轮询 系统事件分别踢起来, 事后只有这个字段能区分
nonisolated enum LogTrigger: String {
    case manual
    case panelOpen
    case auto
    case launch
    case wake
    case settings
    case retry
    /// Hook 开关转为开启后补跑同步
    case hookEnabled
    case hookChanged
    case taskChanged
    case helperRegistered
    case limitReached
    case statusRefresh
}

/// 日志里耗时字段的统一取值方式, 保留两位小数并带单位
nonisolated struct LogDuration {
    private let startedAt = ContinuousClock.now

    var elapsed: String {
        Self.seconds(startedAt.duration(to: .now))
    }

    /// 已经算好的秒数走这里, 保证和 elapsed 同一种写法
    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", max(0, value))
    }

    /// 重试间隔这类 Duration 走这里, 不必在调用点各写一遍换算
    static func seconds(_ duration: Duration) -> String {
        seconds(
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
        )
    }
}
