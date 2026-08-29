import SwiftUI

/// 单个额度窗口行, 布局宽度固定以避免不同文案撑宽菜单面板
struct QuotaRow: View {
    let window: QuotaWindow
    @Environment(\.mainPanelEntranceAnimationsEnabled) private var animatesEntrance
    @State private var revealedPercent: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(window.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(Metrics.labelMinimumScaleFactor)
                .allowsTightening(true)
                .frame(width: Metrics.labelWidth, alignment: .center)

            SegmentedQuotaBar(
                percent: displayedPercent,
                targetPercent: remainingPercent.map { Double($0) }
            )
            .padding(.leading, Metrics.labelBarSpacing)

            percentageValue
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .frame(width: Metrics.percentWidth, alignment: .leading)
                .padding(.leading, Metrics.barPercentSpacing)

            Spacer(minLength: Metrics.percentResetSpacing)

            Text(resetText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .frame(width: Metrics.resetWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: remainingPercent) {
            await revealPercent()
        }
    }
}

private extension QuotaRow {
    enum Metrics {
        static let labelWidth: CGFloat = 34
        static let labelMinimumScaleFactor: CGFloat = 0.75
        static let labelBarSpacing: CGFloat = 12
        static let barPercentSpacing: CGFloat = 8
        static let percentWidth: CGFloat = 37
        static let percentResetSpacing: CGFloat = 6
        static let resetWidth: CGFloat = 75
        static let entranceDuration: TimeInterval = 0.65
    }

    var resetText: String {
        guard window.hasData, let resetsAt = window.resetsAt else {
            return "--"
        }

        return Self.resetFormatter.string(from: resetsAt)
    }

    @ViewBuilder
    var percentageValue: some View {
        if let displayedPercent, let remainingPercent {
            AnimatedQuotaPercentageText(
                percent: displayedPercent,
                targetPercent: Double(remainingPercent)
            )
        } else {
            Text(verbatim: "--")
                .foregroundStyle(.secondary)
        }
    }

    var remainingPercent: Int? {
        window.hasData ? window.remainingPercent : nil
    }

    var displayedPercent: Double? {
        guard let remainingPercent else {
            return nil
        }

        return animatesEntrance ? revealedPercent : Double(remainingPercent)
    }

    func revealPercent() async {
        guard let remainingPercent else {
            revealedPercent = 0
            return
        }

        let targetPercent = Double(remainingPercent)
        guard animatesEntrance else {
            revealedPercent = targetPercent
            return
        }

        await Task.yield()
        guard !Task.isCancelled else {
            return
        }

        withAnimation(.easeOut(duration: Metrics.entranceDuration)) {
            revealedPercent = targetPercent
        }
    }

    static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMddjmm")
        return formatter
    }()
}

/// 通过 Animatable 的中间值让百分比数字和进度条保持同一动画进度
private struct AnimatedQuotaPercentageText: View, Animatable {
    var percent: Double
    let targetPercent: Double

    var animatableData: Double {
        get { percent }
        set { percent = newValue }
    }

    var body: some View {
        Text(CodexPercentageFormat.string(from: roundedPercent))
            .foregroundStyle(
                QuotaBarPalette.animatedColor(
                    for: percent,
                    targetPercent: targetPercent
                )
            )
            .numericRollTransition(value: Double(roundedPercent))
    }

    private var roundedPercent: Int {
        Int(percent.rounded())
    }
}

/// 分档色值来自共享的 QuotaPalette, 无数据时使用占位色
private enum QuotaBarPalette {
    static func animatedColor(for percent: Double, targetPercent: Double) -> Color {
        let currentPercent = min(max(percent, 0), 100)
        let clampedTargetPercent = min(max(targetPercent, 0), 100)

        guard currentPercent < clampedTargetPercent else {
            return QuotaPalette.color(for: Int(currentPercent.rounded()))
        }

        for (lowerTier, upperTier) in zip(
            QuotaPalette.tiers,
            QuotaPalette.tiers.dropFirst()
        ) {
            let upperBound = Double(upperTier.lowerBound)
            let transitionStart = upperBound - colorTransitionSpan
            guard clampedTargetPercent >= upperBound,
                  currentPercent >= transitionStart,
                  currentPercent < upperBound else {
                continue
            }

            let progress = (currentPercent - transitionStart) / colorTransitionSpan
            return Color(hex: lowerTier.hex).mix(
                with: Color(hex: upperTier.hex),
                by: smoothStep(progress),
                in: .device
            )
        }

        return QuotaPalette.color(for: Int(currentPercent.rounded()))
    }

    static let placeholderColor = Color(hex: 0xE5E7EB)
    private static let colorTransitionSpan = 4.0

    private static func smoothStep(_ value: Double) -> Double {
        let clampedValue = min(max(value, 0), 1)
        return clampedValue * clampedValue * (3 - 2 * clampedValue)
    }
}

/// 胶囊条, 与菜单面板宽度联动
private struct SegmentedQuotaBar: View, Animatable {
    var percent: Double
    let targetPercent: Double?
    var revealedWidth: CGFloat

    init(percent: Double?, targetPercent: Double?) {
        self.percent = percent ?? 0
        self.targetPercent = targetPercent
        revealedWidth = percent.map(Self.filledWidth(for:)) ?? 0
    }

    var animatableData: AnimatablePair<Double, CGFloat> {
        get { AnimatablePair(percent, revealedWidth) }
        set {
            percent = newValue.first
            revealedWidth = newValue.second
        }
    }

    var body: some View {
        let filledColor = targetPercent.map {
            QuotaBarPalette.animatedColor(for: percent, targetPercent: $0)
        } ?? QuotaBarPalette.placeholderColor

        ZStack(alignment: .leading) {
            segments(color: QuotaBarPalette.placeholderColor)

            segments(color: filledColor)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: revealedWidth)
                }
        }
        .frame(width: Metrics.totalWidth, height: Metrics.segmentHeight, alignment: .leading)
    }

    private func segments(color: Color) -> some View {
        HStack(spacing: Metrics.segmentSpacing) {
            ForEach(0 ..< Metrics.segmentCount, id: \.self) { _ in
                Capsule(style: .continuous)
                    .fill(color)
                    .frame(width: Metrics.segmentWidth, height: Metrics.segmentHeight)
            }
        }
    }
}

private extension SegmentedQuotaBar {
    enum Metrics {
        static let segmentCount = 50
        static let segmentWidth: CGFloat = 3.5
        static let segmentSpacing: CGFloat = 2
        static let segmentHeight: CGFloat = 12

        static var totalWidth: CGFloat {
            CGFloat(segmentCount) * segmentWidth + CGFloat(segmentCount - 1) * segmentSpacing
        }
    }

    static func filledWidth(for percent: Double) -> CGFloat {
        let filledSegments = Int((percent / 100.0 * Double(Metrics.segmentCount)).rounded())
        let count = min(max(filledSegments, 0), Metrics.segmentCount)
        guard count > 0 else {
            return 0
        }

        return CGFloat(count) * Metrics.segmentWidth + CGFloat(count - 1) * Metrics.segmentSpacing
    }
}
