import SwiftUI

nonisolated struct MenuSectionVisibilityKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// 将插值高度反馈给宿主尺寸测量, 内容始终从顶部布局
private struct MenuContentHeight: Animatable, ViewModifier {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: height < 0 ? nil : height, alignment: .topLeading)
    }
}

/// 高度反馈限制在尺寸修饰器内, 避免活动卡片逐帧伸缩时重算整个菜单
struct MenuContentSizing: ViewModifier {
    let loadState: CodexLoadState
    @State private var contentHeight: CGFloat = -1
    @State private var animatesContentHeight = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: ContentGeometry.self) { geometry in
                ContentGeometry(height: geometry.size.height, loadState: loadState)
            } action: { oldValue, newValue in
                // 活动区域自行逐帧改变高度, 这里只对账户加载状态切换插值, 避免叠加动画
                animatesContentHeight = contentHeight >= 0 && oldValue.loadState != newValue.loadState
                contentHeight = newValue.height
            }
            .modifier(MenuContentHeight(height: contentHeight))
            .animation(animatesContentHeight ? .codexStatus : nil, value: contentHeight)
    }

    private nonisolated struct ContentGeometry: Equatable {
        let height: CGFloat
        let loadState: CodexLoadState
    }
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

/// 菜单宿主统一测量内容高度, 并在窗口尺寸尚未收敛时保持顶部对齐
struct MenuPanelLayout<Content: View>: View {
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder let content: () -> Content

    var body: some View {
        MenuPanelSizingLayout { content() }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                onHeightChange(height)
            }
            // 测量发生在填满宿主之前, 避免将旧窗口高度当成内容高度而无法收起
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// 宿主窗口和内容共用整点高度, 取整留下的空间放在底部
private struct MenuPanelSizingLayout: Layout {
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
