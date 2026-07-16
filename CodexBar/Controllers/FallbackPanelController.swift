import AppKit
import SwiftUI

/// 全局快捷键无法信任 status item 锚点时使用的无箭头菜单面板
@MainActor
final class FallbackPanelController {
    private let makeContentController: () -> NSHostingController<AnyView>
    private var panel: KeyableBorderlessPanel?

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
        panel?.orderOut(nil)
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
