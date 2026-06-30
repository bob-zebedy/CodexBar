import AppKit
import SwiftUI

/// hover 详情面板需要的完整上下文, 包括屏幕坐标和峰值 token
nonisolated struct UsageHeatmapHoverContext: Equatable {
    let day: UsageHeatmapDay
    let showsWorkflow: Bool
    let anchorScreenFrame: CGRect?
    let heatmapScreenFrame: CGRect?
    let preferredSide: UsageHeatmapDetailSide
    let peakTokens: Int
}

nonisolated enum UsageHeatmapDetailSide: Equatable {
    case left
    case right
}

/// hover 单元格在热力图中的列/行位置, 用于吸附和详情定位
nonisolated struct UsageHeatmapSelection: Equatable {
    let day: UsageHeatmapDay
    let column: Int
    let row: Int
}

/// token 摘要和近 30 周热力图的组合区
struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot
    let isStale: Bool
    let showsWorkflow: Bool
    let onHoverContextChange: (UsageHeatmapHoverContext?) -> Void
    private let days: [UsageHeatmapDay?]
    private let peakTokens: Int
    @State private var hoverSelection: UsageHeatmapSelection?
    @State private var heatmapGridScreenFrame: CGRect?

    init(
        usage: CodexUsageSnapshot,
        workflow: WorkflowSnapshot,
        showsWorkflow: Bool,
        isStale: Bool = false,
        onHoverContextChange: @escaping (UsageHeatmapHoverContext?) -> Void = { _ in }
    ) {
        self.usage = usage
        self.isStale = isStale
        self.showsWorkflow = showsWorkflow
        self.onHoverContextChange = onHoverContextChange

        let days = UsageHeatmapDay.grid(
            usage: usage,
            workflow: workflow,
            showsWorkflow: showsWorkflow,
            columnCount: UsageHeatmap.Metrics.columnCount,
            today: Date()
        )
        self.days = days
        peakTokens = max(days.lazy.compactMap { $0?.tokensForHeatmap }.max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricsGrid

            UsageHeatmap(
                days: days,
                selection: $hoverSelection,
                peakTokens: peakTokens,
                onScreenFrameChange: { frame in
                    heatmapGridScreenFrame = frame
                }
            )
        }
        .markStale(isStale)
        .padding(10)
        .liquidGlassSurface(cornerRadius: 8)
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

    private var metricsGrid: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.metricSpacing) {
            tokenMetric(label: "全时累计", value: usage.summary.lifetimeTokens)
            tokenMetric(label: "单日峰值", value: usage.summary.peakDailyTokens)
            textMetric(label: "当前连胜", value: Self.dayText(usage.summary.currentStreakDays))
            textMetric(label: "最长连胜", value: Self.dayText(usage.summary.longestStreakDays))
            textMetric(label: "最长任务", value: Self.durationText(seconds: usage.summary.longestRunningTurnSec))
        }
    }

    private func tokenMetric(label: String, value: Int) -> some View {
        metric(label: label, alignment: .center) {
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

    private func metric(
        label: String,
        alignment: Alignment,
        @ViewBuilder value: () -> some View
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
        let days = duration / 86400
        let hours = duration % 86400 / 3600
        let minutes = duration % 3600 / 60
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
        static let statusAnimation = Animation.codexStatus
    }

    private var hoverContext: UsageHeatmapHoverContext? {
        // 详情面板由控制器显示, SwiftUI 这里只负责传递屏幕坐标和数据
        hoverSelection.map {
            UsageHeatmapHoverContext(
                day: $0.day,
                showsWorkflow: showsWorkflow,
                anchorScreenFrame: hoveredSquareScreenFrame(for: $0),
                heatmapScreenFrame: heatmapGridScreenFrame,
                preferredSide: UsageHeatmap.Metrics.preferredDetailSide(for: $0.column),
                peakTokens: peakTokens
            )
        }
    }

    private func hoveredSquareScreenFrame(for selection: UsageHeatmapSelection) -> CGRect? {
        guard let heatmapGridScreenFrame else {
            return nil
        }

        let x = heatmapGridScreenFrame.minX + CGFloat(selection.column) * UsageHeatmap.Metrics.squarePitch
        let y = heatmapGridScreenFrame.maxY
            - CGFloat(selection.row) * UsageHeatmap.Metrics.squarePitch
            - UsageHeatmap.Metrics.squareSize

        return CGRect(
            x: x,
            y: y,
            width: UsageHeatmap.Metrics.squareSize,
            height: UsageHeatmap.Metrics.squareSize
        )
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

/// 近 30 周 token 热力图, hover 时把指针吸附到最近的有效日期格
struct UsageHeatmap: View {
    let days: [UsageHeatmapDay?]
    let onScreenFrameChange: (CGRect?) -> Void
    @Binding var selection: UsageHeatmapSelection?
    @State private var snapSelection: UsageHeatmapSelection?
    @State private var hoverClearTask: Task<Void, Never>?
    private let peakTokens: Int

    init(
        days: [UsageHeatmapDay?],
        selection: Binding<UsageHeatmapSelection?>,
        peakTokens: Int,
        onScreenFrameChange: @escaping (CGRect?) -> Void = { _ in }
    ) {
        self.days = days
        self.onScreenFrameChange = onScreenFrameChange
        _selection = selection
        self.peakTokens = peakTokens
    }

    var body: some View {
        heatmapGrid
            .frame(height: Metrics.height)
            .onDisappear {
                cancelHoverClearTask()
                onScreenFrameChange(nil)
            }
    }

    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 \(Metrics.columnCount) 周")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if let dateRangeText {
                    Text(dateRangeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .top, spacing: Metrics.squareSpacing) {
                ForEach(0 ..< Metrics.columnCount, id: \.self) { column in
                    VStack(spacing: Metrics.squareSpacing) {
                        ForEach(0 ..< Metrics.rowCount, id: \.self) { row in
                            let index = column * Metrics.rowCount + row

                            if days.indices.contains(index), let day = days[index] {
                                UsageHeatmapSquare(
                                    day: day,
                                    percent: Double(day.tokensForHeatmap) / Double(peakTokens),
                                    isHovered: snapSelection?.day.id == day.id
                                )
                            } else {
                                Color.clear
                                    .frame(width: Metrics.squareSize, height: Metrics.squareSize)
                            }
                        }
                    }
                }
            }
            .frame(width: Metrics.totalWidth, height: Metrics.gridHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(point):
                    updatePointerLocation(point)
                case .ended:
                    scheduleDeactivate()
                }
            }
            .background {
                ScreenFrameReader(onChange: onScreenFrameChange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleDays: [UsageHeatmapDay] {
        days.compactMap(\.self)
    }

    private var dateRangeText: String? {
        guard let firstDate = visibleDays.first?.startDate,
              let lastDate = visibleDays.last?.startDate else {
            return nil
        }

        return "\(firstDate) ~ \(lastDate)"
    }

    private func updatePointerLocation(_ point: CGPoint) {
        guard let target = snappedSelection(at: point) else {
            scheduleDeactivate()
            return
        }

        cancelHoverClearTask()

        if !matches(snapSelection, target) {
            withAnimation(.snappy(duration: Metrics.snapAnimationDuration)) {
                snapSelection = target
            }
        }

        if !matches(selection, target) {
            activate(target)
        }
    }

    private func snappedSelection(at point: CGPoint) -> UsageHeatmapSelection? {
        // 以格子中心为准吸附, 指针离中心过远时视为离开格子
        let column = Int(((point.x - Metrics.squareSize / 2) / Metrics.squarePitch).rounded())
        let row = Int(((point.y - Metrics.squareSize / 2) / Metrics.squarePitch).rounded())

        guard (0 ..< Metrics.columnCount).contains(column),
              (0 ..< Metrics.rowCount).contains(row) else {
            return nil
        }

        let center = CGPoint(
            x: CGFloat(column) * Metrics.squarePitch + Metrics.squareSize / 2,
            y: CGFloat(row) * Metrics.squarePitch + Metrics.squareSize / 2
        )
        guard abs(point.x - center.x) <= Metrics.snapHalfExtent,
              abs(point.y - center.y) <= Metrics.snapHalfExtent else {
            return nil
        }

        let index = column * Metrics.rowCount + row
        guard days.indices.contains(index), let day = days[index] else {
            return nil
        }

        return UsageHeatmapSelection(day: day, column: column, row: row)
    }

    private func activate(_ target: UsageHeatmapSelection) {
        withAnimation(.easeInOut(duration: Metrics.hoverFadeDuration)) {
            selection = target
        }
    }

    private func scheduleDeactivate() {
        cancelHoverClearTask()
        hoverClearTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Metrics.hoverExitGraceMilliseconds))
            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeInOut(duration: Metrics.hoverFadeDuration)) {
                snapSelection = nil
                selection = nil
            }
        }
    }

    private func cancelHoverClearTask() {
        hoverClearTask?.cancel()
        hoverClearTask = nil
    }

    private func matches(_ lhs: UsageHeatmapSelection?, _ rhs: UsageHeatmapSelection) -> Bool {
        lhs?.day.id == rhs.day.id && lhs?.column == rhs.column && lhs?.row == rhs.row
    }
}

