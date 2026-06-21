import SwiftUI

struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot
    let isStale: Bool
    let showsWorkflowStats: Bool
    private let days: [UsageHeatmapDay?]
    @State private var hoveredDay: UsageHeatmapDay?
    
    init(
        usage: CodexUsageSnapshot,
        workflowStats: WorkflowStatsSnapshot,
        showsWorkflowStats: Bool,
        isStale: Bool = false
    ) {
        self.usage = usage
        self.isStale = isStale
        self.showsWorkflowStats = showsWorkflowStats
        
        self.days = UsageHeatmapDay.grid(
            usage: usage,
            workflowStats: workflowStats,
            showsWorkflowStats: showsWorkflowStats,
            columnCount: UsageHeatmap.Metrics.columnCount,
            today: Date()
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricsGrid
            
            UsageHeatmap(
                days: days,
                showsWorkflowStats: showsWorkflowStats,
                hoveredDay: $hoveredDay
            )
        }
        .markStale(isStale)
        .padding(10)
        .liquidGlassSurface(cornerRadius: 8)
        .onAppear {
            hoveredDay = nil
        }
    }
    
    private var metricsGrid: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.metricSpacing) {
            tokenMetric(label: "全时累计", value: usage.summary.lifetimeTokens, alignment: .center)
            tokenMetric(label: "单日峰值", value: usage.summary.peakDailyTokens, alignment: .center)
            textMetric(label: "当前连胜", value: Self.dayText(usage.summary.currentStreakDays))
            textMetric(label: "最长连胜", value: Self.dayText(usage.summary.longestStreakDays))
            textMetric(label: "最长任务", value: Self.durationText(seconds: usage.summary.longestRunningTurnSec))
        }
    }
    
    private func tokenMetric(label: String, value: Int, alignment: Alignment) -> some View {
        metric(label: label, alignment: alignment) {
            TokenCountText(tokens: value)
        }
    }
    
    private func textMetric(label: String, value: String) -> some View {
        metric(label: label, alignment: .center) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
    
    private func metric<Content: View>(
        label: String,
        alignment: Alignment,
        @ViewBuilder value: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: alignment)
            
            value()
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .frame(maxWidth: .infinity)
    }
    
    private static func dayText(_ days: Int?) -> String {
        guard let days else {
            return "--"
        }
        
        return "\(max(days, 0))天"
    }
    
    private static func durationText(seconds: Int?) -> String {
        guard let seconds else {
            return "--"
        }
        
        let duration = max(seconds, 0)
        let days = duration / 86_400
        let hours = duration % 86_400 / 3_600
        let minutes = duration % 3_600 / 60
        let remainingSeconds = duration % 60
        
        if days > 0 {
            return "\(days) 天 \(hours) 时 \(minutes) 分 \(remainingSeconds) 秒"
        }
        
        if hours > 0 {
            return "\(hours) 时 \(minutes) 分 \(remainingSeconds) 秒"
        }
        
        if minutes > 0 {
            return "\(minutes) 分 \(remainingSeconds) 秒"
        }
        
        return "\(remainingSeconds) 秒"
    }
    
    private enum Metrics {
        static let metricSpacing: CGFloat = 8
    }
}

struct UsageHeatmap: View {
    let days: [UsageHeatmapDay?]
    let showsWorkflowStats: Bool
    @Binding var hoveredDay: UsageHeatmapDay?
    @State private var hoveredSquareFrame: CGRect = .zero
    // hover 期间 body 频繁重算, 峰值只在构建时求一次
    private let peakTokens: Int
    
