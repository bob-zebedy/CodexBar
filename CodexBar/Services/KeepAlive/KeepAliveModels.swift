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
                ? String(localized: "keep-alive.low-battery.off")
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
                return String(localized: "keep-alive.duration.unlimited")
            }

            let hours = rawValue / 3600
            return String(
                localized: "keep-alive.duration.hours",
                defaultValue: "\(hours)"
            )
        }

        /// 日志以小时记录时限, 与 LowBatteryThreshold 一样用 -1 表示无限制或未启用
        /// rawValue 使用秒数, 日志转换为小时便于阅读
        var loggedHours: Int {
            self == .unlimited ? -1 : rawValue / 3600
        }

        var timeInterval: TimeInterval? {
            self == .unlimited ? nil : TimeInterval(rawValue)
        }
    }

    enum PowerHelperStatus: Equatable {
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

    enum PowerHelperInstallationStatus: Equatable {
        case notInstalled
        case authorized
        case requiresApproval
        case unavailable(String)

        init(registration: PowerHelperStatus, packageIssue: PowerHelperPackageIssue?, registrationError: String?) {
            if let packageIssue {
                self = .unavailable(packageIssue.message)
                return
            }
            switch registration {
            case .enabled:
                self = .authorized
            case .requiresApproval:
                self = .requiresApproval
            case .notRegistered, .notFound:
                // 系统尚无后台注册记录时也会返回 notFound
                self = registrationError.map(Self.unavailable) ?? .notInstalled
            }
        }
    }

    /// 防睡眠未生效的原因, 同时用作日志中的 reason= 取值
    enum SleepBlockReason: String {
        case notStarted
        case userOff
        case noTasks
        case powerHelperUnavailable
        case powerHelperRefreshing
        case terminating
        case lowBattery
        case limitReached
    }

    /// shouldDisableSleep 的求值结果与它依赖的各项, 只用于变化检测与日志
    /// blockReason 与 shouldDisableSleep 共用判定规则, 保持结果与依赖状态一致
    /// battery 只保存布尔状态, 避免电量每次变化都触发日志
    struct SleepConditions: Equatable {
        let blockReason: SleepBlockReason?
        let enabled: Bool
        let tasks: Bool
        let powerHelper: PowerHelperStatus
        let refreshing: Bool
        let battery: Bool
        let limited: Bool
    }
}

nonisolated enum PowerHelperPackageIssue: Equatable, Sendable {
    case missing
    case invalid

    var message: String {
        switch self {
        case .missing:
            KeepAliveLocalizedMessage.powerHelperAssetsMissing
        case .invalid:
            KeepAliveLocalizedMessage.powerHelperAssetsInvalid
        }
    }
}

nonisolated enum KeepAliveLocalizedMessage {
    static let powerHelperAssetsMissing = String(localized: "power-helper.error.assets-missing")
    static let powerHelperAssetsInvalid = String(localized: "power-helper.error.assets-invalid")
    static let registrationFailed = String(localized: "power-helper.error.registration-failed")
    static let updateFailed = String(localized: "power-helper.error.update-failed")
    static let preventIdleSleepFailed = String(localized: "keep-alive.error.prevent-idle-sleep-failed")
    static let toggleSleepFailed = String(localized: "keep-alive.error.toggle-sleep-failed")
    static let restoreIdleSleepFailed = String(localized: "keep-alive.error.restore-idle-sleep-failed")
    static let connectionFailed = String(localized: "power-helper.error.connection-failed")
    static let noResponse = String(localized: "power-helper.error.no-response")
    static let retryLimitReached = String(localized: "keep-alive.error.retry-limit-reached")
    static let invalidPowerHelperInterface = String(localized: "power-helper.error.invalid-interface")
    static let connectionInterrupted = String(localized: "power-helper.error.connection-interrupted")
    static let autoResetWakeScheduleFailed = String(localized: "auto-reset.error.wake-schedule-failed")
}

nonisolated enum KeepAliveError: LocalizedError {
    case invalidPowerHelperProxy
    case connectionInterrupted
    case wakeScheduleCancellationFailed

    var errorDescription: String? {
        switch self {
        case .invalidPowerHelperProxy:
            KeepAliveLocalizedMessage.invalidPowerHelperInterface
        case .connectionInterrupted:
            KeepAliveLocalizedMessage.connectionInterrupted
        case .wakeScheduleCancellationFailed:
            KeepAliveLocalizedMessage.autoResetWakeScheduleFailed
        }
    }
}
