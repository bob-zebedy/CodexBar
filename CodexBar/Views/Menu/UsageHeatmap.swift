import AppKit
import SwiftUI

/// hover 详情面板需要的完整上下文, 包括屏幕坐标和峰值 token
nonisolated struct UsageHeatmapHoverContext: Equatable {
    let period: UsageHeatmapPeriod
    let mode: UsageHeatmapMode
    let isStale: Bool
    let alignmentScreenFrame: CGRect?
    let preferredSide: UsageHeatmapDetailSide
    let peakTokens: Int
}

nonisolated enum UsageHeatmapDetailSide: Equatable {
    case left
    case right
}

/// 日期标识跟随数据刷新, 列/行位置只记录指针命中时的坐标
nonisolated struct UsageHeatmapSelection: Equatable {
    let dateID: String
    let column: Int
    let row: Int

    func day(in days: [UsageHeatmapDay?]) -> UsageHeatmapDay? {
        days.lazy.compactMap(\.self).first { $0.id == dateID }
    }

    func currentColumn(in days: [UsageHeatmapDay?]) -> Int? {
        days.firstIndex { $0?.id == dateID }.map { $0 / CodexWeekGrid.rowCount }
    }

    func period(in days: [UsageHeatmapDay?], weeks: [UsageHeatmapPeriod?], mode: UsageHeatmapMode) -> UsageHeatmapPeriod? {
        guard let index = days.firstIndex(where: { $0?.id == dateID }) else { return nil }
        switch mode {
        case .daily:
            return days[index].flatMap { UsageHeatmapPeriod(days: [$0]) }
        case .weekly:
            let column = index / CodexWeekGrid.rowCount
            return weeks.indices.contains(column) ? weeks[column] : nil
        }
    }

    static func at(column: Int, row: Int, in days: [UsageHeatmapDay?], mode: UsageHeatmapMode) -> UsageHeatmapSelection? {
        guard column >= 0, column < (days.count + CodexWeekGrid.rowCount - 1) / CodexWeekGrid.rowCount,
              (0 ..< CodexWeekGrid.rowCount).contains(row) else { return nil }
        let selectedRow = mode == .daily ? row : 0
        let index = column * CodexWeekGrid.rowCount + selectedRow
        guard days.indices.contains(index), let day = days[index] else { return nil }
        return UsageHeatmapSelection(dateID: day.id, column: column, row: selectedRow)
    }

    func highlights(column: Int, row: Int, in days: [UsageHeatmapDay?], mode: UsageHeatmapMode) -> Bool {
        Self.at(column: column, row: row, in: days, mode: mode)?.dateID == dateID
    }
}

// MARK: - 热力图与 hover 吸附

/// 近期 Token 用量热力图, hover 时把指针吸附到最近的有效日期格
struct UsageHeatmap: View {
    let days: [UsageHeatmapDay?]
    let weeks: [UsageHeatmapPeriod?]
    @Binding var mode: UsageHeatmapMode
    @Binding var selection: UsageHeatmapSelection?
    let peakTokens: Int
    var onScreenFrameChange: (CGRect?) -> Void = { _ in }
    @Environment(\.mainPanelAnimationsEnabled) private var allowsAnimations

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(LocalizedStringResource("usage.heatmap.past-weeks", defaultValue: "\(Metrics.columnCount, specifier: "%lld")"))
                    Text(verbatim: "•")
                    Button {
                        selection = nil
                        mode = mode == .daily ? .weekly : .daily
                    } label: {
                        Text(modeTitle)
                            .foregroundStyle(Color.codexSecondaryLabel)
                            .numericTransition(value: modeTitle, enabled: allowsAnimations)
                    }
                    .buttonStyle(ModeButtonStyle())
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize()

                Spacer(minLength: 0)

                if let dateRangeText {
                    Text(dateRangeText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .numericTransition(value: dateRangeText, enabled: allowsAnimations)
                        .lineLimit(1)
                }
            }

            UsageHeatmapGrid(days: days, weeks: weeks, mode: mode, selection: $selection, peakTokens: peakTokens)
                // 切换模式重新创建网格, 复用入场动画和任务取消边界
                .id(mode)
                .transition(.identity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.height)
        .background {
            ScreenFrameReader(onChange: onScreenFrameChange)
        }
        .onDisappear {
            onScreenFrameChange(nil)
        }
    }

    private struct ModeButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }

    private var modeTitle: String {
        switch mode {
        case .daily:
            String(localized: "usage.heatmap.daily-data")
        case .weekly:
            String(localized: "usage.heatmap.weekly-data")
        }
    }

    private var dateRangeText: String? {
        let firstDate: String?
        let lastDate: String?
        switch mode {
        case .daily:
            let visibleDays = days.compactMap(\.self)
            firstDate = visibleDays.first?.startDate
            lastDate = visibleDays.last?.startDate
        case .weekly:
            let visibleWeeks = weeks.compactMap(\.self)
            firstDate = visibleWeeks.first?.startDate
            lastDate = visibleWeeks.last?.endDate
        }
        guard let firstDate, let lastDate else { return nil }
        let firstText = localDayText(firstDate)
        let lastText = localDayText(lastDate)
        return String(localized: "date-range.closed", defaultValue: "\(firstText)\(lastText)")
    }

    private func localDayText(_ dayKey: String) -> String {
        guard let date = CodexDateFormat.dayDate(from: dayKey) else {
            return dayKey
        }
        return CodexDateFormat.localDayDisplayString(from: date)
    }
}