    init(
        days: [UsageHeatmapDay?],
        showsWorkflowStats: Bool,
        hoveredDay: Binding<UsageHeatmapDay?>
    ) {
        self.days = days
        self.showsWorkflowStats = showsWorkflowStats
        self._hoveredDay = hoveredDay
        self.peakTokens = max(days.lazy.compactMap { $0?.tokensForHeatmap }.max() ?? 0, 1)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            heatmapGrid
            
            if let hoveredDay {
                UsageHeatmapTooltip(day: hoveredDay, showsWorkflowStats: showsWorkflowStats)
                    .id(hoveredDay.id)
                    .allowsHitTesting(false)
                    .offset(tooltipOffset)
                    .zIndex(1)
                    .transition(.opacity)
            }
        }
        .frame(height: Metrics.height)
        .coordinateSpace(name: Metrics.coordinateSpaceName)
    }
    
    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 \(Metrics.columnCount) 周")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if let firstDate = visibleDays.first?.startDate, let lastDate = visibleDays.last?.startDate {
                    Text("\(firstDate) ~ \(lastDate)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            
            HStack(alignment: .top, spacing: Metrics.squareSpacing) {
                ForEach(0..<Metrics.columnCount, id: \.self) { column in
                    VStack(spacing: Metrics.squareSpacing) {
                        ForEach(0..<Metrics.rowCount, id: \.self) { row in
                            let index = column * Metrics.rowCount + row
                            
                            if days.indices.contains(index), let day = days[index] {
                                UsageHeatmapSquare(
                                    day: day,
                                    percent: Double(day.tokensForHeatmap) / Double(peakTokens),
                                    isHovered: hoveredDay?.id == day.id
                                ) { frame in
                                    if hoveredDay?.id != day.id {
                                        withAnimation(.easeInOut(duration: Metrics.tooltipFadeDuration)) {
                                            hoveredDay = day
                                            hoveredSquareFrame = frame
                                        }
                                    } else if hoveredSquareFrame != frame {
                                        hoveredSquareFrame = frame
                                    }
                                } onEnded: {
                                    if hoveredDay?.id == day.id {
                                        withAnimation(.easeInOut(duration: Metrics.tooltipFadeDuration)) {
                                            hoveredDay = nil
                                        }
                                    }
                                }
                            } else {
                                Color.clear
                                    .frame(width: Metrics.squareSize, height: Metrics.squareSize)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var visibleDays: [UsageHeatmapDay] {
        days.compactMap { $0 }
    }
    
    private var tooltipOffset: CGSize {
        let aboveY = hoveredSquareFrame.minY - Metrics.tooltipSquareSpacing - tooltipHeight
        let tooltipY = aboveY >= 0 ? aboveY : hoveredSquareFrame.maxY + Metrics.tooltipSquareSpacing
        
        return CGSize(
            width: tooltipX(for: hoveredSquareFrame),
            height: min(max(tooltipY, 0), max(0, Metrics.height - tooltipHeight))
        )
    }
    
    private var tooltipHeight: CGFloat {
        Metrics.tooltipHeight(showsWorkflowStats: showsWorkflowStats)
    }
    
    private func tooltipX(for squareFrame: CGRect) -> CGFloat {
        let trailingX = squareFrame.maxX + Metrics.tooltipSquareSpacing
        let tooltipWidth = Metrics.tooltipWidth(showsWorkflowStats: showsWorkflowStats)
        let leadingX = squareFrame.minX - Metrics.tooltipSquareSpacing - tooltipWidth
        let maxX = max(0, Metrics.totalWidth - tooltipWidth)
        
        if leadingX >= 0 {
            return leadingX
        }
        
        if trailingX + tooltipWidth <= Metrics.totalWidth {
            return trailingX
        }
        
        return min(max(leadingX, 0), maxX)
    }
}

extension UsageHeatmap {
    enum Metrics {
        static let coordinateSpaceName = "usageHeatmap"
        static let columnCount = 30
        static let rowCount = CodexWeekGrid.rowCount
        static let squareSize: CGFloat = 12
        static let squareSpacing: CGFloat = 3
        static let height: CGFloat = 120
        static let workflowTooltipWidth: CGFloat = 132
        static let tokenTooltipWidth: CGFloat = 92
        static let workflowTooltipHeight: CGFloat = 116
        static let tokenTooltipHeight: CGFloat = 40
        static let tooltipSquareSpacing: CGFloat = 2
        static let tooltipFadeDuration: TimeInterval = 0.15
        
        static var totalWidth: CGFloat {
            CGFloat(columnCount) * squareSize + CGFloat(columnCount - 1) * squareSpacing
        }
        
        static func tooltipWidth(showsWorkflowStats: Bool) -> CGFloat {
            showsWorkflowStats ? workflowTooltipWidth : tokenTooltipWidth
        }
        
        static func tooltipHeight(showsWorkflowStats: Bool) -> CGFloat {
            showsWorkflowStats ? workflowTooltipHeight : tokenTooltipHeight
        }
    }
}

private struct UsageHeatmapSquare: View {
    let day: UsageHeatmapDay
    let percent: Double
    let isHovered: Bool
    let onActive: (CGRect) -> Void
    let onEnded: () -> Void
    
    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fillColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(borderColor, lineWidth: isHovered ? 1.2 : 0.7)
                }
                .shadow(color: .blue.opacity(0.22), radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
                .scaleEffect(isHovered ? 1.08 : 1)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        onActive(proxy.frame(in: .named(UsageHeatmap.Metrics.coordinateSpaceName)))
                    case .ended:
                        onEnded()
                    }
                }
        }
        .frame(width: UsageHeatmap.Metrics.squareSize, height: UsageHeatmap.Metrics.squareSize)
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.snappy(duration: 0.14), value: isHovered)
    }
    
    private var clampedPercent: Double {
        min(max(percent, 0), 1)
    }
    
    private var fillColor: Color {
        guard day.tokensForHeatmap > 0 else {
            return Color.blue.opacity(isHovered ? 0.16 : 0.08)
        }
        
        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return Color.blue.opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }
    
    private var borderColor: Color {
        if isHovered {
            return Color.blue.opacity(0.78)
        }
        
        return Color.blue.opacity(day.tokensForHeatmap > 0 ? 0.18 : 0.10)
    }
}

