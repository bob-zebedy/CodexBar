import SwiftUI

struct ActivityCardWaitingEdges: View {
    let left: Bool
    let right: Bool
    let animates: Bool
    @State private var startedAt = Date()

    var body: some View {
        // 两侧共用呼吸相位, 改变方向时只交接透明度
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animates || (!left && !right))) { timeline in
            let elapsed = animates ? timeline.date.timeIntervalSince(startedAt) : 0
            HStack(spacing: 0) {
                ActivityCardWaitingEdge(isLeading: true, elapsed: elapsed)
                    .frame(width: 10)
                    .opacity(left ? 1 : 0)
                Spacer(minLength: 0)
                ActivityCardWaitingEdge(isLeading: false, elapsed: elapsed)
                    .frame(width: 10)
                    .opacity(right ? 1 : 0)
            }
        }
        .animation(animates ? .easeInOut(duration: 0.25) : nil, value: left)
        .animation(animates ? .easeInOut(duration: 0.25) : nil, value: right)
    }
}

private struct ActivityCardWaitingEdge: View {
    let isLeading: Bool
    let elapsed: TimeInterval
    @Environment(\.colorScheme) private var colorScheme

    /// 按 Apple HIG 的 Pulse 示例视频近似明暗曲线, 不包含额外停顿
    private static let breathCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.31, y: 0),
        endControlPoint: UnitPoint(x: 0.69, y: 1)
    )

    private var amber: Color {
        colorScheme == .dark
            ? Color(red: 1, green: 0.76, blue: 0.40)
            : Color(red: 0.95, green: 0.58, blue: 0.18)
    }

    private var breathIntensity: Double {
        // 从峰值开始, 关闭动画时也保持完整亮度
        let phase = max(0, elapsed).truncatingRemainder(dividingBy: 2)
        return Self.breathCurve.value(at: abs(phase - 1))
    }

    var body: some View {
        Canvas { context, size in
            var mist = context
            mist.opacity = (colorScheme == .dark ? 0.96 : 0.72) * breathIntensity
            mist.addFilter(.blur(radius: 2))
            // 雾光延伸到卡片外再裁切, 让最亮处贴住侧边而不在内部形成亮线
            mist.fill(
                Path(CGRect(x: isLeading ? -6 : 0, y: -6, width: size.width + 6, height: size.height + 12)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: amber, location: 0),
                        .init(color: amber.opacity(0.65), location: 0.20),
                        .init(color: amber.opacity(0.25), location: 0.50),
                        .init(color: amber.opacity(0.05), location: 0.78),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: CGPoint(x: isLeading ? 0 : size.width, y: 0),
                    endPoint: CGPoint(x: isLeading ? size.width : 0, y: 0)
                )
            )
        }
        // 遮罩将模糊限制在侧边留白内, 避免扩散到图标和文字区域
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.5),
                    .init(color: .clear, location: 1)
                ],
                startPoint: isLeading ? .leading : .trailing,
                endPoint: isLeading ? .trailing : .leading
            )
        }
    }
}