/// 网格持有一次入场的动画和 hover 任务, 模式切换时与旧网格一起取消
private struct UsageHeatmapGrid: View {
    typealias Metrics = UsageHeatmap.Metrics

    let days: [UsageHeatmapDay?]
    let weeks: [UsageHeatmapPeriod?]
    let mode: UsageHeatmapMode
    @Binding var selection: UsageHeatmapSelection?
    let peakTokens: Int
    @Environment(\.mainPanelEntranceAnimationsEnabled) private var animatesEntrance
    @Environment(\.colorScheme) private var colorScheme
    @State private var areSquaresRevealed = false
    @State private var entranceStartedAt: TimeInterval?
    @State private var snapSelection: UsageHeatmapSelection?
    @State private var hoverClearTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.squareSpacing) {
            ForEach(0 ..< Metrics.columnCount, id: \.self) { column in
                VStack(spacing: Metrics.squareSpacing) {
                    ForEach(0 ..< Metrics.rowCount, id: \.self) { row in
                        square(column: column, row: row)
                            .opacity(showsSquares ? 1 : 0)
                            .scaleEffect(showsSquares ? 1 : Metrics.entranceScale)
                            .animation(entranceAnimation(column: column, row: row), value: showsSquares)
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
        .task {
            await revealSquares()
        }
        .onChange(of: days) { _, newDays in
            guard let snapSelection, snapSelection.day(in: newDays) == nil else { return }
            cancelHoverClearTask()
            withAnimation(.snappy(duration: Metrics.snapAnimationDuration)) {
                self.snapSelection = nil
            }
        }
        .onDisappear {
            cancelHoverClearTask()
            snapSelection = nil
            selection = nil
        }
    }

    @ViewBuilder
    private func square(column: Int, row: Int) -> some View {
        let index = column * Metrics.rowCount + row
        let day = days.indices.contains(index) ? days[index] : nil
        let isHovered = snapSelection?.highlights(column: column, row: row, in: days, mode: mode) == true
        if mode == .weekly, weeks.indices.contains(column), let week = weeks[column] {
            let filledRows = week.filledRowCount(peakTokens: peakTokens)
            let isFilled = row >= Metrics.rowCount - filledRows
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isFilled ? Color.blue.opacity(0.82) : Color.secondary.opacity(0.09))
                .frame(width: Metrics.squareSize, height: Metrics.squareSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isFilled
                            ? (colorScheme == .dark ? Color.white : Color.black).opacity(0.25)
                            : Color.blue.opacity(0.15))
                        .opacity(isHovered ? 1 : 0)
                        .animation(.snappy(duration: 0.14), value: isHovered)
                        .allowsHitTesting(false)
                }
        } else if mode == .daily, let day {
            UsageHeatmapSquare(
                tokenState: day.tokenState,
                percent: Double(day.tokensForHeatmap) / Double(peakTokens),
                isHovered: isHovered
            )
        } else {
            Color.clear
                .frame(width: Metrics.squareSize, height: Metrics.squareSize)
        }
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

        return UsageHeatmapSelection.at(column: column, row: row, in: days, mode: mode)
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
        lhs?.dateID == rhs.dateID && lhs?.column == rhs.column && lhs?.row == rhs.row
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

/// 日视图用透明度表示用量强度
private struct UsageHeatmapSquare: View {
    let tokenState: UsageHeatmapTokenState
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
        guard tokenState.count != nil else {
            return Color.secondary.opacity(isHovered ? 0.12 : 0.05)
        }
        guard (tokenState.count ?? 0) > 0 else {
            return Color.blue.opacity(isHovered ? 0.16 : 0.08)
        }

        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return Color.blue.opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }

    private var borderColor: Color {
        guard tokenState.count != nil else {
            return Color.secondary.opacity(isHovered ? 0.42 : 0.12)
        }
        if isHovered {
            return Color.blue.opacity(0.78)
        }

        return Color.blue.opacity((tokenState.count ?? 0) > 0 ? 0.18 : 0.10)
    }

    private var shadowColor: Color {
        tokenState.count == nil ? .clear : .blue.opacity(0.22)
    }
}
