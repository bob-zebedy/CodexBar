import AppKit

/// 可临时禁止成为 key window, 让菜单面板关闭动画期间不被辅助窗口抢焦点
@MainActor
final class AuxiliaryHostingWindow: NSWindow {
    var allowsKeyFocus = true

    override var canBecomeKey: Bool {
        allowsKeyFocus
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// 承载 SwiftUI 内容的单窗口控制器基类, 统一懒创建, 居中与窗口管理逻辑
@MainActor
class HostingWindowController {
    let screenProvider: () -> NSScreen?
    private(set) var window: NSWindow?

    init(screenProvider: @escaping () -> NSScreen?) {
        self.screenProvider = screenProvider
    }

    func open() {
        let target: NSWindow
        if let window {
            target = window
        } else {
            target = makeWindow()
            target.isReleasedWhenClosed = false
            window = target
        }

        applyWindowPresentationPolicy(target)

        if !target.isVisible {
            prepareForDisplay(target)
        }

        bringToFront(target)
    }

    func makeWindow() -> NSWindow {
        fatalError("subclass must override makeWindow()")
    }

    func applyWindowPresentationPolicy(_ window: NSWindow) {
        window.level = .normal
        // 重新打开时跟随到当前桌面, 避免把用户切回窗口旧桌面

        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    func prepareForDisplay(_ window: NSWindow) {
        center(window)
    }

    func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        (window as? AuxiliaryHostingWindow)?.allowsKeyFocus = true
        window.bringToFrontActivatingApp()
    }

    func setAllowsKeyFocus(_ allowsKeyFocus: Bool) {
        (window as? AuxiliaryHostingWindow)?.allowsKeyFocus = allowsKeyFocus
    }

    func center(_ window: NSWindow) {
        guard let screen = screenProvider() ?? window.screen ?? NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let windowFrame = window.frame
        window.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - windowFrame.width / 2,
                y: visibleFrame.midY - windowFrame.height / 2
            )
        )
    }
}
