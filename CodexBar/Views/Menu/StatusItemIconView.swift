import AppKit
import Combine
import SwiftUI

final class StatusItemIconPresentation: ObservableObject {
    struct Indicator: Equatable {
        let percent: Double
        let isStale: Bool
        var isVisible = true
    }

    struct State: Equatable {
        var isUnavailable = false
        var isOrdinaryUsageRestricted = false
        var indicators = Array(repeating: Indicator(percent: 0, isStale: false, isVisible: false), count: 2)
        var usesSplitRingStyle = false

        var showsIndicators: Bool {
            indicators.contains(where: \.isVisible)
        }

        var isStale: Bool {
            showsIndicators && indicators.filter(\.isVisible).allSatisfy(\.isStale)
        }
    }

    @Published private(set) var state = State()

    func update(isUnavailable: Bool, ordinaryUsageAllowed: Bool?, indicators: [Indicator?], animated: Bool) {
        var next = state
        next.isUnavailable = isUnavailable
        next.isOrdinaryUsageRestricted = ordinaryUsageAllowed == false
        // 隐藏时保留颜色和几何, 让原来的弧线连续收回至零
        if !indicators.isEmpty {
            next.usesSplitRingStyle = indicators.count > 1
        }
        for index in next.indicators.indices {
            if indicators.indices.contains(index), let indicator = indicators[index] {
                next.indicators[index] = indicator
            } else {
                next.indicators[index].isVisible = false
            }
        }
        guard next != state else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = !animated
        withTransaction(transaction) {
            state = next
        }
    }
}

final class StatusItemIconHostingView: NSHostingView<StatusItemIconView> {
    /// 图标不接管点击和焦点, 继续由原生菜单栏按钮处理左右键
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }
}

struct StatusItemIconView: View {
    @ObservedObject var presentation: StatusItemIconPresentation
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    static let size = NSSize(width: 26, height: 22)
    private static var symbolImages: [String: [CGFloat: CGImage]] = [:]

    var body: some View {
        let state = presentation.state
        let symbolName = state.isUnavailable ? "person" : "person.fill"
        ZStack {
            ForEach(state.indicators.indices, id: \.self) { index in
                indicatorArc(state.indicators[index], index: index)
            }

            ZStack {
                symbolImage(named: symbolName)
                    .id(symbolName)
                    .transition(.opacity)
            }
            .foregroundStyle(symbolColor)
            .animation(.easeInOut(duration: 0.2), value: state.isUnavailable)
            .animation(.easeInOut(duration: 0.2), value: state.isOrdinaryUsageRestricted)
            .scaleEffect(
                state.showsIndicators ? 1 : 16.0 / 14.0,
                anchor: UnitPoint(x: 0.5, y: 18.0 / 22.0)
            )
            .offset(y: state.showsIndicators ? 0 : -1)
            .opacity(state.isStale ? 0.75 : 1)
            .animation(.easeInOut(duration: 0.2), value: state.showsIndicators)
        }
        // 菜单栏跨桌面切换时使用图标快照, 先合成圆弧和人物以保持绘制一致
        .drawingGroup()
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
    }

    private func indicatorArc(_ indicator: StatusItemIconPresentation.Indicator, index: Int) -> some View {
        let usesSplitRingStyle = index > 0 || presentation.state.usesSplitRingStyle
        let isRightSide = index > 0
        let radius = usesSplitRingStyle ? Metrics.splitRadius : Metrics.singleRadius
        let fullSweepAngle = usesSplitRingStyle ? Metrics.splitSweepAngle : Metrics.singleSweepAngle
        let startAngle = -90 + (isRightSide ? 1 : -1) * fullSweepAngle / 2
        let sweepAngle = usesSplitRingStyle
            ? (isRightSide ? -1 : 1) * (fullSweepAngle / 2 - Metrics.halfGapAngle)
            : fullSweepAngle
        let style = StrokeStyle(lineWidth: Metrics.lineWidth, lineCap: .round)
        return ZStack {
            StatusItemIndicatorArc(radius: radius, startAngle: startAngle, sweepAngle: sweepAngle)
                .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.34), style: style)
                .opacity(indicator.isVisible ? 1 : 0)
            StatusItemIndicatorArc(
                radius: radius,
                startAngle: startAngle,
                sweepAngle: sweepAngle,
                percent: indicator.isVisible ? indicator.percent : 0
            )
            .stroke(QuotaPalette.color(for: Int(indicator.percent)), style: style)
        }
        .opacity(indicator.isStale ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.3), value: indicator.isVisible)
        .animation(.easeInOut(duration: 0.3), value: indicator.percent)
        .animation(.easeInOut(duration: 0.3), value: usesSplitRingStyle)
    }

    private var symbolColor: Color {
        if presentation.state.isUnavailable {
            return .primary
        }
        guard presentation.state.isOrdinaryUsageRestricted else { return .primary }
        return Color(hex: colorScheme == .dark ? 0xE8B27C : 0xD99858)
    }

    @ViewBuilder
    private func symbolImage(named name: String) -> some View {
        let scale = ceil(max(displayScale, 1) * 16 / 14)
        if let image = Self.rasterizedSymbol(named: name, displayScale: displayScale, scale: scale) {
            Image(decorative: image, scale: scale)
                .renderingMode(.template)
        } else {
            Self.symbolContent(named: name)
        }
    }

    private static func rasterizedSymbol(named name: String, displayScale: CGFloat, scale: CGFloat) -> CGImage? {
        if let image = symbolImages[name]?[displayScale] {
            return image
        }

        // 只在图形或屏幕倍率首次出现时栅格化, 缩放过程复用普通图片
        let renderer = ImageRenderer(content: symbolContent(named: name)
            .foregroundStyle(.white)
            .environment(\.displayScale, displayScale))
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            return nil
        }
        symbolImages[name, default: [:]][displayScale] = image
        return image
    }

    private static func symbolContent(named name: String) -> some View {
        // 固定基线作为缩放锚点, 保持指示器切换时人物主体的位置稳定
        Color.clear
            .frame(width: size.width, height: size.height)
            .alignmentGuide(.firstTextBaseline) { _ in 18 }
            .overlay(alignment: .centerFirstTextBaseline) {
                Image(systemName: name)
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(.monochrome)
            }
    }

    private enum Metrics {
        static let singleRadius: CGFloat = 11
        static let splitRadius: CGFloat = 11.5
        static let lineWidth: CGFloat = 2
        static let centerGap: CGFloat = 1
        static let singleSweepAngle = 180 + 2 * asin(5.0 / 11.0) * 180 / .pi
        static let splitSweepAngle = 234.0
        static let halfGapAngle = asin((lineWidth + centerGap) / (2 * splitRadius)) * 180 / .pi
    }
}

private nonisolated struct StatusItemIndicatorArc: Shape {
    var radius: CGFloat
    var startAngle: Double
    var sweepAngle: Double
    var percent: Double = 100

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(radius, startAngle), AnimatablePair(sweepAngle, percent)) }
        set {
            radius = newValue.first.first
            startAngle = newValue.first.second
            sweepAngle = newValue.second.first
            percent = newValue.second.second
        }
    }

    func path(in _: CGRect) -> Path {
        guard percent > 0 else { return Path() }
        let endAngle = startAngle + sweepAngle * min(percent, 100) / 100
        var path = Path()
        path.addArc(
            center: CGPoint(x: 13, y: 14),
            radius: radius,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: sweepAngle < 0
        )
        return path
    }
}
