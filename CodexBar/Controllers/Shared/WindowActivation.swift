import AppKit

@MainActor
extension NSWindow {
    /// LSUIElement 应用没有 Dock 图标, 需按此顺序激活才能将窗口置于最前
    func bringToFrontActivatingApp() {
        orderFrontRegardless()
        NSRunningApplication.current.activate(options: [])
        makeKeyAndOrderFront(nil)
    }
}
