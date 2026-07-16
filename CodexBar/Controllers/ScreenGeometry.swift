import AppKit

/// 屏幕坐标相关的共享几何工具
extension NSScreen {
    /// 鼠标当前所在屏幕
    @MainActor
    static func containingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        }
    }
}

nonisolated extension CGRect {
    /// 各分量有限且宽高为正, 才能作为可信的屏幕坐标参与定位
    var isValidScreenRect: Bool {
        minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
            && width > 0
            && height > 0
    }
}

extension NSWindow {
    /// LSUIElement 应用无 Dock 图标, 把窗口可靠拉到最前依赖这套固定激活序列
    @MainActor
    func bringToFrontActivatingApp() {
        orderFrontRegardless()
        NSRunningApplication.current.activate(options: [])
        makeKeyAndOrderFront(nil)
    }
}

extension NSView {
    /// SwiftUI hosting 视图的 fittingSize 可能给出非有限或非正尺寸, 校验通过才能用于窗口布局
    @MainActor
    var validFittingSize: NSSize? {
        layoutSubtreeIfNeeded()
        let size = fittingSize
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return size
    }
}
