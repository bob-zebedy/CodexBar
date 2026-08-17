import Combine
import Foundation
import os

nonisolated enum AutoResetLeadTime: Int, CaseIterable, Hashable, Sendable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400
    case sixHours = 21600

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    var title: String {
        switch self {
        case .fifteenMinutes:
            String(localized: "auto-reset.lead-time.fifteen-minutes")
        case .thirtyMinutes:
            String(localized: "auto-reset.lead-time.thirty-minutes")
        case .oneHour:
            String(localized: "auto-reset.lead-time.one-hour")
        case .twoHours:
            String(localized: "auto-reset.lead-time.two-hours")
        case .fourHours:
            String(localized: "auto-reset.lead-time.four-hours")
        case .sixHours:
            String(localized: "auto-reset.lead-time.six-hours")
        }
    }
}

/// 自动重置的本机设置
@MainActor
final class AutoResetSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var leadTime: AutoResetLeadTime

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        leadTime = Self.loadLeadTime(from: defaults)
    }

    func refresh() {
        let isEnabled = defaults.bool(forKey: Self.enabledKey)
        if isEnabled != self.isEnabled {
            self.isEnabled = isEnabled
        }

        let leadTime = Self.loadLeadTime(from: defaults)
        if leadTime != self.leadTime {
            self.leadTime = leadTime
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        AppLog.settings.notice("自动重置变更: enabled=\(enabled ? 1 : 0)")
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func setLeadTime(_ leadTime: AutoResetLeadTime) {
        guard leadTime != self.leadTime else {
            return
        }

        AppLog.settings.notice("自动重置临期时间变更: seconds=\(leadTime.rawValue)")
        self.leadTime = leadTime
        defaults.set(leadTime.rawValue, forKey: Self.leadTimeKey)
    }

    private static func loadLeadTime(from defaults: UserDefaults) -> AutoResetLeadTime {
        guard let storedValue = defaults.object(forKey: leadTimeKey) else {
            return defaultLeadTime
        }
        guard let rawValue = storedValue as? Int,
              let leadTime = AutoResetLeadTime(rawValue: rawValue) else {
            defaults.set(defaultLeadTime.rawValue, forKey: leadTimeKey)
            return defaultLeadTime
        }

        return leadTime
    }

    private static let enabledKey = "AutoReset.enabled"
    private static let leadTimeKey = "AutoReset.leadTimeSeconds"
    private static let defaultLeadTime = AutoResetLeadTime.thirtyMinutes
}
