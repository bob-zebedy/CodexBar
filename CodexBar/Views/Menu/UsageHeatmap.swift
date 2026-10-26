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

/// 选择跟随日期, 位置从最新网格计算
nonisolated struct UsageHeatmapSelection: Equatable {
    let dateID: String

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
        return UsageHeatmapSelection(dateID: day.id)
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
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations

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
                            .contentTransition(allowsAnimations ? .numericText() : .identity)
                            .animation(allowsAnimations ? .codexStatus : nil, value: modeTitle)
                    }
                    .buttonStyle(ModeButtonStyle())
                }
                .font(MenuMetrics.bodyFont)
                .foregroundStyle(.secondary)
                .fixedSize()

                Spacer(minLength: 0)

                if let dateRangeText {
                    Text(dateRangeText)
                        .font(MenuMetrics.bodyFont.monospacedDigit())
                        .foregroundStyle(Color.codexSecondaryLabel)
                        .contentTransition(allowsAnimations ? .numericText() : .identity)
                        .animation(allowsAnimations ? .codexStatus : nil, value: dateRangeText)
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
    @State private var hoverClearTask: Task<Void, Never>?
    @State private var frameProvider = ScreenFrameProvider()
    @State private var followsAppearanceTransition = false
    @State private var appearanceTransitionRevision = 0

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
        .background {
            ScreenFrameReader(provider: frameProvider)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: AppearanceTransition.didChangeNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === frameProvider.window else { return }
            if selection != nil, AppearanceTransition.isActive(in: window) {
                followsAppearanceTransition = true
            }
            guard followsAppearanceTransition else { return }
            appearanceTransitionRevision &+= 1
        }
        .onChange(of: days.map { $0?.id }) { _, _ in
            guard followsAppearanceTransition else { return }
            appearanceTransitionRevision &+= 1
        }
        .task(id: appearanceTransitionRevision) { [appearanceTransitionRevision] in
            await followAppearanceTransition(revision: appearanceTransitionRevision)
        }
        .onDisappear {
            followsAppearanceTransition = false
            cancelHoverClearTask()
            selection = nil
        }
    }

    @ViewBuilder
    private func square(column: Int, row: Int) -> some View {
        let index = column * Metrics.rowCount + row
        let day = days.indices.contains(index) ? days[index] : nil
        let isHovered = selection?.highlights(column: column, row: row, in: days, mode: mode) == true
        if mode == .weekly, weeks.indices.contains(column), let week = weeks[column] {
            let filledRows = week.filledRowCount(peakTokens: peakTokens)
            let isFilled = row >= Metrics.rowCount - filledRows
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isFilled
                    ? (colorScheme == .dark ? CodexDarkPalette.heatmap : Color.blue).opacity(0.82)
                    : (colorScheme == .dark ? CodexDarkPalette.raisedSurface.opacity(0.70) : Color.secondary.opacity(0.09)))
                .frame(width: Metrics.squareSize, height: Metrics.squareSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isFilled
                            ? (colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.25))
                            : CodexDarkPalette.heatmap.opacity(0.20))
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

        if selection != target {
            activate(target)
        }
    }

    private func snappedSelection(at point: CGPoint) -> UsageHeatmapSelection? {
        guard let (column, row) = Metrics.gridPosition(at: point),
              isSquareInteractive(column: column, row: row) else {
            return nil
        }
        return UsageHeatmapSelection.at(column: column, row: row, in: days, mode: mode)
    }

    private func followAppearanceTransition(revision: Int) async {
        guard !Task.isCancelled, revision == appearanceTransitionRevision,
              followsAppearanceTransition, let window = frameProvider.window else { return }
        defer {
            // 新任务可能已排队, 旧任务退出时不能清除它的跟踪状态
            if !Task.isCancelled, revision == appearanceTransitionRevision {
                followsAppearanceTransition = false
            }
        }
        // 快照可能中断 hover, 只在过渡期间按真实指针核对, 结束时再校准一次
        repeat {
            guard !Task.isCancelled, revision == appearanceTransitionRevision,
                  frameProvider.window === window,
                  window.isVisible, !window.isMiniaturized else { return }
            if let frame = frameProvider.currentScreenFrame(in: window, allowingCachedFrame: false) {
                let pointer = NSEvent.mouseLocation
                let point = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
                if frame.contains(pointer), let target = snappedSelection(at: point) {
                    cancelHoverClearTask()
                    if selection != target {
                        activate(target)
                    }
                } else if selection != nil, hoverClearTask == nil {
                    scheduleDeactivate()
                }
            }
            guard AppearanceTransition.isActive(in: window) else { return }
            try? await Task.sleep(for: .milliseconds(16))
        } while !Task.isCancelled
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

            hoverClearTask = nil
            withAnimation(.easeInOut(duration: Metrics.hoverFadeDuration)) {
                selection = nil
            }
        }
    }

    private func cancelHoverClearTask() {
        hoverClearTask?.cancel()
        hoverClearTask = nil
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
        static let hoverFadeDuration: TimeInterval = 0.15
        static let hoverExitGraceMilliseconds: UInt64 = 160
        static let entranceScale: CGFloat = 0.35
        static let entranceStagger: TimeInterval = 0.015
        static let entranceResponse: TimeInterval = 0.25
        static let entranceDampingFraction = 0.60

        static func gridPosition(at point: CGPoint) -> (column: Int, row: Int)? {
            let column = ((point.x - squareSize / 2) / squarePitch).rounded()
            let row = ((point.y - squareSize / 2) / squarePitch).rounded()
            // 先验证浮点索引, 避免非有限值或超大坐标在转为 Int 时崩溃
            guard column >= 0, column < CGFloat(columnCount),
                  row >= 0, row < CGFloat(rowCount) else { return nil }
            return (Int(column), Int(row))
        }

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
    @Environment(\.colorScheme) private var colorScheme

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
            return colorScheme == .dark
                ? CodexDarkPalette.raisedSurface.opacity(isHovered ? 1 : 0.70)
                : Color.blue.opacity(isHovered ? 0.16 : 0.08)
        }

        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return (colorScheme == .dark ? CodexDarkPalette.heatmap : Color.blue)
            .opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }

    private var borderColor: Color {
        if colorScheme == .dark {
            return isHovered ? CodexDarkPalette.heatmap.opacity(0.55) : .clear
        }
        guard tokenState.count != nil else {
            return Color.secondary.opacity(isHovered ? 0.42 : 0.12)
        }
        if isHovered {
            return Color.blue.opacity(0.78)
        }

        return Color.blue.opacity((tokenState.count ?? 0) > 0 ? 0.18 : 0.10)
    }

    private var shadowColor: Color {
        colorScheme == .dark || tokenState.count == nil ? .clear : .blue.opacity(0.22)
    }
}
