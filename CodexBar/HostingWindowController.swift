import AppKit

/// 承载 SwiftUI 内容的单窗口控制器基类, 统一懒创建、居中与置顶逻辑
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
            // 重新打开时跟随到当前桌面, 避免把用户切回窗口旧桌面
            target.collectionBehavior.insert(.moveToActiveSpace)
            window = target
        }
        
        if !target.isVisible {
            prepareForDisplay(target)
        }
        
        bringToFront(target)
    }
    
    func makeWindow() -> NSWindow {
        fatalError("subclass must override makeWindow()")
    }
    
    func prepareForDisplay(_ window: NSWindow) {
        center(window)
    }
    
    func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        
        NSApplication.shared.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
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
