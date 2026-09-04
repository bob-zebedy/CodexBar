import AppKit
import SwiftUI

/// hover 详情面板需要的完整上下文, 包括屏幕坐标和峰值 token
nonisolated struct UsageHeatmapHoverContext: Equatable {
    let day: UsageHeatmapDay
    let showsWorkflow: Bool
    let alignmentScreenFrame: CGRect?
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

// MARK: - 摘要区

/// token 摘要和近 30 周热力图的组合区
struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot?
    let isStale: Bool
    let showsWorkflow: Bool
    let onHoverContextChange: (UsageHeatmapHoverContext?) -> Void
    private let days: [UsageHeatmapDay?]
    private let peakTokens: Int
    @State private var hoverSelection: UsageHeatmapSelection?
    @State private var heatmapScreenFrame: CGRect?

    init(
        usage: CodexUsageSnapshot?,
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
        if usage?.hasAppServerData == true || showsWorkflow {
            VStack(alignment: .leading, spacing: 8) {
                metricsGrid

                if usage?.hasDailyUsageBuckets == true || showsWorkflow {
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

        let totalSeconds = max(seconds, 0)
        let duration = Duration.seconds(Double(totalSeconds))
        let allowedUnits: Set<Duration.UnitsFormatStyle.Unit> = if totalSeconds >= 86400 {
            [.days, .hours, .minutes, .seconds]
        } else if totalSeconds >= 3600 {
            [.hours, .minutes, .seconds]
        } else if totalSeconds >= 60 {
            [.minutes, .seconds]
        } else {
            [.seconds]
        }
        return CodexDurationFormat.abbreviated(duration, allowedUnits: allowedUnits)
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

// MARK: - 热力图与 hover 吸附

/// 近 30 周 token 热力图, hover 时把指针吸附到最近的有效日期格
struct UsageHeatmap: View {
    let days: [UsageHeatmapDay?]
    let onScreenFrameChange: (CGRect?) -> Void
    @Binding var selection: UsageHeatmapSelection?
    @Environment(\.mainPanelEntranceAnimationsEnabled) private var animatesEntrance
    @State private var areSquaresRevealed = false
    @State private var entranceStartedAt: TimeInterval?
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
            .background {
                ScreenFrameReader(onChange: onScreenFrameChange)
            }
            .task {
                await revealSquares()
            }
            .onDisappear {
                cancelHoverClearTask()
                snapSelection = nil
                selection = nil
                onScreenFrameChange(nil)
            }
    }

    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringResource("usage.heatmap.past-weeks", defaultValue: "\(Metrics.columnCount, specifier: "%lld")"))
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
                                .opacity(showsSquares ? 1 : 0)
                                .scaleEffect(showsSquares ? 1 : Metrics.entranceScale)
                                .animation(
                                    entranceAnimation(column: column, row: row),
                                    value: showsSquares
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateRangeText: String? {
        let visibleDays = days.compactMap(\.self)
        guard let firstDate = visibleDays.first?.startDate,
              let lastDate = visibleDays.last?.startDate else {
            return nil
        }

        let firstText = localDayText(firstDate)
        let lastText = localDayText(lastDate)
        return String(localized: "date-range.closed", defaultValue: "\(firstText)\(lastText)")
    }

    private var showsSquares: Bool {
        areSquaresRevealed || !animatesEntrance
    }

    private func entranceAnimation(column: Int, row: Int) -> Animation? {
        guard areSquaresRevealed,
              animatesEntrance else {
            return nil
        }

        return .spring(
            response: Metrics.entranceResponse,
            dampingFraction: Metrics.entranceDampingFraction
        )
        .delay(entranceDelay(column: column, row: row))
    }

    private func revealSquares() async {
        guard animatesEntrance else {
            areSquaresRevealed = true
            return
        }

        await Task.yield()
        guard !Task.isCancelled else {
            return
        }

        entranceStartedAt = ProcessInfo.processInfo.systemUptime
        areSquaresRevealed = true
    }

    private func entranceDelay(column: Int, row: Int) -> TimeInterval {
        TimeInterval(column + row) * Metrics.entranceStagger
    }

    private func isSquareInteractive(column: Int, row: Int) -> Bool {
        guard showsSquares else {
            return false
        }

        guard animatesEntrance, let entranceStartedAt else {
            return true
        }

        let elapsed = ProcessInfo.processInfo.systemUptime - entranceStartedAt
        let interactiveAt = entranceDelay(column: column, row: row) + Metrics.entranceResponse
        return elapsed >= interactiveAt
    }

    private func localDayText(_ dayKey: String) -> String {
        guard let date = CodexDateFormat.dayDate(from: dayKey) else {
            return dayKey
        }
        return CodexDateFormat.localDayDisplayString(from: date)
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
              (0 ..< Metrics.rowCount).contains(row),
              isSquareInteractive(column: column, row: row) else {
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
        static let entranceScale: CGFloat = 0.35
        static let entranceStagger: TimeInterval = 0.015
        static let entranceResponse: TimeInterval = 0.25
        static let entranceDampingFraction = 0.60

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

// MARK: - 单元格

/// 单个热力图方块, 蓝色透明度表示当天 token 强度, 中性色表示 token 数据不可用
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
            .shadow(color: shadowColor, radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
            .scaleEffect(isHovered ? 1.08 : 1)
            .frame(width: UsageHeatmap.Metrics.squareSize, height: UsageHeatmap.Metrics.squareSize)
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .animation(.snappy(duration: 0.14), value: isHovered)
    }

    private var clampedPercent: Double {
        min(max(percent, 0), 1)
    }

    private var fillColor: Color {
        guard day.tokenCount != nil else {
            return Color.secondary.opacity(isHovered ? 0.12 : 0.05)
        }
        guard day.tokensForHeatmap > 0 else {
            return Color.blue.opacity(isHovered ? 0.16 : 0.08)
        }

        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return Color.blue.opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }

    private var borderColor: Color {
        guard day.tokenCount != nil else {
            return Color.secondary.opacity(isHovered ? 0.42 : 0.12)
        }
        if isHovered {
            return Color.blue.opacity(0.78)
        }

        return Color.blue.opacity(day.tokensForHeatmap > 0 ? 0.18 : 0.10)
    }

    private var shadowColor: Color {
        day.tokenCount == nil ? .clear : .blue.opacity(0.22)
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
            .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
            .animation(Metrics.statusAnimation, value: context)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static func panelSize(showsWorkflow: Bool) -> CGSize {
        CGSize(
            width: Metrics.panelWidth,
            height: showsWorkflow ? Metrics.workflowPanelHeight : Metrics.tokenPanelHeight
        )
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
                mostUsedModelMetricRow

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
            Text("usage.heatmap.intensity")
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            tokenIntensityValue
                .frame(width: Metrics.tokenIntensityStripWidth)
        }
    }

    private var tokenIntensityMetricRow: some View {
        metricRowLayout {
            tokenIntensityDot
            Text("usage.heatmap.intensity")
                .foregroundStyle(.secondary)
                .frame(width: Metrics.metricLabelWidth, alignment: .leading)

            tokenIntensityValue
                .frame(width: Metrics.tokenIntensityStripWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var mostUsedModelMetricRow: some View {
        metricRowLayout {
            metricDot(tint: .cyan)
            Text("usage.heatmap.top-model")
                .foregroundStyle(.secondary)
                .frame(width: Metrics.metricLabelWidth, alignment: .leading)

            fittingModelValue(context.day.workflow.mostUsedModel ?? "--")
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

    @ViewBuilder
    private var tokenIntensityValue: some View {
        if context.day.tokenCount != nil {
            tokenIntensityStrip
        } else {
            Text(verbatim: "--")
                .foregroundStyle(Color.codexLabel)
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var workflowMetricRows: [WorkflowMetricRow] {
        [
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.sessions"),
                value: context.day.workflow.sessionCount,
                tint: .green
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.turns"),
                value: context.day.workflow.turnCount,
                tint: .teal
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.subagents"),
                value: context.day.workflow.subagentCount,
                tint: .indigo
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.tool-calls"),
                value: context.day.workflow.toolCallCount,
                tint: .orange
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.approvals"),
                value: context.day.workflow.permissionRequestCount,
                tint: .red
            ),
            WorkflowMetricRow(
                label: String(localized: "workflow.metric.compactions"),
                value: context.day.workflow.contextCompactionCount,
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
            tokenCount: context.day.tokenCount,
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
        fittingValueContent(value)
            .numericRollTransition(value: comparison)
            .layoutPriority(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func fittingModelValue(_ value: String) -> some View {
        fittingValueContent(value)
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

    private struct WorkflowMetricRow: Identifiable {
        let label: String
        let value: Int
        let tint: Color

        var id: String {
            label
        }
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 212
        static let workflowPanelHeight: CGFloat = 208
        static let tokenPanelHeight: CGFloat = 84
        static let sectionSpacing: CGFloat = 8
        static let headerSpacing: CGFloat = 10
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 12
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

/// token 详情在数字和 `--` 之间切换时只做淡入淡出, 数字之间仍保留滚动过渡
private struct HeatmapTokenText: View {
    let tokenCount: Int?
    let font: Font
    let numericWidth: CGFloat
    let unitWidth: CGFloat

    @State private var displayedTokenCount: Int?
    @State private var isVisible = true
    @State private var fadeTask: Task<Void, Never>?

    init(
        tokenCount: Int?,
        font: Font,
        numericWidth: CGFloat,
        unitWidth: CGFloat
    ) {
        self.tokenCount = tokenCount
        self.font = font
        self.numericWidth = numericWidth
        self.unitWidth = unitWidth
        _displayedTokenCount = State(initialValue: tokenCount)
    }

    var body: some View {
        content
            .opacity(isVisible ? 1 : 0)
            .frame(width: width, alignment: .trailing)
            .onChange(of: tokenCount) { _, newTokenCount in
                updateDisplayedTokenCount(newTokenCount)
            }
            .onDisappear {
                fadeTask?.cancel()
            }
    }

    @ViewBuilder
    private var content: some View {
        if let displayedTokenCount {
            TokenCountText(
                tokens: displayedTokenCount,
                font: font,
                reservedNumericWidth: numericWidth,
                reservedUnitWidth: unitWidth
            )
            .foregroundStyle(Color.codexLabel)
        } else {
            Text(verbatim: "--")
                .font(font)
                .foregroundStyle(Color.codexLabel)
        }
    }

    private func updateDisplayedTokenCount(_ newTokenCount: Int?) {
        fadeTask?.cancel()

        if (displayedTokenCount == nil) == (newTokenCount == nil) {
            updateTokenCountWithoutFade(newTokenCount)
            return
        }

        fadeToTokenCount(newTokenCount)
    }

    private func updateTokenCountWithoutFade(_ newTokenCount: Int?) {
        guard displayedTokenCount != newTokenCount || !isVisible else {
            return
        }

        withAnimation(Metrics.numericAnimation) {
            displayedTokenCount = newTokenCount
            isVisible = true
        }
    }

    private func fadeToTokenCount(_ newTokenCount: Int?) {
        fadeTask = Task { @MainActor in
            withAnimation(Metrics.fadeAnimation) {
                isVisible = false
            }

            try? await Task.sleep(for: .milliseconds(Metrics.fadeDelayMilliseconds))
            guard !Task.isCancelled else {
                return
            }

            displayedTokenCount = newTokenCount
            withAnimation(Metrics.fadeAnimation) {
                isVisible = true
            }

            fadeTask = nil
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
            .numericRollTransition(value: dateValue(components))
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