private struct UsageHeatmapTooltip: View {
    let day: UsageHeatmapDay
    let showsWorkflowStats: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            if showsWorkflowStats {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.headerSpacing) {
                    dateText
                    
                    Spacer(minLength: Metrics.headerMinimumSpacer)
                    
                    tokenText
                }
                
                ForEach(workflowMetricRows, id: \.label) { row in
                    metricRow(row.label, value: row.value)
                }
            } else {
                dateText
                tokenText
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(
            width: tooltipWidth,
            height: tooltipHeight,
            alignment: .leading
        )
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(tooltipFill)
        }
        .liquidGlassSurface(cornerRadius: Metrics.cornerRadius)
    }
    
    private var workflowMetricRows: [(label: String, value: String)] {
        [
            ("会话总数", "\(day.workflowStats.sessionCount)"),
            ("对话轮次", "\(day.workflowStats.turnCount)"),
            ("子智能体", "\(day.workflowStats.subagentCount)"),
            ("工具调用", "\(day.workflowStats.toolCallCount)"),
            ("权限请求", "\(day.workflowStats.permissionRequestCount)"),
            ("上下文压缩", "\(day.workflowStats.contextCompactionCount)")
        ]
    }
    
    private var tooltipHeight: CGFloat {
        UsageHeatmap.Metrics.tooltipHeight(showsWorkflowStats: showsWorkflowStats)
    }
    
    private var tooltipWidth: CGFloat {
        UsageHeatmap.Metrics.tooltipWidth(showsWorkflowStats: showsWorkflowStats)
    }
    
    private var dateText: some View {
        Text(day.startDate)
            .font(dateFont)
            .foregroundStyle(Color.codexSecondaryLabel)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
    }
    
    @ViewBuilder
    private var tokenText: some View {
        if let tokenCount = day.tokenCount {
            TokenCountText(tokens: tokenCount, font: tokenFont)
                .foregroundStyle(Color.codexLabel)
        } else {
            Text("--")
                .font(tokenFont)
                .foregroundStyle(Color.codexLabel)
        }
    }
    
    private var dateFont: Font {
        showsWorkflowStats
        ? .system(size: Metrics.workflowFontSize).monospacedDigit()
        : .caption2.monospacedDigit()
    }
    
    private var tokenFont: Font {
        showsWorkflowStats
        ? .system(size: Metrics.workflowFontSize).monospacedDigit().weight(.semibold)
        : .caption.monospacedDigit().weight(.semibold)
    }
    
    private func metricRow(_ label: String, value: String) -> some View {
        HStack(spacing: Metrics.metricRowSpacing) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.metricLabelWidth, alignment: .leading)
            
            fittingMetricValue(value)
        }
        .font(.system(size: Metrics.workflowFontSize))
    }
    
    private func fittingMetricValue(_ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            metricValueText(value)
                .fixedSize(horizontal: true, vertical: false)
            
            metricValueText(value)
                .minimumScaleFactor(Metrics.metricValueMinimumScale)
                .allowsTightening(true)
        }
        .layoutPriority(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    
    private func metricValueText(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(Color.codexLabel)
            .monospacedDigit()
            .lineLimit(1)
    }
    
    private var tooltipFill: Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.88 : 0.82)
    }
    
    private enum Metrics {
        static let rowSpacing: CGFloat = 3
        static let headerSpacing: CGFloat = 4
        static let headerMinimumSpacer: CGFloat = 4
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 6
        static let cornerRadius: CGFloat = 7
        static let metricRowSpacing: CGFloat = 6
        static let metricLabelWidth: CGFloat = 54
        static let metricValueMinimumScale: CGFloat = 0.60
        static let workflowFontSize: CGFloat = 10
    }
}
