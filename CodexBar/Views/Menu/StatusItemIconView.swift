import AppKit
import Combine
import SwiftUI

final class StatusItemIconPresentation: ObservableObject {
    struct State: Equatable {
        var symbolName = "person.fill"
        var remainingPercent = 0
        var showsQuota = false
        var isStale = false
    }

    @Published private(set) var state = State()

    func update(symbolName: String, percent: Int?, isStale: Bool, animated: Bool) {
        let next = State(
            symbolName: symbolName,
            remainingPercent: percent.map { min(max($0, 0), 100) } ?? state.remainingPercent,
            showsQuota: percent != nil,
            isStale: percent == nil ? state.isStale : isStale
        )
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

    static let size = NSSize(width: 26, height: 22)
    private static var symbolImages: [String: [CGFloat: CGImage]] = [:]

    var body: some View {
        let state = presentation.state
        ZStack {
            ZStack {
                StatusItemQuotaArc()
                    .stroke(
                        Color(nsColor: .tertiaryLabelColor).opacity(0.34),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .opacity(state.showsQuota ? 1 : 0)
                StatusItemQuotaArc(percent: state.showsQuota ? CGFloat(state.remainingPercent) : 0)
                    .stroke(
                        QuotaPalette.color(for: state.remainingPercent),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
            }
            .opacity(state.isStale ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.3), value: state.showsQuota)

            ZStack {
                symbolImage(named: state.symbolName)
                    .id(state.symbolName)
                    .transition(.opacity.combined(with: .scale(
                        scale: 0.75,
                        anchor: UnitPoint(x: 0.5, y: 18.0 / 22.0)
                    )))
            }
            .animation(.easeInOut(duration: 0.2), value: state.symbolName)
            .scaleEffect(
                state.showsQuota ? 1 : 16.0 / 14.0,
                anchor: UnitPoint(x: 0.5, y: 18.0 / 22.0)
            )
            .offset(y: state.showsQuota ? 0 : -1)
            .opacity(state.showsQuota && state.isStale ? 0.75 : 1)
        }
        .animation(.easeInOut(duration: 0.2), value: state.showsQuota)
        .frame(width: Self.size.width, height: Self.size.height)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func symbolImage(named name: String) -> some View {
        let scale = ceil(max(displayScale, 1) * 16 / 14)
        if let image = Self.rasterizedSymbol(named: name, displayScale: displayScale, scale: scale) {
            Image(decorative: image, scale: scale)
                .renderingMode(.template)
                .foregroundStyle(.primary)
        } else {
            Self.symbolContent(named: name)
                .foregroundStyle(.primary)
        }
    }

    private static func rasterizedSymbol(named name: String, displayScale: CGFloat, scale: CGFloat) -> CGImage? {
        if let image = symbolImages[name]?[displayScale] {
            return image
        }

        // 只在符号或屏幕倍率首次出现时栅格化, 缩放过程复用普通图片
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
        // 基线固定人物主体, 徽章的下伸部分不参与居中计算
        Color.clear
            .frame(width: size.width, height: size.height)
            .alignmentGuide(.firstTextBaseline) { _ in 18 }
            .overlay(alignment: .centerFirstTextBaseline) {
                Image(systemName: name)
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(.monochrome)
            }
    }
}

private nonisolated struct StatusItemQuotaArc: Shape {
    var percent: CGFloat = 100

    var animatableData: CGFloat {
        get { percent }
        set { percent = newValue }
    }

    func path(in _: CGRect) -> Path {
        guard percent > 0 else { return Path() }
        let radius: CGFloat = 11
        let extraAngle = asin(CGFloat(5) / radius) * 180 / .pi
        let startAngle = 180 + extraAngle
        let endAngle = startAngle - (180 + 2 * extraAngle) * min(percent, 100) / 100
        var path = Path()
        path.addArc(
            center: CGPoint(x: 13, y: 14),
            radius: radius,
            startAngle: .degrees(-Double(startAngle)),
            endAngle: .degrees(-Double(endAngle)),
            clockwise: false
        )
        return path
    }
}
