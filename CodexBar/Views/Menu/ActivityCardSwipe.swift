import SwiftUI

/// 拖动和收尾共用位移, 新手势可以在收尾途中接管当前画面
nonisolated struct ActivityCardSwipe: Equatable {
    private(set) var isDragging = false
    private(set) var settlement: Settlement?
    private var dragOffset: CGFloat = 0

    var isActive: Bool {
        isDragging || settlement != nil
    }

    func offset(at now: Date) -> CGFloat {
        guard let settlement else { return dragOffset }
        let progress = min(1, max(0, now.timeIntervalSince(settlement.startedAt) / settlement.duration))
        let remaining = 1 - progress
        return settlement.target + (settlement.origin - settlement.target) * remaining * remaining * remaining
    }

    /// 已确认的翻页在下一次拖动开始时换基准, 两侧内容的屏幕位置保持不变
    mutating func begin(width: CGFloat, now: Date) -> Int {
        let step = settlement?.step ?? 0
        dragOffset = offset(at: now) + CGFloat(step) * width
        settlement = nil
        isDragging = true
        return step
    }

    mutating func move(by delta: CGFloat, width: CGFloat) {
        guard isDragging, delta.isFinite, width.isFinite, width > 0 else { return }
        dragOffset = min(width, max(-width, dragOffset + delta))
    }

    mutating func end(velocity: CGFloat, width: CGFloat, cancelled: Bool, now: Date) {
        guard isDragging, width.isFinite, width > 0 else { return }
        let velocity = velocity.isFinite ? min(width * 5, max(-width * 5, velocity)) : 0
        let projected = dragOffset + velocity * 0.15
        let commits = !cancelled && abs(dragOffset) >= min(8, width * 0.03)
            && projected * dragOffset > 0 && abs(projected) >= width * 0.25
        let step = commits ? (dragOffset < 0 ? 1 : -1) : 0
        let target = -CGFloat(step) * width
        settlement = Settlement(
            origin: dragOffset, target: target, step: step, startedAt: now,
            duration: max(0.08, min(0.24, Double(abs(target - dragOffset) / width) * 0.3))
        )
        isDragging = false
    }

    struct Settlement: Hashable {
        let origin: CGFloat
        let target: CGFloat
        let step: Int
        let startedAt: Date
        let duration: TimeInterval
    }
}

/// 横向位移和容器高度共用进度, 拖动结束后沿用同一高度计算方式完成收尾
struct ActivityCardSwipePages<Content: View>: View {
    let swipe: ActivityCardSwipe
    let width: CGFloat
    @ViewBuilder let content: (Int) -> Content

    var body: some View {
        TimelineView(.animation(paused: swipe.settlement == nil)) { timeline in
            ActivityCardSwipeLayout(width: width, offset: swipe.offset(at: timeline.date)) {
                content(-1)
                content(0)
                content(1)
            }
        }
        .transaction { $0.animation = nil }
    }
}

private struct ActivityCardSwipeLayout: Layout {
    let width: CGFloat
    let offset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let pageWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? width
        guard subviews.count == 3, pageWidth > 0 else { return .zero }
        let proposal = ProposedViewSize(width: pageWidth, height: nil)
        let currentHeight = subviews[1].sizeThatFits(proposal).height
        let adjacentHeight = subviews[offset < 0 ? 2 : 0].sizeThatFits(proposal).height
        let progress = min(1, abs(offset) / pageWidth)
        return CGSize(width: pageWidth, height: currentHeight + (adjacentHeight - currentHeight) * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (index, subview) in subviews.enumerated() {
            // 每页按自然高度排版, 容器只改变可见范围, 避免文字随高度压缩或居中移动
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index - 1) * bounds.width + offset, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
        }
    }
}
