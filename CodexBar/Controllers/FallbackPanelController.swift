import AppKit
import SwiftUI

/// 全局快捷键无法通过 status item 锚点可靠定位时使用的无箭头菜单面板
@MainActor
final class FallbackPanelController {
    private let makeContentController: () -> NSHostingController<AnyView>
    private var panel: KeyableBorderlessPanel?
    private var resizeTask: Task<Void, Never>?

    init(makeContentController: @escaping () -> NSHostingController<AnyView>) {
        self.makeContentController = makeContentController
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var window: NSWindow? {
        panel
    }

    var contentView: NSView? {
        panel?.contentViewController?.view
    }

    func prepareForDisplay(on screen: NSScreen?) {
        cancelPendingResize()
        let panel = makePanelIfNeeded()
        let contentSize = contentSize(for: panel)
        panel.setFrame(frame(for: contentSize, on: screen), display: false)
    }

    func show() {
        guard let panel else {
            return
        }

        panel.bringToFrontActivatingApp()
    }

    func orderOut() {
        cancelPendingResize()
        panel?.orderOut(nil)
        AppearanceTransition.dismissSnapshots(in: panel)
    }

    func resizeIfVisible(contentHeight: CGFloat) {
        guard let panel, panel.isVisible,
              contentHeight.isFinite, contentHeight > 0 else { return }
        cancelPendingResize()
        guard panel.frame.height != contentHeight else { return }
        resizeTask = Task { @MainActor [weak self] in
            // 几何回调可能仍在 NSHostingView.layout 中, 等本轮布局退出后再调整窗口
            await Task.yield()
            guard let self, !Task.isCancelled, let panel = self.panel, panel.isVisible else { return }
            resizeTask = nil
            var frame = panel.frame
            frame.origin.y = frame.maxY - contentHeight
            frame.size.height = contentHeight
            // 高度由 SwiftUI 逐帧插值, 窗口直接跟随, 避免叠加动画
            panel.setFrame(frame, display: true)
        }
    }

    private func cancelPendingResize() {
        resizeTask?.cancel()
        resizeTask = nil
    }

    private func makePanelIfNeeded() -> KeyableBorderlessPanel {
        if let panel {
            return panel
        }

        let panel = KeyableBorderlessPanel(
            contentRect: NSRect(origin: .zero, size: Metrics.fallbackSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = makeContentController()
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        self.panel = panel
        return panel
    }

    private func contentSize(for panel: NSPanel) -> NSSize {
        guard let fittingSize = panel.contentViewController?.view.validFittingSize else {
            return Metrics.fallbackSize
        }

        return NSSize(
            width: CodexStatusMenuView.menuWidth,
            height: fittingSize.height
        )
    }

    private func frame(for panelSize: NSSize, on preferredScreen: NSScreen?) -> NSRect {
        guard let screen = preferredScreen ?? NSScreen.containingMouse() ?? NSScreen.main else {
            return NSRect(origin: .zero, size: panelSize)
        }

        let visibleFrame = screen.visibleFrame
        return NSRect(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - Metrics.topInset,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private enum Metrics {
        static let fallbackSize = NSSize(
            width: CodexStatusMenuView.menuWidth,
            height: 420
        )
        static let topInset: CGFloat = 8
    }
}
