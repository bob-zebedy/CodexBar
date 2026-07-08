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
