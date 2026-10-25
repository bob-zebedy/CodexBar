import SwiftUI

struct HeatmapDetailView: View {
    let context: UsageHeatmapHoverContext
    let mainPanelSettings: MainPanelSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let panelSize = Self.panelSize

        activityContent
            .markStale(context.isStale)
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .frame(
                width: panelSize.width,
                height: panelSize.height,
                alignment: .topLeading
            )
            .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
            .animation(Metrics.statusAnimation, value: context)
            .contentAnimations(settings: mainPanelSettings)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static var panelSize: CGSize {
        CGSize(width: Metrics.activityPanelWidth, height: Metrics.activityPanelHeight)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            dateText
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .liquidGlassCapsule(tint: .accentColor)

            Spacer(minLength: 8)

            tokenText
        }
    }

    private var activityContent: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header

            LiquidGlassDivider()
                .opacity(0.72)

            tokenIntensityMetricRow

            HStack(alignment: .top, spacing: Metrics.columnSpacing) {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    columnTitle("usage.heatmap.activity-data-metrics")
                    Grid(alignment: .leading, horizontalSpacing: Metrics.metricRowSpacing, verticalSpacing: Metrics.metricSpacing) {
                        mostUsedModelMetricRow
                        ForEach(activityMetricRows) { row in
                            metricRow(row)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    columnTitle("usage.heatmap.token-usage-metrics")
                    tokenUsageMetrics
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(height: Metrics.columnHeight)
        }
    }

    private func columnTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.codexSecondaryLabel)
            .frame(height: Metrics.metricRowHeight)
    }

    private var tokenUsageMetrics: some View {
        let tokenUsage = context.period.tokenUsage
        let cacheHitRate = tokenUsage?.cacheHitRate ?? 0
        return Grid(alignment: .leading, horizontalSpacing: Metrics.metricRowSpacing, verticalSpacing: Metrics.metricSpacing) {
            tokenUsageRow("usage.token-usage.total", tokens: tokenUsage?.totalTokens, tint: .blue)
            tokenUsageRow("usage.token-usage.output", tokens: tokenUsage?.outputTokens, tint: .orange)
            tokenUsageRow("usage.token-usage.input", tokens: tokenUsage?.inputTokens, tint: .indigo)
            tokenUsageRow("usage.token-usage.reasoning-output", tokens: tokenUsage?.reasoningOutputTokens, tint: .cyan)
            tokenUsageRow("usage.token-usage.cache-write-input", tokens: tokenUsage?.cacheWriteInputTokens, tint: .purple)
            tokenUsageRow("usage.token-usage.cached-input", tokens: tokenUsage?.cachedInputTokens, tint: .green)
            metricRowLayout {
                metricDot(tint: .teal)
                Text("usage.token-usage.cache-hit-rate")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: Metrics.metricRowHeight)
                fittingMetricValue(
                    cacheHitRate.formatted(.percent.precision(.fractionLength(0 ... 1))),
                    comparison: cacheHitRate
                )
            }
        }
    }

    private func tokenUsageRow(_ title: LocalizedStringKey, tokens: Int64?, tint: Color) -> some View {
        let count = tokens ?? 0
        return metricRowLayout {
            metricDot(tint: tint)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Metrics.metricRowHeight)
            fittingMetricValue(TokenCountFormatter.text(from: Int(count)), comparison: Double(count))
        }
    }

    private var tokenIntensityMetricRow: some View {
        tokenIntensityStrip
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.metricRowHeight)
    }

    private var mostUsedModelMetricRow: some View {
        metricRowLayout {
            metricDot(tint: .cyan)
            Text("usage.heatmap.top-model")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Metrics.metricRowHeight)

            fittingModelValue(context.period.activityData.mostUsedModel ?? "--")
        }
    }

    private func metricRowLayout(@ViewBuilder content: () -> some View) -> some View {
        GridRow(content: content)
            .font(.system(size: Metrics.activityFontSize))
    }

    private func metricDot(tint: Color, darkOpacity: Double = 0.86, lightOpacity: Double = 0.72) -> some View {
        Circle()
            .fill(tint.opacity(colorScheme == .dark ? darkOpacity : lightOpacity))
            .frame(width: Metrics.metricDotSize, height: Metrics.metricDotSize)
    }

    private var tokenIntensityStrip: some View {
        HStack(spacing: Metrics.tokenIntensitySegmentSpacing) {
            ForEach(0 ..< Metrics.tokenIntensitySegmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tokenIntensityFill(for: index))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: Metrics.tokenIntensityStripHeight)
    }

    private var activityMetricRows: [ActivityMetricRow] {
        [
            ActivityMetricRow(
                label: String(localized: "history.activity-data.threads"),
                value: context.period.activityData.threadCount,
                tint: .green
            ),
            ActivityMetricRow(
                label: String(localized: "history.activity-data.turns"),
                value: context.period.activityData.turnCount,
                tint: .teal
            ),
            ActivityMetricRow(
                label: String(localized: "history.activity-data.subagents"),
                value: context.period.activityData.subagentCount,
                tint: .indigo
            ),
            ActivityMetricRow(
                label: String(localized: "history.activity-data.tool-calls"),
                value: context.period.activityData.toolCallCount,
                tint: .orange
            ),
            ActivityMetricRow(
                label: String(localized: "history.activity-data.approvals"),
                value: context.period.activityData.approvalRequestedCount,
                tint: .red
            ),
            ActivityMetricRow(
                label: String(localized: "history.activity-data.compactions"),
                value: context.period.activityData.contextCompactionCount,
                tint: .purple
            )
        ]
    }

    private var dateText: some View {
        HStack(spacing: 0) {
            AnimatedDateText(startDate: context.period.startDate, font: dateFont)
            if context.mode == .weekly {
                Text(verbatim: " ~ ")
                    .font(dateFont)
                AnimatedDateText(startDate: context.period.endDate, font: dateFont)
            }
        }
        .foregroundStyle(Color.codexSecondaryLabel)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private var tokenText: some View {
        HeatmapTokenText(
            tokenState: context.period.tokenState,
            font: tokenFont,
            minimumWidth: Metrics.tokenMinimumWidth
        )
    }

    private var dateFont: Font {
        .caption2.monospacedDigit()
    }

    private var tokenFont: Font {
        .system(size: 14).monospacedDigit().weight(.semibold)
    }

    private var tokenIntensityLevel: Int {
        guard context.period.tokensForHeatmap > 0 else {
            return 0
        }

        let percent = tokenIntensityPercent
        return min(
            Metrics.tokenIntensitySegmentCount,
            max(1, Int(ceil(percent * Double(Metrics.tokenIntensitySegmentCount))))
        )
    }

    private var tokenIntensityPercent: Double {
        guard context.peakTokens > 0 else {
            return 0
        }

        return min(max(Double(context.period.tokensForHeatmap) / Double(context.peakTokens), 0), 1)
    }

    private func tokenIntensityFill(for index: Int) -> Color {
        guard context.period.tokenState.count != nil else {
            return Color.secondary.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }

        guard index < tokenIntensityLevel else {
            return Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.10)
        }

        let position = Double(index) / Double(Metrics.tokenIntensitySegmentCount - 1)
        let opacity = colorScheme == .dark ? 0.42 + position * 0.40 : 0.34 + position * 0.36
        return Color.blue.opacity(min(opacity, 0.88))
    }

    private func metricRow(_ row: ActivityMetricRow) -> some View {
        let count = row.value ?? (context.mode == .daily ? 0 : nil)
        return metricRowLayout {
            metricDot(tint: row.tint)
            Text(row.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Metrics.metricRowHeight)

            fittingMetricValue(count.map(String.init) ?? "--", comparison: Double(count ?? 0))
        }
    }

    private func fittingMetricValue(_ value: String, comparison: Double) -> some View {
        fittingValueContent(value)
            .numericTransition(value: value, comparison: comparison)
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func fittingModelValue(_ value: String) -> some View {
        metricValueText(value)
            .minimumScaleFactor(Metrics.metricValueMinimumScale)
            .allowsTightening(true)
            .numericTransition(value: value)
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func fittingValueContent(_ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            metricValueText(value)
                .fixedSize(horizontal: true, vertical: false)

            metricValueText(value)
                .minimumScaleFactor(Metrics.metricValueMinimumScale)
                .allowsTightening(true)
        }
    }

    private func metricValueText(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(Color.codexLabel)
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
    }

    private struct ActivityMetricRow: Identifiable {
        let label: String
        let value: Int?
        let tint: Color

        var id: String {
            label
        }
    }

    private enum Metrics {
        static let activityPanelWidth: CGFloat = 360
        static let activityPanelHeight: CGFloat = 232
        static let columnSpacing: CGFloat = 12
        static let columnHeight: CGFloat = 150
        static let sectionSpacing: CGFloat = 8
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 12
        static let tokenMinimumWidth: CGFloat = 52
        static let metricSpacing: CGFloat = 5
        static let metricRowSpacing: CGFloat = 6
        static let metricDotSize: CGFloat = 5
        static let metricRowHeight: CGFloat = 14
        static let metricValueMinimumScale: CGFloat = 0.60
        static let activityFontSize: CGFloat = 11
        static let tokenIntensitySegmentCount = 10
        static let tokenIntensitySegmentSpacing: CGFloat = 3
        static let tokenIntensityStripHeight: CGFloat = 5
        static let statusAnimation = Animation.codexStatus
    }
}

