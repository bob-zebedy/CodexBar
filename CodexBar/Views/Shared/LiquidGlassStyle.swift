import AppKit
import Combine
import SwiftUI

/// CodexBar 统一的短状态动画
extension Animation {
    static let codexStatus = Animation.easeInOut(duration: 0.20)
}

/// 共享语义色和 Display P3 十六进制初始化
extension Color {
    // 某些自定义 View 需要具体 Color
    // 不能直接使用 .primary/.secondary 这类 ShapeStyle
    static let codexLabel = Color(nsColor: NSColor.labelColor)
    static let codexSecondaryLabel = Color(nsColor: NSColor.secondaryLabelColor)

    nonisolated init(displayP3Hex hex: Int) {
        self.init(
            .displayP3,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// 深色界面用背景明度区分层级, 强调色只用于数据和交互状态
enum CodexDarkPalette {
    static let background = Color(displayP3Hex: 0x181B21)
    static let surface = Color(displayP3Hex: 0x232831)
    static let raisedSurface = Color(displayP3Hex: 0x2D333F)
    static let track = Color(displayP3Hex: 0x3B434F)
    static let heatmap = Color(displayP3Hex: 0x7D9CDB)
    static let separator = Color.white.opacity(0.06)
    static let outline = Color.white.opacity(0.08)
}

// MARK: - View 修饰符

extension EnvironmentValues {
    @Entry var contentAnimationsEnabled = false
}

extension View {
    func contentAnimations(settings: MainPanelSettings, isVisible: Bool = true) -> some View {
        modifier(ContentAnimationsModifier(settings: settings, isVisible: isVisible))
    }

    /// 数值比较决定滚动方向, 复合文案按显示内容触发过渡
    func numericTransition(
        value: some Equatable,
        comparison: Double? = nil
    ) -> some View {
        modifier(NumericTransitionModifier(value: value, comparison: comparison))
    }
}

private struct ContentAnimationsModifier: ViewModifier {
    @ObservedObject var settings: MainPanelSettings
    let isVisible: Bool

    func body(content: Content) -> some View {
        let enabled = settings.areAnimationsEnabled && isVisible
        content
            .environment(\.contentAnimationsEnabled, enabled)
            .transaction { transaction in
                // 隐藏的宿主仍可能绘制数字过渡, 必须同时阻止子视图重新开启动画
                guard !enabled else { return }
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
    }
}

private struct NumericTransitionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    let value: Value
    let comparison: Double?

    func body(content: Content) -> some View {
        let transition: ContentTransition = if let comparison {
            .numericText(value: comparison)
        } else {
            .numericText()
        }
        content
            .contentTransition(allowsAnimations ? transition : .identity)
            .animation(allowsAnimations ? .codexStatus : nil, value: value)
    }
}

/// 自绘 Liquid Glass 背景和 stale 状态修饰
extension View {
    func liquidGlassSurface(
        cornerRadius: CGFloat,
        isOuterSurface: Bool = false
    ) -> some View {
        liquidGlassSurface(
            cornerRadii: RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            ),
            isOuterSurface: isOuterSurface
        )
    }

    func liquidGlassSurface(
        cornerRadii: RectangleCornerRadii,
        isOuterSurface: Bool = false
    ) -> some View {
        background {
            LiquidGlassSurface(
                cornerRadii: cornerRadii,
                isOuterSurface: isOuterSurface
            )
        }
    }

    func liquidGlassCapsule(tint: Color) -> some View {
        liquidGlassBadge(tint: tint, in: Capsule(style: .continuous))
    }

    func liquidGlassBadge(tint: Color, in shape: some InsettableShape, showsTopHighlight: Bool = true) -> some View {
        background {
            LiquidGlassBadge(tint: tint, shape: shape, showsTopHighlight: showsTopHighlight)
        }
    }

    /// 数据为缓存回退 (本轮刷新失败) 时弱化显示
    func markStale(_ isStale: Bool) -> some View {
        opacity(isStale ? 0.55 : 1)
    }

    /// 侧边详情面板统一的外观: 玻璃底 + 背板填充 + 边界描边 + 圆角裁剪
    func sidePanelChrome(cornerRadius: CGFloat) -> some View {
        modifier(SidePanelChrome(cornerRadius: cornerRadius))
    }
}

private struct SidePanelChrome: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .liquidGlassSurface(cornerRadius: cornerRadius, isOuterSurface: true)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backingFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(boundaryColor, lineWidth: 0.8)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var backingFill: Color {
        colorScheme == .dark
            ? CodexDarkPalette.background
            : Color(nsColor: NSColor.windowBackgroundColor).opacity(0.86)
    }

    private var boundaryColor: Color {
        colorScheme == .dark
            ? Color.clear
            : Color.black.opacity(0.14)
    }
}

/// 分区之间的细分隔线, 以银灰和冷白高光衬托玻璃背景
struct LiquidGlassDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isVisible = false

