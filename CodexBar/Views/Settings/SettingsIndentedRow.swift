import SwiftUI

struct SettingsRowWithCaption<Value: Equatable, Row: View, Caption: View>: View {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    private let value: Value?
    private let row: Row
    private let caption: (Value, Bool) -> Caption
    @State private var retainedValue: Value?
    @State private var collapseID: UUID?

    private var isExpanded: Bool {
        retainedValue != nil && collapseID == nil
    }

    init(_ value: Value?, @ViewBuilder row: () -> Row, @ViewBuilder caption: @escaping (Value, Bool) -> Caption) {
        self.value = value
        self.row = row()
        self.caption = caption
        _retainedValue = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
                .frame(minHeight: SettingsRowMetrics.optionsButtonSize)
            SettingsDrawerLayout(progress: isExpanded ? 1 : 0) {
                if let displayedValue = value ?? retainedValue {
                    caption(displayedValue, value != nil)
                        .padding(.top, 4)
                        .transition(.identity)
                }
            }
            .clipped()
            .allowsHitTesting(value != nil)
        }
        .onChange(of: value) { _, next in
            let animation = allowsAnimations ? SettingsOptionsPanelMetrics.contentAnimation : nil
            if let next {
                withAnimation(animation) {
                    retainedValue = next
                    collapseID = nil
                }
            } else {
                // 收起时保留旧提示来测量高度, 过期的动画回调不能清掉新提示
                let id = UUID()
                withAnimation(animation, completionCriteria: .removed) {
                    collapseID = id
                } completion: {
                    guard collapseID == id else { return }
                    retainedValue = nil
                    collapseID = nil
                }
            }
        }
    }
}

/// 按内容的自然高度和展开进度逐帧计算可见高度, 让设置窗口随内容调整大小
struct SettingsDrawerLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let details = subviews.first else { return .zero }
        let size = details.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

/// 设置页中与主行标题对齐的缩进辅助行
struct SettingsIndentedRow<Content: View>: View {
    var iconWidth: CGFloat = SettingsRowMetrics.iconWidth
    var spacing: CGFloat = SettingsRowMetrics.spacing
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: spacing) {
            Color.clear
                .frame(width: iconWidth)

            content()
        }
    }
}

struct SettingsCaptionMessageRow: View {
    let message: String
    var color = Color.red

    var body: some View {
        SettingsIndentedRow {
            Text(message)
                .font(SettingsRowMetrics.captionFont)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
