import SwiftUI

/// 仅在菜单面板可见时每秒刷新, 隐藏时保持静态圆环
struct AutoRefreshCountdownTimeline: View {
    let startedAt: Date
    let interval: TimeInterval
    let isActive: Bool
    let color: Color

    var body: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                circle(now: timeline.date)
            }
        } else {
            circle(now: Date())
        }
    }

    private func circle(now: Date) -> AutoRefreshCountdownCircle {
        AutoRefreshCountdownCircle(
            startedAt: startedAt,
            interval: interval,
            now: now,
            isActive: isActive,
            color: color
        )
    }
}

private struct AutoRefreshCountdownCircle: View {
    let startedAt: Date
    let interval: TimeInterval
    let now: Date
    let isActive: Bool
    let color: Color

    private var progress: Double {
        guard interval > 0 else {
            return 0
        }

        let elapsed = max(0, now.timeIntervalSince(startedAt))
        return max(0, 1 - elapsed / interval)
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.15), lineWidth: Metrics.lineWidth)

            Circle()
                .inset(by: Metrics.lineWidth / 2)
                .trim(from: 1 - progress, to: 1)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: Metrics.lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: MenuMetrics.statusIconSize, height: MenuMetrics.statusIconSize)
        // 只让刷新起点变化触发动画, 避免每秒 tick 被补间
        .animation(isActive ? .linear(duration: Metrics.resetAnimationDuration) : nil, value: startedAt)
    }

    private enum Metrics {
        static let lineWidth: CGFloat = 1.4
        static let resetAnimationDuration: TimeInterval = 0.50
    }
}