    var body: some View {
        Group {
            if colorScheme == .dark {
                Rectangle().fill(CodexDarkPalette.separator)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isVisible)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate * .pi / 4
                    line(offset: sin(phase) * 0.28)
                }
            }
        }
        .mask {
            LinearGradient(
                stops: [
                    .init(color: Color.clear, location: 0),
                    .init(color: Color.white, location: 0.12),
                    .init(color: Color.white, location: 0.88),
                    .init(color: Color.clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .frame(height: 1)
        .background {
            LiquidGlassDividerVisibility { isVisible = $0 }
        }
    }

    private func line(offset: Double) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(displayP3Hex: 0x8A98AC),
                        Color(displayP3Hex: 0xE4EBF3),
                        Color(displayP3Hex: 0xACB8C9),
                        Color.clear
                    ],
                    startPoint: UnitPoint(x: offset, y: 0.5),
                    endPoint: UnitPoint(x: 1 + offset, y: 0.5)
                )
            )
            .opacity(0.30)
    }
}

/// 面板可能保留隐藏的 hosting view, 按窗口可见性暂停时间线, 不依赖动画偏好开关
private struct LiquidGlassDividerVisibility: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context _: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context _: Context) {
        view.onChange = onChange
        view.updateVisibility()
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var reportedVisibility = false
        private var visibilityObservation: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibilityObservation = nil
            if let window {
                visibilityObservation = NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
                    .sink { [weak self] _ in
                        MainActor.assumeIsolated { self?.updateVisibility() }
                    }
            }
            updateVisibility()
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateVisibility()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateVisibility()
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        func updateVisibility() {
            let visible = window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
            guard visible != reportedVisibility else { return }
            reportedVisibility = visible
            Task { @MainActor [weak self] in self?.onChange?(visible) }
        }
    }
}

// MARK: - 表面绘制

/// 深色使用低对比表面, 浅色保留玻璃高光和纹理
private struct LiquidGlassSurface: View {
    let cornerRadii: RectangleCornerRadii
    let isOuterSurface: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)

        if colorScheme == .dark {
            shape
                .fill(isOuterSurface ? CodexDarkPalette.background : CodexDarkPalette.surface)
                .overlay {
                    if isOuterSurface {
                        shape.strokeBorder(CodexDarkPalette.outline, lineWidth: 0.5)
                    }
                }
                .shadow(color: Color.black.opacity(isOuterSurface ? 0.24 : 0.10), radius: isOuterSurface ? 12 : 4, y: isOuterSurface ? 6 : 1)
        } else {
            ZStack {
                shape
                    .fill(baseFill)

                shape
                    .fill(highlightFill)
                    .blendMode(.plusLighter)

                LiquidGlassFrostedTexture(isOuterSurface: isOuterSurface)
                    .clipShape(shape)

                shape
                    .strokeBorder(
                        borderColor,
                        lineWidth: isOuterSurface ? 1.0 : 0.8
                    )

                shape
                    .strokeBorder(rimHighlightColor, lineWidth: rimLineWidth)
                    .shadow(
                        color: rimLightShadowColor,
                        radius: isOuterSurface ? 0.5 : 1.0,
                        x: 0,
                        y: isOuterSurface ? -0.2 : -0.4
                    )
                    .shadow(
                        color: rimDarkShadowColor,
                        radius: isOuterSurface ? 0.8 : 1.3,
                        x: 0,
                        y: isOuterSurface ? 0.6 : 1.0
                    )

                LiquidGlassSpecular(cornerRadii: cornerRadii)
                    .opacity(isOuterSurface ? 0.82 : 0.64)
            }
            .shadow(
                color: raisedHighlightShadowColor,
                radius: isOuterSurface ? 0 : 2,
                x: isOuterSurface ? 0 : -1,
                y: isOuterSurface ? 0 : -1
            )
            .shadow(
                color: ambientShadowColor,
                radius: isOuterSurface ? 18 : 12,
                x: 0,
                y: isOuterSurface ? 10 : 7
            )
            .shadow(
                color: contactShadowColor,
                radius: isOuterSurface ? 0 : 3,
                x: 0,
                y: isOuterSurface ? 0 : 2
            )
        }
    }

    private var baseFill: Color {
        baseColor.opacity(0.6)
    }

    private var highlightFill: Color {
        Color.white.opacity(isOuterSurface ? 0.12 : 0.14)
    }

    private var borderColor: Color {
        Color.white.opacity(isOuterSurface ? 0.34 : 0.28)
    }

    private var rimHighlightColor: Color {
        Color.white.opacity(isOuterSurface ? 0.36 : 0.50)
    }

    private var rimLightShadowColor: Color {
        Color.white.opacity(0.20)
    }

    private var rimDarkShadowColor: Color {
        Color.black.opacity(0.12)
    }

    private var rimLineWidth: CGFloat {
        isOuterSurface ? 0.8 : 1.1
    }

    private var baseColor: Color {
        isOuterSurface
            ? Color(displayP3Hex: 0xF8FBFF)
            : Color.white
    }

    private var raisedHighlightShadowColor: Color {
        Color.white.opacity(0.46)
    }

    private var ambientShadowColor: Color {
        if isOuterSurface {
            return Color.black.opacity(0.16)
        }

        return Color.black.opacity(0.18)
    }

    private var contactShadowColor: Color {
        Color.black.opacity(0.08)
    }
}