extension UsageHeatmap {
    enum Metrics {
        static let columnCount = 30
        static let rowCount = CodexWeekGrid.rowCount
        static let squareSize: CGFloat = 12
        static let squareSpacing: CGFloat = 3
        static let squarePitch = squareSize + squareSpacing
        static let height: CGFloat = 120
        static let snapAnimationDuration: TimeInterval = 0.12
        static let hoverFadeDuration: TimeInterval = 0.15
        static let hoverExitGraceMilliseconds: UInt64 = 160
        static let snapHalfExtent: CGFloat = squareSize / 2 + squareSpacing

        static var totalWidth: CGFloat {
            CGFloat(columnCount) * squareSize + CGFloat(columnCount - 1) * squareSpacing
        }

        static var gridHeight: CGFloat {
            CGFloat(rowCount) * squareSize + CGFloat(rowCount - 1) * squareSpacing
        }

        static func preferredDetailSide(for column: Int) -> UsageHeatmapDetailSide {
            column < columnCount / 2 ? .left : .right
        }
    }
}

/// 单个热力图方块, 蓝色透明度表示当天 token 强度
private struct UsageHeatmapSquare: View {
    let day: UsageHeatmapDay
    let percent: Double
    let isHovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(fillColor)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(borderColor, lineWidth: isHovered ? 1.2 : 0.7)
            }
            .shadow(color: .blue.opacity(0.22), radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
            .scaleEffect(isHovered ? 1.08 : 1)
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

struct UsageHeatmapDayDetailView: View {
    let context: UsageHeatmapHoverContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let panelSize = Self.panelSize(showsWorkflow: context.showsWorkflow)

        detailContent
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding)
            .frame(
                width: panelSize.width,
                height: panelSize.height,
                alignment: .topLeading
            )
            .liquidGlassSurface(cornerRadius: Metrics.cornerRadius, isOuterSurface: true)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .fill(panelBackingFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(panelBoundaryColor, lineWidth: Metrics.boundaryLineWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .animation(Metrics.statusAnimation, value: context)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static func panelSize(showsWorkflow: Bool) -> CGSize {
        showsWorkflow
            ? CGSize(width: Metrics.workflowPanelWidth, height: Metrics.workflowPanelHeight)
            : CGSize(width: Metrics.tokenPanelWidth, height: Metrics.tokenPanelHeight)
    }

    @ViewBuilder
    private var detailContent: some View {
        if context.showsWorkflow {
            workflowContent
        } else {
            tokenOnlyContent
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Metrics.headerSpacing) {
            dateText
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .liquidGlassCapsule(tint: .accentColor)

            Spacer(minLength: 8)

            tokenText
                .frame(minWidth: Metrics.tokenMinimumWidth, alignment: .trailing)
        }
    }

    private var workflowContent: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header

            LiquidGlassDivider()
                .opacity(0.72)

            VStack(alignment: .leading, spacing: Metrics.metricSpacing) {
                tokenIntensityMetricRow

                ForEach(workflowMetricRows) { row in
                    metricRow(row)
                }
            }
        }
    }

    private var tokenOnlyContent: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header

            LiquidGlassDivider()
                .opacity(0.62)

            tokenOnlyFooter
        }
    }

    private var tokenOnlyFooter: some View {
        metricRowLayout {
            tokenIntensityDot
            Text("用量强度")
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            tokenIntensityStrip
                .frame(width: Metrics.tokenIntensityStripWidth)
        }
    }

    private var tokenIntensityMetricRow: some View {
        metricRowLayout {
            tokenIntensityDot
            Text("用量强度")
                .foregroundStyle(.secondary)
                .frame(width: Metrics.metricLabelWidth, alignment: .leading)

            tokenIntensityStrip
                .frame(width: Metrics.tokenIntensityStripWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var tokenIntensityDot: some View {
        metricDot(tint: .blue, darkOpacity: 0.88, lightOpacity: 0.76)
    }

    private func metricRowLayout(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Metrics.metricRowSpacing, content: content)
            .font(.system(size: Metrics.workflowFontSize))
            .frame(height: Metrics.metricRowHeight)
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

    private var workflowMetricRows: [WorkflowMetricRow] {
        [
            WorkflowMetricRow(label: "会话总数", value: context.day.workflow.sessionCount, tint: .green),
            WorkflowMetricRow(label: "对话轮次", value: context.day.workflow.turnCount, tint: .teal),
            WorkflowMetricRow(label: "子智能体", value: context.day.workflow.subagentCount, tint: .indigo),
            WorkflowMetricRow(label: "工具调用", value: context.day.workflow.toolCallCount, tint: .orange),
            WorkflowMetricRow(label: "权限请求", value: context.day.workflow.permissionRequestCount, tint: .red),
            WorkflowMetricRow(label: "上下文压缩", value: context.day.workflow.contextCompactionCount, tint: .purple)
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
        ZStack(alignment: .trailing) {
            if let tokenCount = context.day.tokenCount {
                TokenCountText(
                    tokens: tokenCount,
                    font: tokenFont,
                    reservedNumericWidth: Metrics.tokenMinimumWidth,
                    reservedUnitWidth: Metrics.tokenUnitWidth
                )
                .foregroundStyle(Color.codexLabel)
                .transition(.opacity)
            } else {
                Text("--")
                    .font(tokenFont)
                    .foregroundStyle(Color.codexLabel)
                    .transition(.opacity)
            }
        }
        .frame(
            width: Metrics.tokenMinimumWidth + Metrics.tokenUnitWidth,
            alignment: .trailing
        )
        .animation(Metrics.statusAnimation, value: context.day.tokenCount == nil)
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
        guard index < tokenIntensityLevel else {
            return Color.blue.opacity(colorScheme == .dark ? 0.14 : 0.10)
        }

        let opacity = colorScheme == .dark ? 0.42 + Double(index) * 0.10 : 0.34 + Double(index) * 0.09
        return Color.blue.opacity(min(opacity, 0.88))
    }

    private func metricRow(_ row: WorkflowMetricRow) -> some View {
        metricRowLayout {
            metricDot(tint: row.tint)
            Text(row.label)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.metricLabelWidth, alignment: .leading)

            fittingMetricValue("\(row.value)", comparison: Double(row.value))
        }
    }

    private func fittingMetricValue(_ value: String, comparison: Double) -> some View {
        ViewThatFits(in: .horizontal) {
            metricValueText(value)
                .fixedSize(horizontal: true, vertical: false)

            metricValueText(value)
                .minimumScaleFactor(Metrics.metricValueMinimumScale)
                .allowsTightening(true)
        }
        .numericRollTransition(value: comparison)
        .layoutPriority(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func metricValueText(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(Color.codexLabel)
            .fontWeight(.semibold)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var panelBackingFill: Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.90 : 0.86)
    }

    private var panelBoundaryColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.18)
            : .black.opacity(0.14)
    }

    private struct WorkflowMetricRow: Identifiable {
        let label: String
        let value: Int
        let tint: Color

        var id: String {
            label
        }
    }

    private enum Metrics {
        static let workflowPanelWidth: CGFloat = 212
        static let workflowPanelHeight: CGFloat = 189
        static let tokenPanelWidth: CGFloat = 212
        static let tokenPanelHeight: CGFloat = 84
        static let sectionSpacing: CGFloat = 8
        static let headerSpacing: CGFloat = 10
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 12
        static let boundaryLineWidth: CGFloat = 0.8
        static let tokenMinimumWidth: CGFloat = 38
        static let tokenUnitWidth: CGFloat = 14
        static let metricSpacing: CGFloat = 5
        static let metricRowSpacing: CGFloat = 6
        static let metricDotSize: CGFloat = 5
        static let metricRowHeight: CGFloat = 14
        static let metricLabelWidth: CGFloat = 72
        static let metricValueMinimumScale: CGFloat = 0.60
        static let workflowFontSize: CGFloat = 11
        static let tokenIntensitySegmentCount = 5
        static let tokenIntensitySegmentSpacing: CGFloat = 3
        static let tokenIntensityStripWidth: CGFloat = 74
        static let tokenIntensityStripHeight: CGFloat = 5
        static let statusAnimation = Animation.codexStatus
    }
}

/// 日期拆成三段以获得更自然的数字滚动过渡
private struct AnimatedDateText: View {
    let startDate: String
    let font: Font

    var body: some View {
        if let components {
            HStack(spacing: 0) {
                Text(components.year)
                Text("-")
                Text(components.month)
                Text("-")
                Text(components.day)
            }
            .font(font)
            .numericRollTransition(value: dateValue(components))
        } else {
            Text(startDate)
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
