import SwiftUI

// MARK: - 摘要区

/// Token 摘要和近期用量热力图的组合区
struct UsageSummaryView: View {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    let usage: CodexUsageSnapshot?
    let isStale: Bool
    let onHoverContextChange: (UsageHeatmapHoverContext?) -> Void
    private let days: [UsageHeatmapDay?]
    private let peakTokens: Int
    private let weeks: [UsageHeatmapPeriod?]
    private let peakWeeklyTokens: Int
    @Binding var mode: UsageHeatmapMode
    @State private var hoverSelection: UsageHeatmapSelection?
    @State private var heatmapScreenFrame: CGRect?

    init(
        usage: CodexUsageSnapshot?,
        history: HistorySnapshot,
        mode: Binding<UsageHeatmapMode>,
        isStale: Bool = false,
        onHoverContextChange: @escaping (UsageHeatmapHoverContext?) -> Void = { _ in }
    ) {
        self.usage = usage
        _mode = mode
        self.isStale = isStale
        self.onHoverContextChange = onHoverContextChange

        let days = UsageHeatmapDay.grid(
            usage: usage,
            history: history,
            columnCount: UsageHeatmap.Metrics.columnCount,
            today: Date()
        )
        self.days = days
        let weeks = UsageHeatmapPeriod.weeks(in: days)
        self.weeks = weeks
        peakWeeklyTokens = max(weeks.lazy.compactMap { $0?.tokensForHeatmap }.max() ?? 0, 1)
        peakTokens = max(days.lazy.compactMap { $0?.tokensForHeatmap }.max() ?? 0, 1)
    }

    var body: some View {
        content
            .markStale(isStale)
            .padding(MenuMetrics.panelPadding)
            .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
            .onAppear {
                clearHover()
            }
            .onDisappear {
                clearHover()
            }
            .onChange(of: days) { _, newDays in
                clearMissingHoverSelection(in: newDays)
            }
            .onChange(of: hoverContext) { _, context in
                onHoverContextChange(context)
            }
            .animation(allowsAnimations ? Metrics.statusAnimation : nil, value: usage)
            .animation(allowsAnimations ? Metrics.statusAnimation : nil, value: days)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricsGrid
            UsageHeatmap(
                days: days,
                weeks: weeks,
                mode: $mode,
                selection: $hoverSelection,
                peakTokens: mode == .daily ? peakTokens : peakWeeklyTokens,
                onScreenFrameChange: { frame in
                    heatmapScreenFrame = frame
                }
            )
        }
    }

    private var metricsGrid: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.metricSpacing) {
            tokenMetric(label: "usage.summary.lifetime-tokens", value: usage?.summary.lifetimeTokens)
            tokenMetric(label: "usage.summary.peak-tokens", value: usage?.summary.peakDailyTokens)
            textMetric(
                label: "usage.summary.current-streak",
                value: Self.dayText(usage?.summary.currentStreakDays)
            )
            textMetric(
                label: "usage.summary.longest-streak",
                value: Self.dayText(usage?.summary.longestStreakDays)
            )
            textMetric(
                label: "usage.summary.longest-turn",
                value: Self.durationText(seconds: usage?.summary.longestRunningTurnSec)
            )
        }
    }

    private func tokenMetric(label: LocalizedStringResource, value: Int?) -> some View {
        metric(label: label) {
            if let value {
                TokenCountText(tokens: value)
                    .foregroundStyle(Color.codexLabel)
                    .minimumScaleFactor(0.8)
            } else {
                Text(verbatim: "--")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private func textMetric(label: LocalizedStringResource, value: String) -> some View {
        metric(label: label) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.codexLabel)
                .numericTransition(value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func metric(
        label: LocalizedStringResource,
        @ViewBuilder value: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            value()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private static func dayText(_ days: Int?) -> String {
        guard let days else {
            return "--"
        }

        return String(localized: "duration.days-compact", defaultValue: "\(max(days, 0), specifier: "%lld")")
    }

    private static func durationText(seconds: Int?) -> String {
        guard let seconds else {
            return "--"
        }

        return CodexDurationFormat.activityText(for: TimeInterval(seconds))
    }

    private enum Metrics {
        static let metricSpacing: CGFloat = 8
        static let statusAnimation = Animation.codexStatus
    }

    private var hoverContext: UsageHeatmapHoverContext? {
        // 详情面板由控制器显示, SwiftUI 这里只负责传递屏幕坐标和数据
        guard let hoverSelection,
              let column = hoverSelection.currentColumn(in: days),
              let period = hoverSelection.period(in: days, weeks: weeks, mode: mode) else { return nil }
        return UsageHeatmapHoverContext(
            period: period,
            mode: mode,
            isStale: isStale,
            alignmentScreenFrame: heatmapScreenFrame,
            preferredSide: UsageHeatmap.Metrics.preferredDetailSide(for: column),
            peakTokens: mode == .daily ? peakTokens : peakWeeklyTokens
        )
    }

    private func clearMissingHoverSelection(in days: [UsageHeatmapDay?]) {
        guard let hoverSelection, hoverSelection.day(in: days) == nil else { return }
        withAnimation(Metrics.statusAnimation) {
            self.hoverSelection = nil
        }
    }

    private func clearHover() {
        hoverSelection = nil
        onHoverContextChange(nil)
    }
}