/// 稳定伪随机纹理, 不依赖运行时随机数以避免重绘闪烁
private struct LiquidGlassFrostedTexture: View {
    let isOuterSurface: Bool

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let step: CGFloat = isOuterSurface ? 4 : 3
            let columns = max(Int((size.width / step).rounded(.up)), 0)
            let rows = max(Int((size.height / step).rounded(.up)), 0)
            let baseOpacity = 0.045
            let outerScale = isOuterSurface ? 0.75 : 1.0
            let shadowFactor = 0.16

            // 按强度分桶合并同色点, 把上万次单点 fill 压缩成每桶一次路径填充
            // 桶内取中值不透明度, 与逐点绘制的偏差不超过 baseOpacity / (2 * bucketCount)
            var highlightPaths = [Path](repeating: Path(), count: Self.bucketCount)
            var shadowPaths = [Path](repeating: Path(), count: Self.bucketCount)

            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let sample = Self.noise(column: column, row: row)
                    let isHighlight = sample >= 0.5
                    let strength = isHighlight ? (sample - 0.5) * 2 : (0.5 - sample) * 2
                    let bucket = min(Int(strength * Double(Self.bucketCount)), Self.bucketCount - 1)
                    let rect = CGRect(
                        x: CGFloat(column) * step,
                        y: CGFloat(row) * step,
                        width: 1,
                        height: 1
                    )

                    if isHighlight {
                        highlightPaths[bucket].addRect(rect)
                    } else {
                        shadowPaths[bucket].addRect(rect)
                    }
                }
            }

            for bucket in 0 ..< Self.bucketCount {
                let strength = (Double(bucket) + 0.5) / Double(Self.bucketCount)
                let opacity = baseOpacity * strength * outerScale
                context.fill(highlightPaths[bucket], with: .color(Color.white.opacity(opacity)))
                context.fill(shadowPaths[bucket], with: .color(Color.black.opacity(opacity * shadowFactor)))
            }
        }
        .allowsHitTesting(false)
    }

    private static let bucketCount = 16

    private nonisolated static func noise(column: Int, row: Int) -> Double {
        var value = UInt64(column) &* 0x9E3779B185EBCA87
        value ^= UInt64(row) &* 0xC2B2AE3D27D4EB4F
        value ^= value >> 33
        value &*= 0xFF51AFD7ED558CCD
        value ^= value >> 33
        value &*= 0xC4CEB9FE1A85EC53
        value ^= value >> 33
        return Double(value & 0xFFFF) / Double(0xFFFF)
    }
}

/// 小徽章背景, 用于计划名和当前运行状态
private struct LiquidGlassBadge<S: InsettableShape>: View {
    let tint: Color
    let shape: S
    let showsTopHighlight: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            shape
                .fill(CodexDarkPalette.raisedSurface)
                .overlay {
                    shape.fill(tint.opacity(0.12))
                }
        } else {
            shape
                .fill(fillColor)
                .overlay {
                    LiquidGlassFrostedTexture(isOuterSurface: false)
                        .clipShape(shape)
                        .opacity(0.55)
                }
                .overlay {
                    shape
                        .strokeBorder(borderColor, lineWidth: 0.8)
                }
                .overlay {
                    shape
                        .strokeBorder(innerRimColor, lineWidth: 0.45)
                        .padding(0.8)
                }
                .overlay(alignment: .top) {
                    if showsTopHighlight {
                        Capsule(style: .continuous)
                            .fill(topHighlightColor)
                            .frame(height: 1)
                            .padding(.horizontal, 7)
                            .padding(.top, 1.5)
                    }
                }
        }
    }

    private var fillColor: Color {
        Color(displayP3Hex: 0xF1F5F9)
    }

    private var borderColor: Color {
        tint.opacity(0.26)
    }

    private var innerRimColor: Color {
        Color.white.opacity(0.42)
    }

    private var topHighlightColor: Color {
        Color.white.opacity(0.30)
    }
}

/// 面板边缘的高光描边
private struct LiquidGlassSpecular: View {
    let cornerRadii: RectangleCornerRadii

    var body: some View {
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
            .strokeBorder(
                AngularGradient(
                    colors: [
                        Color.white.opacity(0.52),
                        Color.white.opacity(0.04),
                        Color.white.opacity(0.18),
                        Color.clear,
                        Color.white.opacity(0.42)
                    ],
                    center: .center,
                    startAngle: .degrees(215),
                    endAngle: .degrees(575)
                ),
                lineWidth: 1
            )
            .blur(radius: 0.15)
    }
}
