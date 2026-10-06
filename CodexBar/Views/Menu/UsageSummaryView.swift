import SwiftUI

// MARK: - 摘要区

/// Token 摘要和近期用量热力图的组合区
struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot?
    let isStale: Bool
    let showsActivity: Bool
    let onHoverContextChange: (UsageHeatmapHoverContext?) -> Void
    private let days: [UsageHeatmapDay?]
    private let peakTokens: Int
    @State private var hoverSelection: UsageHeatmapSelection?
    @State private var heatmapScreenFrame: CGRect?

    init(
        usage: CodexUsageSnapshot?,
        history: HistorySnapshot,
        showsActivity: Bool,
        isStale: Bool = false,
        onHoverContextChange: @escaping (UsageHeatmapHoverContext?) -> Void = { _ in }
    ) {
        self.usage = usage
        self.isStale = isStale
        self.showsActivity = showsActivity
        self.onHoverContextChange = onHoverContextChange

        let days = UsageHeatmapDay.grid(
            usage: usage,
            history: history,
            showsActivity: showsActivity,
            columnCount: UsageHeatmap.Metrics.columnCount,
            today: Date()
        )
        self.days = days
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
                refreshHoveredDay(from: newDays)
            }
            .onChange(of: hoverContext) { _, context in
                onHoverContextChange(context)
            }
            .animation(Metrics.statusAnimation, value: usage)
            .animation(Metrics.statusAnimation, value: days)
    }

    @ViewBuilder
    private var content: some View {
        if usage?.hasAppServerData == true || showsActivity {
            VStack(alignment: .leading, spacing: 8) {
                metricsGrid

                if usage?.hasDailyUsageBuckets == true || showsActivity {
                    UsageHeatmap(
                        days: days,
                        selection: $hoverSelection,
                        peakTokens: peakTokens,
                        onScreenFrameChange: { frame in
                            heatmapScreenFrame = frame
                        }
                    )
                } else {
                    dailyUsageUnavailable
                }
            }
        } else {
            Text("common.empty.no-data")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, MenuMetrics.loadingVerticalPadding)
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
                label: "usage.summary.longest-chat",
                value: Self.durationText(seconds: usage?.summary.longestRunningTurnSec)
            )
        }
    }

    private func tokenMetric(label: LocalizedStringResource, value: Int?) -> some View {
        metric(label: label) {
            if let value {
                TokenCountText(tokens: value)
                    .minimumScaleFactor(0.8)
            } else {
                Text(verbatim: "--")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
    }

    private var dailyUsageUnavailable: some View {
        Text("usage.heatmap.no-data")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: UsageHeatmap.Metrics.height)
    }

    private func textMetric(label: LocalizedStringResource, value: String) -> some View {
        metric(label: label) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
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
        hoverSelection.map {
            UsageHeatmapHoverContext(
                day: $0.day,
                showsActivity: showsActivity,
                alignmentScreenFrame: heatmapScreenFrame,
                preferredSide: UsageHeatmap.Metrics.preferredDetailSide(for: $0.column),
                peakTokens: peakTokens
            )
        }
    }

    private func refreshHoveredDay(from days: [UsageHeatmapDay?]) {
        guard let hoverSelection else {
            return
        }

        guard let updatedDay = days.compactMap(\.self).first(where: { $0.id == hoverSelection.day.id }) else {
            withAnimation(Metrics.statusAnimation) {
                self.hoverSelection = nil
            }
            return
        }

        guard updatedDay != hoverSelection.day else {
            return
        }

        withAnimation(Metrics.statusAnimation) {
            self.hoverSelection = UsageHeatmapSelection(
                day: updatedDay,
                column: hoverSelection.column,
                row: hoverSelection.row
            )
        }
    }

    private func clearHover() {
        hoverSelection = nil
        onHoverContextChange(nil)
    }
}
