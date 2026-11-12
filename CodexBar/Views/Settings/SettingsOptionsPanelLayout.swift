import AppKit
import SwiftUI

/// 设置子选项面板共用的间距和控件高度
enum SettingsOptionsPanelMetrics {
    static let minimumWidth: CGFloat = 300
    static let maximumWidth: CGFloat = 380
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let rowSpacing: CGFloat = 5
    static let rowHeight: CGFloat = 22
    /// 通知面板音效子行的高度
    static let secondaryRowHeight: CGFloat = 18
    static let controlSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 12
    static let resizeDuration: TimeInterval = 0.24
    static let contentAnimation = Animation.easeInOut(duration: resizeDuration)

    static func height(rowCount: Int, secondaryRowCount: Int = 0) -> CGFloat {
        verticalPadding * 2
            + rowHeight * CGFloat(rowCount)
            + rowSpacing * CGFloat(max(rowCount - 1, 0))
            + secondaryRowHeight * CGFloat(secondaryRowCount)
    }
}

@MainActor
final class SettingsOptionsPanelSizeObserver {
    let onChange: @MainActor (CGSize) -> Void

    init(onChange: @escaping @MainActor (CGSize) -> Void) {
        self.onChange = onChange
    }
}

extension EnvironmentValues {
    @Entry var settingsOptionsPanelSizeObserver: SettingsOptionsPanelSizeObserver?
}

extension View {
    func settingsOptionsReveal(isExpanded: Bool, height: CGFloat, spacing: CGFloat = 0) -> some View {
        frame(height: height)
            .padding(.top, spacing)
            .frame(height: isExpanded ? height + spacing : 0, alignment: .top)
            .clipped()
            .disabled(!isExpanded)
            .allowsHitTesting(isExpanded)
    }

    func settingsOptionsPanel(height: CGFloat) -> some View {
        modifier(SettingsOptionsPanelSurface(height: height))
    }
}

private struct SettingsOptionsPanelSurface: AnimatableModifier {
    var height: CGFloat
    @Environment(\.settingsOptionsPanelSizeObserver) private var sizeObserver

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        let panelHeight = height.rounded(.up)
        content
            .frame(height: panelHeight, alignment: .top)
            .sidePanelChrome(cornerRadius: SettingsOptionsPanelMetrics.cornerRadius)
            .background {
                GeometryReader { geometry in
                    SettingsOptionsPanelSizeReporter(
                        size: CGSize(width: geometry.size.width, height: panelHeight),
                        observer: sizeObserver
                    )
                }
            }
            // 窗口高度向上取整, 取整余量和布局尚未同步的高度差都留在底部
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

private struct SettingsOptionsPanelSizeReporter: NSViewRepresentable {
    let size: CGSize
    let observer: SettingsOptionsPanelSizeObserver?

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_: NSView, context _: Context) {
        // 使用同一帧的可见高度调整窗口, 避免叠加 AppKit 尺寸动画
        observer?.onChange(size)
    }
}
