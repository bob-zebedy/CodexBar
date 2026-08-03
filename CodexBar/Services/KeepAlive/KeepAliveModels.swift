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
}
