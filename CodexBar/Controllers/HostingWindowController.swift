import AppKit

/// 可临时忽略 key window 请求, 让菜单面板关闭动画期间不被辅助窗口抢焦点
@MainActor
final class AuxiliaryHostingWindow: NSWindow {
    var allowsKeyFocus = true
    /// 设置窗口与可获得焦点的子面板共享撤销栈, 避免焦点切换后 Command-Z 失效
    var sharedUndoManager: UndoManager?

    override var undoManager: UndoManager? {
        sharedUndoManager ?? super.undoManager
    }

    @IBAction func undo(_: Any?) {
        undoManager?.undo()
    }

    @IBAction func redo(_: Any?) {
        undoManager?.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            undoManager?.canUndo == true
        case #selector(redo(_:)):
            undoManager?.canRedo == true
        default:
            super.validateUserInterfaceItem(item)
        }
    }

    override func makeKey() {
        guard allowsKeyFocus else {
            return
        }

        super.makeKey()
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
