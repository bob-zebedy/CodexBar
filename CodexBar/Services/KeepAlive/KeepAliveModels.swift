import Foundation
import ServiceManagement

extension KeepAliveController {
    /// 低电量保护阈值, rawValue 就是百分比; off 用 -1 与合法百分比区分
    enum LowBatteryThreshold: Int, CaseIterable, Identifiable {
        case off = -1
        case fivePercent = 5
        case tenPercent = 10
        case fifteenPercent = 15
        case twentyPercent = 20
        case twentyFivePercent = 25

        var id: Int {
            rawValue
        }

        var title: String {
            self == .off
                ? String(localized: "keep-alive.low-battery.off", defaultValue: "关闭")
                : CodexPercentageFormat.string(from: rawValue)
        }

        /// nil 表示不启用保护
        var percent: Int? {
            self == .off ? nil : rawValue
        }
    }

    enum MaximumDuration: Int, CaseIterable, Identifiable {
        case oneHour = 3600
        case twoHours = 7200
        case fourHours = 14400
        case eightHours = 28800
        case twelveHours = 43200
        case twentyFourHours = 86400
        case unlimited = -1

        var id: Int {
            rawValue
        }

        var title: String {
            guard self != .unlimited else {
                return String(
                    localized: "keep-alive.duration.unlimited",
                    defaultValue: "无限制"
                )
            }

            let hours = rawValue / 3600
            return String(
                localized: "keep-alive.duration.hours",
                defaultValue: "\(hours) 小时"
            )
        }

        /// 日志用的小时数, 与 LowBatteryThreshold 的百分比同一种可读形式, 无限制同样记 -1
        /// rawValue 是秒数, 直接记会得到 14400 这种不好读的值
        var loggedHours: Int {
            self == .unlimited ? -1 : rawValue / 3600
        }

        var timeInterval: TimeInterval? {
            self == .unlimited ? nil : TimeInterval(rawValue)
        }
    }

    enum HelperStatus: Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound

        var isRegisteredOrAwaitingApproval: Bool {
            self == .enabled || self == .requiresApproval
        }

        init(_ status: SMAppService.Status) {
            switch status {
            case .notRegistered:
                self = .notRegistered
            case .enabled:
                self = .enabled
            case .requiresApproval:
                self = .requiresApproval
            case .notFound:
                self = .notFound
            @unknown default:
                self = .notFound
            }
        }
    }

    /// 防睡眠没生效时缺的是哪一项, 同时充当日志里的 reason= 取值
    enum SleepBlockReason: String {
        case notStarted
        case userOff
        case hookDisabled
        case noTasks
        case helperUnavailable
        case helperRefreshing
        case terminating
        case lowBattery
        case limitReached
    }

    /// shouldDisableSleep 的求值结果与它依赖的各项, 只用于变化检测与日志
    /// blockReason 与 shouldDisableSleep 同源, 不会出现"字段都满足却报某项缺失"
    /// battery 只放布尔: 放电量百分比会让每掉 1% 都记一条
    struct SleepConditions: Equatable {
        let blockReason: SleepBlockReason?
        let enabled: Bool
        let hook: Bool
        let tasks: Bool
        let helper: HelperStatus
        let refreshing: Bool
        let battery: Bool
        let limited: Bool
    }
}

nonisolated enum KeepAliveLocalizedMessage {
    static let helperAssetsMissing = String(
        localized: "keep-alive.error.helper-assets-missing",
        defaultValue: "服务异常, 请重新安装 CodexBar"
    )
    static let registrationFailed = String(
        localized: "keep-alive.error.registration-failed",
        defaultValue: "注册服务失败"
    )
    static let updateFailed = String(
        localized: "keep-alive.error.update-failed",
        defaultValue: "更新服务失败"
    )
    static let preventIdleSleepFailed = String(
        localized: "keep-alive.error.prevent-idle-sleep-failed",
        defaultValue: "防止空闲睡眠失败"
    )
    static let toggleSleepFailed = String(
        localized: "keep-alive.error.toggle-sleep-failed",
        defaultValue: "切换睡眠状态失败"
    )
    static let restoreIdleSleepFailed = String(
        localized: "keep-alive.error.restore-idle-sleep-failed",
        defaultValue: "恢复空闲睡眠策略失败"
    )
    static let requestSystemSleepFailed = String(
        localized: "keep-alive.error.request-system-sleep-failed",
        defaultValue: "请求系统睡眠失败"
    )
    static let connectionFailed = String(
        localized: "keep-alive.error.connection-failed",
        defaultValue: "连接服务失败"
    )
    static let noResponse = String(
        localized: "keep-alive.error.no-response",
        defaultValue: "服务无响应"
    )
    static let retryLimitReached = String(
        localized: "keep-alive.error.retry-limit-reached",
        defaultValue: "防睡眠多次失败, 已停止重试"
    )
    static let invalidHelperInterface = String(
        localized: "keep-alive.error.invalid-helper-interface",
        defaultValue: "服务接口无效"
    )
    static let connectionInterrupted = String(
        localized: "keep-alive.error.connection-interrupted",
        defaultValue: "服务连接中断"
    )
    static let autoResetWakeScheduleFailed = String(
        localized: "keep-alive.error.auto-reset-wake-schedule-failed",
        defaultValue: "设置自动重置唤醒计划失败"
    )
}

nonisolated enum KeepAliveError: LocalizedError {
    case invalidHelperProxy
    case connectionInterrupted
    case wakeScheduleCancellationFailed

    var errorDescription: String? {
        switch self {
        case .invalidHelperProxy:
            KeepAliveLocalizedMessage.invalidHelperInterface
        case .connectionInterrupted:
            KeepAliveLocalizedMessage.connectionInterrupted
        case .wakeScheduleCancellationFailed:
            KeepAliveLocalizedMessage.autoResetWakeScheduleFailed
        }
    }
}
