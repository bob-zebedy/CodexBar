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
    /// 本地通知投递
    static let notification = Logger(subsystem: subsystem, category: "notification")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.zabrian.codexbar"
}