/// token 详情在数字和占位状态之间切换时只做淡入淡出, 数字之间仍保留滚动过渡
private struct HeatmapTokenText: View {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    let tokenState: UsageHeatmapTokenState
    let font: Font
    let minimumWidth: CGFloat

    @State private var displayedTokenState: UsageHeatmapTokenState
    @State private var isVisible = true

    init(
        tokenState: UsageHeatmapTokenState,
        font: Font,
        minimumWidth: CGFloat
    ) {
        self.tokenState = tokenState
        self.font = font
        self.minimumWidth = minimumWidth
        _displayedTokenState = State(initialValue: tokenState)
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .frame(minWidth: minimumWidth, alignment: .trailing)
            .task(id: Update(state: tokenState, animated: allowsAnimations)) {
                await updateDisplayedTokenState(tokenState)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch displayedTokenState {
        case let .available(tokenCount):
            TokenCountText(tokens: tokenCount, font: font)
                .foregroundStyle(Color.codexLabel)

        case .pending:
            Image(systemName: "questionmark")
                .font(font)
                .foregroundStyle(Color.codexLabel)

        case .unavailable:
            Text(verbatim: "--")
                .font(font)
                .foregroundStyle(Color.codexLabel)
        }
    }

    private func updateDisplayedTokenState(_ newTokenState: UsageHeatmapTokenState) async {
        guard !Task.isCancelled else { return }
        guard allowsAnimations else {
            displayedTokenState = newTokenState
            isVisible = true
            return
        }
        guard displayedTokenState != newTokenState || !isVisible else {
            return
        }

        if displayedTokenState.count != nil, newTokenState.count != nil {
            updateTokenStateWithoutFade(newTokenState)
        } else if displayedTokenState == newTokenState {
            withAnimation(Metrics.fadeAnimation) {
                isVisible = true
            }
        } else {
            await fadeToTokenState(newTokenState)
        }
    }

    private func updateTokenStateWithoutFade(_ newTokenState: UsageHeatmapTokenState) {
        withAnimation(Metrics.numericAnimation) {
            displayedTokenState = newTokenState
            isVisible = true
        }
    }

    private func fadeToTokenState(_ newTokenState: UsageHeatmapTokenState) async {
        withAnimation(Metrics.fadeAnimation) {
            isVisible = false
        }

        try? await Task.sleep(for: .milliseconds(Metrics.fadeDelayMilliseconds))
        guard !Task.isCancelled else {
            return
        }

        displayedTokenState = newTokenState
        withAnimation(Metrics.fadeAnimation) {
            isVisible = true
        }
    }

    private struct Update: Equatable {
        let state: UsageHeatmapTokenState
        let animated: Bool
    }

    private enum Metrics {
        static let fadeAnimation = Animation.easeInOut(duration: 0.12)
        static let fadeDelayMilliseconds: UInt64 = 120
        static let numericAnimation = Animation.codexStatus
    }
}

/// 日期拆成三段以固定 yyyy-MM-dd 格式并保留自然的数字滚动过渡
private struct AnimatedDateText: View {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    let startDate: String
    let font: Font

    var body: some View {
        if let components {
            HStack(spacing: 0) {
                Text(verbatim: components.year)
                Text(verbatim: "-")
                Text(verbatim: components.month)
                Text(verbatim: "-")
                Text(verbatim: components.day)
            }
            .font(font)
            .contentTransition(allowsAnimations ? .numericText(value: dateValue(components)) : .identity)
        } else {
            Text(verbatim: startDate)
                .font(font)
                .contentTransition(allowsAnimations ? .numericText() : .identity)
        }
    }

    private func dateValue(_ components: DateTextComponents) -> Double {
        guard let year = Int(components.year),
              let month = Int(components.month),
              let day = Int(components.day) else {
            return 0
        }
        return Double(year * 10000 + month * 100 + day)
    }

    private var components: DateTextComponents? {
        let parts = startDate.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }

        return DateTextComponents(year: parts[0], month: parts[1], day: parts[2])
    }

    private struct DateTextComponents {
        let year: String
        let month: String
        let day: String
    }
}
