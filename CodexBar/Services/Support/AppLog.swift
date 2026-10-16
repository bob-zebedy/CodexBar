import Foundation
import os

/// App 侧统一的系统日志出口, 与 app-server 链路的日志窗口分工明确
/// 用户可见的错误文案只留步骤名, 定位问题需要的细节写到这里
/// subsystem 取 bundle identifier, Debug 与 Release 两套装置的日志因此天然分开
nonisolated enum AppLog {
    /// App 生命周期, Sparkle 更新, 额度刷新结果与重置次数查询
    static let app = Logger(subsystem: subsystem, category: "app")
    static let keepAlive = Logger(subsystem: subsystem, category: "keepalive")
    /// 本地 活动事件聚合与维护
    static let history = Logger(subsystem: subsystem, category: "history")
    /// CloudKit 同步
    static let sync = Logger(subsystem: subsystem, category: "sync")
    /// 实时任务监控, 只记低频的生命周期节点, 逐事件与逐快照的路径一律不记
    static let activity = Logger(subsystem: subsystem, category: "activity")
    /// 开机启动, 全局快捷键, Codex 自身通知配置这类用户设置
    static let settings = Logger(subsystem: subsystem, category: "settings")
    /// codex 可执行文件检测与版本读取
    static let codex = Logger(subsystem: subsystem, category: "codex")
    /// 本地通知
    static let notification = Logger(subsystem: subsystem, category: "notification")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.zabrian.codexbar"
}

nonisolated enum LogFields {
    static func joined(_ fields: String...) -> String {
        fields.joined(separator: "; ")
    }

    static func joined(_ fields: [String]) -> String {
        fields.joined(separator: "; ")
    }
}

/// 记录操作触发来源, 区分同一链路的用户动作, 定时轮询和系统事件
nonisolated enum LogTrigger: String {
    case manual
    case panelOpen
    case auto
    case launch
    case wake
    case settings
    case retry
    case taskChanged
    case powerHelperRegistered
    case termination
    case limitReached
    /// 电量或供电方式变化
    case battery
    case accountNotification
    case statusRefresh
    case autoReset
}

/// 日志里耗时字段的统一取值方式, 保留两位小数并带单位
nonisolated struct LogDuration {
    private let startedAt = ContinuousClock.now

    var elapsed: String {
        Self.seconds(startedAt.duration(to: .now))
    }

    /// 秒数与 elapsed 使用相同的日志格式
    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", max(0, value))
    }

    static func seconds(_ duration: Duration) -> String {
        seconds(TimeInterval(duration))
    }
}

nonisolated extension TimeInterval {
    init(_ duration: Duration) {
        self = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
