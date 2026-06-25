import SwiftUI

/// CodexBar 统一的短状态动画
extension Animation {
    static let codexStatus = Animation.easeInOut(duration: 0.20)
}

/// 共享颜色和十六进制便捷初始化
extension Color {
    // 某些自定义 View 需要具体 Color
    // 不能直接使用 .primary/.secondary 这类 ShapeStyle
    static let codexLabel = Color(nsColor: .labelColor)
    static let codexSecondaryLabel = Color(nsColor: .secondaryLabelColor)

    init(hex: Int) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
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
        background {
            LiquidGlassCapsule(tint: tint)
        }
    }

    /// 数据为缓存回退 (本轮刷新失败) 时弱化显示
    func markStale(_ isStale: Bool) -> some View {
        opacity(isStale ? 0.55 : 1)
    }
}

/// 分区之间的细分隔线, 与玻璃背景保持低对比
struct LiquidGlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.36),
                        .primary.opacity(0.08),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}

/// 自绘玻璃面板, 由底色, 高光, 纹理, 描边和阴影叠加组成
private struct LiquidGlassSurface: View {
    let cornerRadii: RectangleCornerRadii
    let isOuterSurface: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)

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

    private var baseFill: Color {
        baseColor.opacity(0.6)
    }

    private var highlightFill: Color {
        .white.opacity(isOuterSurface ? 0.12 : 0.14)
    }

    private var borderColor: Color {
        .white.opacity(isOuterSurface ? 0.34 : 0.28)
    }

    private var rimHighlightColor: Color {
        .white.opacity(isOuterSurface ? 0.36 : 0.50)
    }

    private var rimLightShadowColor: Color {
        .white.opacity(colorScheme == .dark ? 0.05 : 0.20)
    }

    private var rimDarkShadowColor: Color {
        .black.opacity(colorScheme == .dark ? 0.28 : 0.12)
    }

    private var rimLineWidth: CGFloat {
        isOuterSurface ? 0.8 : 1.1
    }

    private var baseColor: Color {
        if colorScheme == .dark {
            return isOuterSurface
                ? Color(red: 0.07, green: 0.08, blue: 0.095)
                : Color(red: 0.16, green: 0.18, blue: 0.20)
        }

        return isOuterSurface
            ? Color(red: 0.97, green: 0.985, blue: 1.0)
            : Color.white
    }

    private var raisedHighlightShadowColor: Color {
        if colorScheme == .dark {
            return .white.opacity(0.08)
        }

        return .white.opacity(0.46)
    }

    private var ambientShadowColor: Color {
        if isOuterSurface {
            return .black.opacity(0.16)
        }

        return .black.opacity(colorScheme == .dark ? 0.34 : 0.18)
    }

    private var contactShadowColor: Color {
        .black.opacity(colorScheme == .dark ? 0.20 : 0.08)
    }
}

/// 稳定伪随机纹理, 不依赖运行时随机数以避免重绘闪烁
private struct LiquidGlassFrostedTexture: View {
    let isOuterSurface: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let step: CGFloat = isOuterSurface ? 4 : 3
            let columns = max(Int((size.width / step).rounded(.up)), 0)
            let rows = max(Int((size.height / step).rounded(.up)), 0)
            let baseOpacity = colorScheme == .dark ? 0.035 : 0.045
            let outerScale = isOuterSurface ? 0.75 : 1

            for row in 0 ..< rows {
                for column in 0 ..< columns {
                    let sample = Self.noise(column: column, row: row)
                    let isHighlight = sample >= 0.5
                    let strength = isHighlight ? (sample - 0.5) * 2 : (0.5 - sample) * 2
                    let opacity = baseOpacity * strength * outerScale
                    let color = if isHighlight {
                        Color.white.opacity(opacity)
                    } else {
                        Color.black.opacity(opacity * (colorScheme == .dark ? 0.24 : 0.16))
                    }
                    let rect = CGRect(
                        x: CGFloat(column) * step,
                        y: CGFloat(row) * step,
                        width: 1,
                        height: 1
                    )

                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
    }

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
private struct LiquidGlassCapsule: View {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(fillColor)
            .overlay {
                LiquidGlassFrostedTexture(isOuterSurface: false)
                    .clipShape(Capsule(style: .continuous))
                    .opacity(0.55)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.8)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(innerRimColor, lineWidth: 0.45)
                    .padding(0.8)
            }
            .overlay(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(topHighlightColor)
                    .frame(height: 1)
                    .padding(.horizontal, 7)
                    .padding(.top, 1.5)
            }
    }

    private var fillColor: Color {
        colorScheme == .dark
            ? Color(red: 0.18, green: 0.20, blue: 0.22)
            : Color(red: 0.94, green: 0.96, blue: 0.98)
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? tint.opacity(0.34)
            : tint.opacity(0.26)
    }

    private var innerRimColor: Color {
        .white.opacity(colorScheme == .dark ? 0.12 : 0.42)
    }

    private var topHighlightColor: Color {
        .white.opacity(colorScheme == .dark ? 0.10 : 0.30)
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
                        .white.opacity(0.52),
                        .white.opacity(0.04),
                        .white.opacity(0.18),
                        .clear,
                        .white.opacity(0.42)
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
