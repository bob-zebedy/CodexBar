import AppKit
import SwiftUI

/// hover 详情面板需要的完整上下文, 包括屏幕坐标和峰值 token
nonisolated struct UsageHeatmapHoverContext: Equatable {
    let period: UsageHeatmapPeriod
    let mode: UsageHeatmapMode
    let isStale: Bool
    let alignmentScreenFrame: CGRect?
    let preferredSide: SidePanelSide
    let peakTokens: Int
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
            return days[index].map { UsageHeatmapPeriod(day: $0) }
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
    let peakDailyTokens: Int
    let peakWeeklyTokens: Int
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

            UsageHeatmapGrid(days: days, weeks: weeks, mode: mode, selection: $selection, peakDailyTokens: peakDailyTokens, peakWeeklyTokens: peakWeeklyTokens)
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

struct UsageHeatmapGrid: View {
    typealias Metrics = UsageHeatmap.Metrics

    let days: [UsageHeatmapDay?]
    let weeks: [UsageHeatmapPeriod?]
    let mode: UsageHeatmapMode
    @Binding var selection: UsageHeatmapSelection?
    let peakDailyTokens: Int
    let peakWeeklyTokens: Int
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @Environment(\.mainPanelEntranceAnimationsEnabled) private var animatesHeatmapTransitions
    @Environment(\.isMenuHostPresented) private var isMenuHostPresented
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeTransition: UsageHeatmapTransition?
    @State private var pausedAt: TimeInterval?
    @State private var hoverClearTask: Task<Void, Never>?
    @State private var frameProvider = ScreenFrameProvider()
    @State private var appearanceTrackingID: UUID?

    var body: some View {
        TimelineView(.animation(paused: activeTransition == nil || !isMenuHostPresented)) { _ in
            let now = pausedAt ?? uptime()
            let sampleFrame = activeTransition?.frameSampler(at: now)
            let restingFrame = UsageHeatmapTransition.Frame.resting(mode)
            HStack(alignment: .top, spacing: Metrics.squareSpacing) {
                ForEach(0 ..< Metrics.columnCount, id: \.self) { column in
                    VStack(spacing: Metrics.squareSpacing) {
                        ForEach(0 ..< Metrics.rowCount, id: \.self) { row in
                            let timing = UsageHeatmapTransition.tileTimings[column * Metrics.rowCount + row]
                            HeatmapJellySquare(frame: sampleFrame?(timing) ?? restingFrame) { displayedMode, cornerRadius in
                                square(column: column, row: row, displayedMode: displayedMode, cornerRadius: cornerRadius)
                            }
                        }
                    }
                }
            }
            .onChange(of: activeTransition.flatMap { now >= $0.endsAt ? $0.startedAt : nil }, initial: true) { _, finished in
                if let finished, activeTransition?.startedAt == finished {
                    activeTransition = nil
                }
            }
        }
        .frame(width: Metrics.totalWidth, height: Metrics.gridHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .background {
            ScreenFrameReader(provider: frameProvider)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard isMenuHostPresented else { return }
            switch phase {
            case let .active(point):
                updatePointerLocation(point)
            case .ended:
                scheduleDeactivate()
            }
        }
        .onChange(of: isMenuHostPresented, initial: true) { _, presented in
            // 关闭时停在当前帧, 让面板从这里淡出
            pausedAt = presented ? nil : uptime()
            if presented {
                startTransition(from: nil)
            } else {
                appearanceTrackingID = nil
                cancelHoverClearTask()
                selection = nil
            }
        }
        .onChange(of: mode) { oldMode, _ in
            guard isMenuHostPresented else { return }
            cancelHoverClearTask()
            selection = nil
            startTransition(from: oldMode)
            if appearanceTrackingID != nil {
                appearanceTrackingID = UUID()
            }
        }
        .onChange(of: animatesHeatmapTransitions) { _, enabled in
            if !enabled {
                activeTransition = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppearanceTransition.didChangeNotification)) { notification in
            guard isMenuHostPresented, let window = notification.object as? NSWindow, window === frameProvider.window,
                  appearanceTrackingID != nil || (selection != nil && AppearanceTransition.isActive(in: window)) else { return }
            appearanceTrackingID = UUID()
        }
        .onChange(of: days.map { $0?.id }) { _, _ in
            if appearanceTrackingID != nil {
                appearanceTrackingID = UUID()
            }
        }
        .task(id: appearanceTrackingID) { [appearanceTrackingID] in
            if let appearanceTrackingID {
                await followAppearanceTransition(id: appearanceTrackingID)
            }
        }
        .onDisappear {
            appearanceTrackingID = nil
            cancelHoverClearTask()
            selection = nil
        }
    }

    @ViewBuilder
    private func square(column: Int, row: Int, displayedMode: UsageHeatmapMode, cornerRadius: CGFloat) -> some View {
        let index = column * Metrics.rowCount + row
        let day = days.indices.contains(index) ? days[index] : nil
        let isHovered = displayedMode == mode && selection?.highlights(column: column, row: row, in: days, mode: mode) == true
        if displayedMode == .weekly, weeks.indices.contains(column), let week = weeks[column] {
            let filledRows = week.filledRowCount(peakTokens: peakWeeklyTokens)
            let isFilled = row >= Metrics.rowCount - filledRows
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(isFilled
                    ? (colorScheme == .dark ? CodexDarkPalette.heatmap : Color.blue).opacity(0.82)
                    : (colorScheme == .dark ? CodexDarkPalette.raisedSurface.opacity(0.70) : Color.secondary.opacity(0.09)))
                .overlay {
                    shape
                        .fill(isFilled
                            ? (colorScheme == .dark ? Color.white.opacity(0.25) : Color.black.opacity(0.25))
                            : CodexDarkPalette.heatmap.opacity(0.20))
                        .opacity(isHovered ? 1 : 0)
                        .animation(.snappy(duration: 0.14), value: isHovered)
                        .allowsHitTesting(false)
                }
        } else if displayedMode == .daily, let day {
            UsageHeatmapSquare(
                tokenState: day.tokenState,
                percent: Double(day.tokensForHeatmap) / Double(peakDailyTokens),
                isHovered: isHovered,
                cornerRadius: cornerRadius
            )
        }
    }

    private func startTransition(from oldMode: UsageHeatmapMode?) {
        activeTransition = animatesHeatmapTransitions ? UsageHeatmapTransition(to: mode, from: oldMode, interrupting: activeTransition, at: uptime()) : nil
    }

    private func isSquareInteractive(column: Int, row: Int) -> Bool {
        guard isMenuHostPresented else { return false }
        guard let activeTransition else { return true }
        let timing = UsageHeatmapTransition.tileTimings[column * Metrics.rowCount + row]
        let sampleFrame = activeTransition.frameSampler(at: uptime())
        let frame = sampleFrame(timing)
        return frame.isSettled && frame.mode == mode
    }

    private func updatePointerLocation(_ point: CGPoint) {
        guard let target = snappedSelection(at: point) else {
            scheduleDeactivate()
            return
        }

        activate(target)
    }

    private func snappedSelection(at point: CGPoint) -> UsageHeatmapSelection? {
        guard let (column, row) = Metrics.gridPosition(at: point),
              isSquareInteractive(column: column, row: row) else {
            return nil
        }
        return UsageHeatmapSelection.at(column: column, row: row, in: days, mode: mode)
    }

    private func followAppearanceTransition(id: UUID) async {
        defer {
            // 新任务可能已排队, 旧任务退出时不能清除它的跟踪状态
            if !Task.isCancelled, appearanceTrackingID == id {
                appearanceTrackingID = nil
            }
        }
        guard let window = frameProvider.window else { return }
        // 快照可能中断 hover, 只在过渡期间按真实指针核对, 结束时再校准一次
        while !Task.isCancelled, appearanceTrackingID == id, frameProvider.window === window,
              window.isVisible, !window.isMiniaturized {
            if let frame = frameProvider.currentScreenFrame(in: window, allowingCachedFrame: false) {
                let pointer = NSEvent.mouseLocation
                let point = CGPoint(x: pointer.x - frame.minX, y: frame.maxY - pointer.y)
                if frame.contains(pointer), let target = snappedSelection(at: point) {
                    activate(target)
                } else if hoverClearTask == nil {
                    scheduleDeactivate()
                }
            }
            guard AppearanceTransition.isActive(in: window) else { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func activate(_ target: UsageHeatmapSelection) {
        cancelHoverClearTask()
        guard selection != target else { return }
        withAnimation(.easeInOut(duration: Metrics.hoverFadeDuration)) {
            selection = target
        }
    }

    private func scheduleDeactivate() {
        guard selection != nil else { return }
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

        static func preferredDetailSide(for column: Int) -> SidePanelSide {
            column < columnCount / 2 ? .left : .right
        }
    }
}

// MARK: - 单元格

struct UsageHeatmapTransition {
    struct TileTiming {
        let delay: TimeInterval
        let duration: TimeInterval
    }

    struct Frame: Equatable {
        let mode: UsageHeatmapMode
        let scale: Double
        let isSettled: Bool

        var cornerRadius: CGFloat {
            let roundness = UsageHeatmapTransition.ease((1 - scale) / 0.45)
            let circleRadius = UsageHeatmap.Metrics.squareSize / 2
            return 4 + (circleRadius - 4) * roundness
        }

        static func resting(_ mode: UsageHeatmapMode) -> Self {
            Self(mode: mode, scale: 1, isSettled: true)
        }

        fileprivate static func sample(from source: UsageHeatmapMode?, to destination: UsageHeatmapMode, progress: Double) -> Self {
            if progress >= 1 {
                return .resting(destination)
            }
            if let source, progress <= 0 {
                return .resting(source)
            }

            let mode = progress < 0.5 ? source ?? destination : destination
            let scale: Double
            if progress >= 0.8 {
                scale = 1 + 0.06 * UsageHeatmapTransition.ease((1 - progress) / 0.2)
            } else if source != nil, progress < 0.5 {
                scale = 1 - UsageHeatmapTransition.ease(progress / 0.46)
            } else {
                // 切换日周时在零尺寸换色, 首次入场直接展开
                let start = source == nil ? 0.0 : 0.54
                scale = 1.06 * UsageHeatmapTransition.ease((progress - start) / (0.8 - start))
            }
            return Self(mode: mode, scale: scale, isSettled: false)
        }
    }

    private static let baseDiagonalInterval: TimeInterval = 0.024
    private static let waveWidthInCells = 5.0

    /// 节奏按网格位置只抽取一次, 连续切换和重新开面板时仍沿用
    static let tileTimings: [TileTiming] = {
        let timings = (0 ..< UsageHeatmap.Metrics.columnCount).flatMap { column in
            (0 ..< UsageHeatmap.Metrics.rowCount).map { row in
                let diagonal = column + row
                let delay = Double(diagonal) * baseDiagonalInterval + (diagonal == 0 ? 0 : .random(in: -0.015 ... 0.055))
                let duration = waveWidthInCells * baseDiagonalInterval * Double.random(in: 0.8 ... 1.2)
                return TileTiming(delay: delay, duration: duration)
            }
        }
        guard let lastEnd = timings.map({ $0.delay + $0.duration }).max() else { return [] }
        let timeScale = MenuMetrics.contentEntranceDuration / lastEnd
        return timings.map { TileTiming(delay: $0.delay * timeScale, duration: $0.duration * timeScale) }
    }()

    let startedAt: TimeInterval
    private let target: UsageHeatmapMode
    private let sourceMode: UsageHeatmapMode?
    private let startOffset: TimeInterval

    private var targetOffset: TimeInterval {
        // 零点是原模式或空网格, 负方向展开日数据, 正方向展开周数据
        if target == sourceMode {
            return 0
        }
        return target == .daily ? -MenuMetrics.contentEntranceDuration : MenuMetrics.contentEntranceDuration
    }

    var endsAt: TimeInterval {
        startedAt + abs(targetOffset - startOffset)
    }

    init(to mode: UsageHeatmapMode, from oldMode: UsageHeatmapMode?, interrupting previous: Self?, at now: TimeInterval) {
        startedAt = now
        target = mode
        if oldMode != nil, let previous, now < previous.endsAt {
            // 反向播放原时间线, 每格的延迟和换色过程一起倒放
            sourceMode = previous.sourceMode
            startOffset = previous.playhead(at: now)
        } else {
            sourceMode = oldMode
            startOffset = 0
        }
    }

    func frameSampler(at now: TimeInterval) -> (TileTiming) -> Frame {
        guard now < endsAt else {
            let frame = Frame.resting(target)
            return { _ in frame }
        }
        let time = playhead(at: now)
        let destination: UsageHeatmapMode = time <= 0 ? .daily : .weekly
        let elapsed = abs(time)
        return { timing in
            Frame.sample(from: sourceMode, to: destination, progress: (elapsed - timing.delay) / timing.duration)
        }
    }

    fileprivate static func ease(_ fraction: Double) -> Double {
        let t = min(1, max(0, fraction))
        return t * t * (3 - 2 * t)
    }

    private func playhead(at now: TimeInterval) -> TimeInterval {
        let elapsed = max(0, now - startedAt)
        return targetOffset < startOffset ? max(targetOffset, startOffset - elapsed) : min(targetOffset, startOffset + elapsed)
    }
}

private struct HeatmapJellySquare<Content: View>: View {
    let frame: UsageHeatmapTransition.Frame
    @ViewBuilder let content: (UsageHeatmapMode, CGFloat) -> Content

    var body: some View {
        Color.clear
            .frame(width: UsageHeatmap.Metrics.squareSize, height: UsageHeatmap.Metrics.squareSize)
            .overlay {
                if frame.scale > 0 {
                    content(frame.mode, frame.cornerRadius)
                        .animation(nil) { square in
                            square
                                .scaleEffect(frame.scale)
                                .opacity(min(1, frame.scale))
                        }
                        .transition(.identity)
                }
            }
    }
}

/// 日视图用透明度表示用量强度
private struct UsageHeatmapSquare: View {
    let tokenState: UsageHeatmapTokenState
    let percent: Double
    let isHovered: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(fillColor)
            .overlay {
                shape
                    .stroke(borderColor, lineWidth: isHovered ? 1.2 : 0.7)
            }
            .shadow(color: shadowColor, radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
            .scaleEffect(isHovered ? 1.08 : 1)
            .contentShape(shape)
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
            return isHovered ? CodexDarkPalette.heatmap.opacity(0.55) : Color.clear
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
        colorScheme == .dark || tokenState.count == nil ? Color.clear : Color.blue.opacity(0.22)
    }
}
