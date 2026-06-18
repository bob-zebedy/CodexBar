import SwiftUI

extension Animation {
    static let codexStatus = Animation.easeInOut(duration: 0.18)
}

extension Color {
    // 某些自定义 View 需要具体 Color, 不能直接使用 .primary/.secondary 这类 ShapeStyle
    static let codexLabel = Color(nsColor: .labelColor)
    static let codexSecondaryLabel = Color(nsColor: .secondaryLabelColor)
}

extension View {
    func liquidGlassSurface(
        cornerRadius: CGFloat,
        tint: Color,
        isOuterSurface: Bool = false
    ) -> some View {
        liquidGlassSurface(
            cornerRadii: RectangleCornerRadii(
                topLeading: cornerRadius,
                bottomLeading: cornerRadius,
                bottomTrailing: cornerRadius,
                topTrailing: cornerRadius
            ),
            tint: tint,
            isOuterSurface: isOuterSurface
        )
    }
    
    func liquidGlassSurface(
        cornerRadii: RectangleCornerRadii,
        tint: Color,
        isOuterSurface: Bool = false
    ) -> some View {
        background {
            LiquidGlassSurface(
                cornerRadii: cornerRadii,
                tint: tint,
                isOuterSurface: isOuterSurface
            )
        }
    }
    
    func liquidGlassCapsule(tint: Color) -> some View {
        background {
            LiquidGlassCapsule(tint: tint)
        }
    }
    
    // 数据为缓存回退(本轮刷新失败)时弱化显示
    func markStale(_ isStale: Bool) -> some View {
        opacity(isStale ? 0.55 : 1)
    }
}

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

private struct LiquidGlassSurface: View {
    let cornerRadii: RectangleCornerRadii
    let tint: Color
    let isOuterSurface: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
        
        ZStack {
            shape
                .fill(baseFill)
            
            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isOuterSurface ? 0.18 : 0.24),
                            tint.opacity(isOuterSurface ? 0.08 : 0.12),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)
            
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isOuterSurface ? 0.44 : 0.36),
                            tint.opacity(0.24),
                            .primary.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isOuterSurface ? 1.0 : 0.8
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
    
    private var baseFill: LinearGradient {
        LinearGradient(
            colors: [
                baseColor.opacity(isOuterSurface ? 1 : 0.94),
                baseColor.opacity(isOuterSurface ? 0.88 : 0.78)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

private struct LiquidGlassCapsule: View {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Capsule(style: .continuous)
            .fill(baseFill)
            .overlay {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? 0.18 : 0.36),
                                tint.opacity(colorScheme == .dark ? 0.16 : 0.12),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .blendMode(.plusLighter)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.22 : 0.34), lineWidth: 0.7)
            }
    }
    
    private var baseFill: LinearGradient {
        LinearGradient(
            colors: [
                baseColor.opacity(colorScheme == .dark ? 0.76 : 0.70),
                baseColor.opacity(colorScheme == .dark ? 0.58 : 0.52)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var baseColor: Color {
        colorScheme == .dark
        ? Color(red: 0.16, green: 0.18, blue: 0.20)
        : Color.white
    }
}

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
