import Combine
import Foundation
import os

/// 异常任务保护跟随防睡眠开关, 此处只管理静默阈值
@MainActor
final class ActivityProtectionSettings: ObservableObject {
    @Published private(set) var inactivityDuration: InactivityDuration

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inactivityDuration = Self.storedDuration(in: defaults)
    }

    func setInactivityDuration(_ duration: InactivityDuration) {
        guard duration != inactivityDuration else {
            return
        }

        inactivityDuration = duration
        defaults.set(duration.rawValue, forKey: Self.inactivityDurationKey)
        AppLog.activity.notice(
            "异常任务静默阈值变更: minutes=\(duration.loggedMinutes)"
        )
    }

    func refresh() {
        let storedDuration = Self.storedDuration(in: defaults)
        guard storedDuration != inactivityDuration else {
            return
        }
        inactivityDuration = storedDuration
    }

    private static func storedDuration(in defaults: UserDefaults) -> InactivityDuration {
        (defaults.object(forKey: inactivityDurationKey) as? Int)
            .flatMap(InactivityDuration.init(rawValue:)) ?? .oneHour
    }

    private static let inactivityDurationKey = "KeepAlive.abnormalTaskInactivitySeconds"
}

extension ActivityProtectionSettings {
    enum InactivityDuration: Int, CaseIterable, Identifiable {
        case thirtyMinutes = 1800
        case oneHour = 3600
        case twoHours = 7200
        case fourHours = 14400

        var id: Int {
            rawValue
        }

        var timeInterval: TimeInterval {
            TimeInterval(rawValue)
        }

        var loggedMinutes: Int {
            rawValue / 60
        }

        var title: String {
            if self == .thirtyMinutes {
                return String(localized: "activity-protection.duration.thirty-minutes")
            }

            let hours = rawValue / 3600
            return String(
                localized: "activity-protection.duration.hours",
                defaultValue: "\(hours)"
            )
        }
    }
}
