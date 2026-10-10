import SwiftUI

struct HeatmapDetailView: View {
    let context: UsageHeatmapHoverContext
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
                    columnTitle("usage.heatmap.activity-metrics")
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
                    columnTitle("usage.heatmap.token-metrics")
                    dailyTokenMetrics
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

    private var dailyTokenMetrics: some View {
        let usage = context.day.tokenUsage
        let cacheHitRate = usage?.cacheHitRate ?? 0
        return Grid(alignment: .leading, horizontalSpacing: Metrics.metricRowSpacing, verticalSpacing: Metrics.metricSpacing) {
            dailyTokenRow("usage.tokens.total", tokens: usage?.totalTokens, tint: .blue)
            dailyTokenRow("usage.tokens.input", tokens: usage?.inputTokens, tint: .indigo)
            dailyTokenRow("usage.tokens.output", tokens: usage?.outputTokens, tint: .orange)
            dailyTokenRow("usage.tokens.cached-input", tokens: usage?.cachedInputTokens, tint: .green)
            dailyTokenRow("usage.tokens.cache-write-input", tokens: usage?.cacheWriteInputTokens, tint: .purple)
            metricRowLayout {
                metricDot(tint: .teal)
                Text("usage.tokens.cache-hit-rate")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: Metrics.metricRowHeight)
                fittingMetricValue(
                    cacheHitRate.formatted(.percent.precision(.fractionLength(0 ... 1))),
                    comparison: cacheHitRate
                )
            }
            dailyTokenRow("usage.tokens.reasoning-output", tokens: usage?.reasoningOutputTokens, tint: .cyan)
        }
    }

    private func dailyTokenRow(_ title: LocalizedStringKey, tokens: Int64?, tint: Color) -> some View {
        let count = tokens ?? 0
        return metricRowLayout {
            metricDot(tint: tint)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Metrics.metricRowHeight)
            fittingMetricValue(TokenCountFormatter.parts(from: Int(count)).text, comparison: Double(count))
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

            fittingModelValue(context.day.history.mostUsedModel ?? "--")
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
                label: String(localized: "history.metric.sessions"),
                value: context.day.history.threadCount,
                tint: .green
            ),
            ActivityMetricRow(
                label: String(localized: "history.metric.turns"),
                value: context.day.history.turnCount,
                tint: .teal
            ),
            ActivityMetricRow(
                label: String(localized: "history.metric.subagents"),
                value: context.day.history.subagentCount,
                tint: .indigo
            ),
            ActivityMetricRow(
                label: String(localized: "history.metric.tool-calls"),
                value: context.day.history.toolCallCount,
                tint: .orange
            ),
            ActivityMetricRow(
                label: String(localized: "history.metric.approvals"),
                value: context.day.history.approvalRequestedCount,
                tint: .red
            ),
            ActivityMetricRow(
                label: String(localized: "history.metric.compactions"),
                value: context.day.history.contextCompactionCount,
                tint: .purple
            )
        ]
    }

    private var dateText: some View {
        AnimatedDateText(startDate: context.day.startDate, font: dateFont)
            .foregroundStyle(Color.codexSecondaryLabel)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }

    private var tokenText: some View {
        HeatmapTokenText(
            tokenState: context.day.tokenState,
            font: tokenFont,
            numericWidth: Metrics.tokenMinimumWidth,
            unitWidth: Metrics.tokenUnitWidth
        )
    }

    private var dateFont: Font {
        .caption2.monospacedDigit()
    }

    private var tokenFont: Font {
        .system(size: 14).monospacedDigit().weight(.semibold)
    }

    private var tokenIntensityLevel: Int {
        guard context.day.tokensForHeatmap > 0 else {
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

        return min(max(Double(context.day.tokensForHeatmap) / Double(context.peakTokens), 0), 1)
    }

    private func tokenIntensityFill(for index: Int) -> Color {
        guard context.day.tokenCount != nil else {
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
        let count = row.value ?? 0
        return metricRowLayout {
            metricDot(tint: row.tint)
            Text(row.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: Metrics.metricRowHeight)

            fittingMetricValue(String(count), comparison: Double(count))
        }
    }

    private func fittingMetricValue(_ value: String, comparison: Double) -> some View {
        fittingValueContent(value)
            .contentTransition(.numericText(value: comparison))
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func fittingModelValue(_ value: String) -> some View {
        metricValueText(value)
            .minimumScaleFactor(Metrics.metricValueMinimumScale)
            .allowsTightening(true)
            .contentTransition(.numericText())
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
        static let tokenMinimumWidth: CGFloat = 38
        static let tokenUnitWidth: CGFloat = 14
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
    let tokenState: UsageHeatmapTokenState
    let font: Font
    let numericWidth: CGFloat
    let unitWidth: CGFloat

    @State private var displayedTokenState: UsageHeatmapTokenState
    @State private var isVisible = true

    init(
        tokenState: UsageHeatmapTokenState,
        font: Font,
        numericWidth: CGFloat,
        unitWidth: CGFloat
    ) {
        self.tokenState = tokenState
        self.font = font
        self.numericWidth = numericWidth
        self.unitWidth = unitWidth
        _displayedTokenState = State(initialValue: tokenState)
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .frame(minWidth: width, alignment: .trailing)
            .task(id: tokenState) {
                await updateDisplayedTokenState(tokenState)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch displayedTokenState {
        case let .available(tokenCount):
            TokenCountText(
                tokens: tokenCount,
                font: font,
                reservedNumericWidth: numericWidth,
                reservedUnitWidth: unitWidth
            )
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

    private var width: CGFloat {
        numericWidth + unitWidth
    }

    private enum Metrics {
        static let fadeAnimation = Animation.easeInOut(duration: 0.12)
        static let fadeDelayMilliseconds: UInt64 = 120
        static let numericAnimation = Animation.codexStatus
    }
}

/// 日期拆成三段以固定 yyyy-MM-dd 格式并保留自然的数字滚动过渡
private struct AnimatedDateText: View {
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
            .contentTransition(.numericText(value: dateValue(components)))
        } else {
            Text(verbatim: startDate)
                .font(font)
                .contentTransition(.numericText())
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
