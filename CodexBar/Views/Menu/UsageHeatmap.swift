import AppKit
import SwiftUI

/// hover 详情面板需要的完整上下文, 包括屏幕坐标和峰值 token
nonisolated struct UsageHeatmapHoverContext: Equatable {
    let day: UsageHeatmapDay
    let showsActivity: Bool
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

// MARK: - 热力图与 hover 吸附

/// 近期 Token 用量热力图, hover 时把指针吸附到最近的有效日期格
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
