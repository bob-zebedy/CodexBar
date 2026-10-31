import SwiftUI

nonisolated struct MenuSectionVisibilityKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// 区域高度和相邻间距使用同一展开进度, 移除零高度区域时总高度保持不变
struct MenuSectionLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        var size = CGSize.zero
        var precedingVisibility: CGFloat = 0
        for subview in subviews {
            let visibility = subview[MenuSectionVisibilityKey.self]
            let childSize = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            size.width = max(size.width, childSize.width)
            size.height += spacing * min(precedingVisibility, visibility) + childSize.height
            precedingVisibility = max(precedingVisibility, visibility)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        var precedingVisibility: CGFloat = 0
        for subview in subviews {
            let visibility = subview[MenuSectionVisibilityKey.self]
            let childProposal = ProposedViewSize(width: bounds.width, height: nil)
            y += spacing * min(precedingVisibility, visibility)
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: childProposal)
            y += subview.sizeThatFits(childProposal).height
            precedingVisibility = max(precedingVisibility, visibility)
        }
    }
}

/// 宿主窗口和内容共用整点高度, 保持顶部位置稳定
struct MenuPanelLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // NSPopover 的窗口按整点取整, 半点高度会使宿主内容在窗口内上下偏移
        return CGSize(width: size.width, height: size.height.rounded(.up))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        // 取整留下的空间放在底部, 不由默认居中对齐分配到顶部
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
