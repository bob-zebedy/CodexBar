import Foundation

struct StatusIconState: Equatable {
    let isUnavailable: Bool
    let ordinaryUsageAllowed: Bool?
    let progress: [StatusIconProgress?]
    private let metrics: [MenuBarIndicatorMetric]

    init(loadState: CodexLoadState, snapshot: CodexQuotaSnapshot?, configuration: MenuBarIndicatorConfiguration) {
        isUnavailable = loadState.isError || snapshot?.hasTrustedData == false
        ordinaryUsageAllowed = snapshot?.ordinaryUsageAllowed
        metrics = configuration.visibleMetrics(in: snapshot?.codexLimit?.windows ?? [])
        progress = metrics.map { StatusIconProgress(snapshot: snapshot, metric: $0) }
    }

    func toolTip(at now: Date) -> String? {
        guard !metrics.isEmpty else { return nil }
        return zip(metrics, progress).map { metric, progress in
            let value = progress?.toolTipValue(at: now) ?? "--"
            return metric.isResetTime
                ? String(localized: "menu-bar-indicator.tooltip.reset", defaultValue: "\(value)")
                : String(localized: "menu-bar-indicator.tooltip.quota", defaultValue: "\(value)")
        }
        .joined(separator: " | ")
    }

    func nextRefreshDate(after now: Date) -> Date? {
        progress.compactMap { $0?.nextRefreshDate(after: now) }.min()
    }
}

struct StatusIconProgress: Equatable {
    enum Value: Equatable {
        case quota(Int)
        case reset(duration: TimeInterval, date: Date)
    }

    let value: Value
    let isStale: Bool

    init?(snapshot: CodexQuotaSnapshot?, metric: MenuBarIndicatorMetric) {
        guard let snapshot,
              let window = snapshot.codexLimit?.window(ofKind: metric.windowKind) else { return nil }
        if metric.isResetTime {
            guard let minutes = window.windowDurationMins, minutes > 0,
                  let date = window.resetsAt, date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            value = .reset(duration: Double(minutes) * 60, date: date)
        } else {
            guard window.hasData else { return nil }
            value = .quota(window.remainingPercent)
        }
        isStale = snapshot.isRateLimitsStale
    }

    func percent(at now: Date) -> Double {
        switch value {
        case let .quota(percent):
            Double(percent)
        case let .reset(duration, date):
            min(100, max(0, (1 - date.timeIntervalSince(now) / duration) * 100))
        }
    }

    func nextRefreshDate(after now: Date) -> Date? {
        guard case let .reset(_, date) = value, date > now else { return nil }
        // 在剩余分钟数变化时同步刷新进度和悬停说明, 到重置时刻补齐至满值
        let remainder = date.timeIntervalSince(now).truncatingRemainder(dividingBy: 60)
        return now.addingTimeInterval(remainder > 0 ? remainder : 60)
    }

    func toolTipValue(at now: Date) -> String {
        switch value {
        case let .quota(percent):
            return CodexPercentageFormat.string(from: percent)
        case let .reset(_, date):
            guard let minutes = Int(exactly: (max(0, date.timeIntervalSince(now)) / 60).rounded(.up)) else { return "--" }
            let days = minutes / (24 * 60)
            let hours = minutes / 60 % 24
            let remainingMinutes = minutes % 60
            if days > 0 {
                return String(localized: "menu-bar-indicator.tooltip.duration", defaultValue: "\(days) \(hours) \(remainingMinutes)")
            }
            if hours > 0 {
                return String(localized: "menu-bar-indicator.tooltip.duration-hours", defaultValue: "\(hours) \(remainingMinutes)")
            }
            if remainingMinutes > 0 {
                return String(localized: "menu-bar-indicator.tooltip.duration-minutes", defaultValue: "\(remainingMinutes)")
            }
            return String(localized: "menu-bar-indicator.tooltip.reset-now")
        }
    }
}
