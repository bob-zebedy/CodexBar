import Combine
import Foundation
import os

nonisolated enum MenuBarIndicatorCount: Int, CaseIterable {
    case one = 1
    case two = 2

    var title: String {
        switch self {
        case .one: String(localized: "menu-bar-indicator.layout.single")
        case .two: String(localized: "menu-bar-indicator.layout.dual")
        }
    }
}

nonisolated enum MenuBarIndicatorMetric: String {
    case primaryQuota
    case secondaryQuota
    case primaryReset
    case secondaryReset

    var windowKind: QuotaWindowKind {
        switch self {
        case .primaryQuota, .primaryReset: .primary
        case .secondaryQuota, .secondaryReset: .secondary
        }
    }

    var isResetTime: Bool {
        self == .primaryReset || self == .secondaryReset
    }

    init(windowKind: QuotaWindowKind, isResetTime: Bool) {
        switch (windowKind, isResetTime) {
        case (.primary, false): self = .primaryQuota
        case (.secondary, false): self = .secondaryQuota
        case (.primary, true): self = .primaryReset
        case (.secondary, true): self = .secondaryReset
        }
    }
}

nonisolated struct MenuBarIndicatorConfiguration: Equatable {
    var isEnabled = false
    var count = MenuBarIndicatorCount.one
    var firstMetric: MenuBarIndicatorMetric?
    var secondMetric: MenuBarIndicatorMetric?

    func metrics(in windows: [QuotaWindow]) -> [MenuBarIndicatorMetric] {
        // Weekly 可能位于 primary 或 secondary, 未手动选择时按实际周期解析默认值
        let defaultWindow = windows.first { $0.windowDurationMins == 7 * 24 * 60 }?.kind
            ?? windows.first?.kind ?? .secondary
        return [
            firstMetric ?? MenuBarIndicatorMetric(windowKind: defaultWindow, isResetTime: false),
            secondMetric ?? MenuBarIndicatorMetric(windowKind: defaultWindow, isResetTime: true)
        ]
    }

    func visibleMetrics(in windows: [QuotaWindow]) -> [MenuBarIndicatorMetric] {
        isEnabled ? Array(metrics(in: windows).prefix(count.rawValue)) : []
    }
}

@MainActor
final class MenuBarIndicatorSettings: ObservableObject {
    @Published private(set) var configuration: MenuBarIndicatorConfiguration
    private let defaults: UserDefaults
    private var pendingConfiguration: MenuBarIndicatorConfiguration?
    private var publishTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = Self.load(from: defaults)
    }

    deinit {
        publishTask?.cancel()
    }

    func refresh() {
        publish(Self.load(from: defaults))
    }

    func setCount(_ count: MenuBarIndicatorCount) {
        var next = pendingConfiguration ?? configuration
        next.count = count
        save(next)
    }

    func setEnabled(_ enabled: Bool) {
        var next = pendingConfiguration ?? configuration
        next.isEnabled = enabled
        save(next)
    }

    func setMetric(isResetTime: Bool? = nil, windowKind: QuotaWindowKind? = nil, at index: Int, windows: [QuotaWindow]) {
        guard (0 ... 1).contains(index) else { return }
        var next = pendingConfiguration ?? configuration
        let current = next.metrics(in: windows)[index]
        let metric = MenuBarIndicatorMetric(
            windowKind: windowKind ?? current.windowKind,
            isResetTime: isResetTime ?? current.isResetTime
        )
        if index == 0 {
            next.firstMetric = metric
        } else {
            next.secondMetric = metric
        }
        save(next)
    }

    private func save(_ next: MenuBarIndicatorConfiguration) {
        guard next != pendingConfiguration ?? configuration else { return }
        defaults.set(next.isEnabled, forKey: Self.enabledKey)
        defaults.set(next.count.rawValue, forKey: Self.countKey)
        defaults.set(next.firstMetric?.rawValue, forKey: Self.firstMetricKey)
        defaults.set(next.secondMetric?.rawValue, forKey: Self.secondMetricKey)
        AppLog.settings.notice(
            "菜单栏指示器变更: enabled=\(next.isEnabled), count=\(next.count.rawValue), first=\(next.firstMetric?.rawValue ?? "default", privacy: .public), second=\(next.secondMetric?.rawValue ?? "default", privacy: .public)"
        )
        publish(next)
    }

    private func publish(_ next: MenuBarIndicatorConfiguration) {
        publishTask?.cancel()
        publishTask = nil
        pendingConfiguration = nil
        guard next != configuration else { return }
        pendingConfiguration = next
        // Picker 的回调可能仍在 SwiftUI 更新中, 合并同一轮修改后再发布
        publishTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            configuration = next
            pendingConfiguration = nil
            publishTask = nil
        }
    }

    private static func load(from defaults: UserDefaults) -> MenuBarIndicatorConfiguration {
        MenuBarIndicatorConfiguration(
            isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
            count: (defaults.object(forKey: countKey) as? Int).flatMap(MenuBarIndicatorCount.init(rawValue:)) ?? .one,
            firstMetric: defaults.string(forKey: firstMetricKey).flatMap(MenuBarIndicatorMetric.init(rawValue:)),
            secondMetric: defaults.string(forKey: secondMetricKey).flatMap(MenuBarIndicatorMetric.init(rawValue:))
        )
    }

    private static let enabledKey = "MenuBarIndicator.isEnabled"
    private static let countKey = "MenuBarIndicator.count"
    private static let firstMetricKey = "MenuBarIndicator.firstMetric"
    private static let secondMetricKey = "MenuBarIndicator.secondMetric"
}
