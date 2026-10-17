import SwiftUI

nonisolated struct ActivityCardNaturalHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ActivitySection<Content: View>: View {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.mainPanelAnimationsEnabled) private var allowsAnimations
    @State private var retainsContent: Bool
    @State private var naturalHeight: CGFloat = 0
    @State private var height: CGFloat
    @State private var progress: CGFloat
    @State private var transitionGeneration = 0

    private var animation: Animation? {
        allowsAnimations ? .timingCurve(0.4, 0, 0.2, 1, duration: 0.5) : nil
    }

    init(isVisible: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isVisible = isVisible
        self.content = content
        _retainsContent = State(initialValue: isVisible)
        _height = State(initialValue: isVisible ? -1 : 0)
        _progress = State(initialValue: isVisible ? 1 : 0)
    }

    var body: some View {
        Group {
            if retainsContent {
                content()
            }
        }
        .modifier(ActivitySectionReveal(height: height, progress: progress))
        .allowsHitTesting(isVisible)
        .onPreferenceChange(ActivityCardNaturalHeightKey.self) { measuredHeight in
            guard measuredHeight > 0 else { return }
            naturalHeight = measuredHeight
            guard isVisible else { return }
            // 初次打开直接采用自然高度, 后续变化统一从当前可见高度继续
            withAnimation(height < 0 ? nil : animation) {
                height = measuredHeight
                progress = 1
            }
        }
        .onChange(of: isVisible) { _, visible in
            transitionGeneration &+= 1
            let generation = transitionGeneration
            if visible, !retainsContent {
                // 先测量内容, 再同时展开高度和间距, 插入本身不触发父布局动画
                retainsContent = true
                return
            }
            withAnimation(animation, completionCriteria: .removed) {
                height = visible ? naturalHeight : 0
                progress = visible ? 1 : 0
            } completion: {
                if transitionGeneration == generation, !isVisible {
                    retainsContent = false
                }
            }
        }
    }
}

struct ActivitySectionReveal: ViewModifier, Animatable {
    var height: CGFloat
    var progress: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(height, progress) }
        set {
            height = newValue.first
            progress = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let visibility = min(1, max(0, progress))
        content
            // 卡片按可见高度绘制背景, 内容裁剪由卡片内部负责, 外投影不参与裁剪
            .frame(height: height < 0 ? nil : max(0, height), alignment: .topLeading)
            // 连同玻璃背景和投影一起淡出, 避免末尾留下被压扁的亮边
            .opacity(visibility * visibility * (3 - 2 * visibility))
            .layoutValue(key: MenuSectionVisibilityKey.self, value: visibility)
    }
}
