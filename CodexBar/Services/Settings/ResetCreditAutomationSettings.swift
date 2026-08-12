import Combine
import Foundation
import os

nonisolated enum ResetCreditAutomationLeadTime: Int, CaseIterable, Hashable, Sendable {
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400
    case sixHours = 21600
    case twelveHours = 43200

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    var title: String {
        switch self {
        case .thirtyMinutes:
            String(localized: "30 分钟")
        case .oneHour:
            String(localized: "1 小时")
        case .twoHours:
            String(localized: "2 小时")
        case .fourHours:
            String(localized: "4 小时")
        case .sixHours:
            String(localized: "6 小时")
        case .twelveHours:
            String(localized: "12 小时")
        }
    }
}

/// 自动使用临期重置的本机设置
@MainActor
final class ResetCreditAutomationSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var leadTime: ResetCreditAutomationLeadTime

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

        AppLog.settings.notice("自动使用重置变更: enabled=\(enabled ? 1 : 0)")
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    func setLeadTime(_ leadTime: ResetCreditAutomationLeadTime) {
        guard leadTime != self.leadTime else {
            return
        }

        AppLog.settings.notice("自动使用重置临期时间变更: seconds=\(leadTime.rawValue)")
        self.leadTime = leadTime
        defaults.set(leadTime.rawValue, forKey: Self.leadTimeKey)
    }

    private static func loadLeadTime(from defaults: UserDefaults) -> ResetCreditAutomationLeadTime {
        guard let rawValue = defaults.object(forKey: leadTimeKey) as? Int,
              let leadTime = ResetCreditAutomationLeadTime(rawValue: rawValue) else {
            return .twoHours
        }

        return leadTime
    }

    private static let enabledKey = "ResetCreditAutomation.enabled"
    private static let leadTimeKey = "ResetCreditAutomation.leadTimeSeconds"
}
