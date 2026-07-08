import AppKit
import SwiftUI

/// 额度颜色按剩余百分比分档, 菜单栏图标与面板额度条共用同一套阈值和色值
nonisolated enum QuotaPalette {
    static func hex(for percent: Int) -> Int {
        switch percent {
        case 80...:
            0x16A085
        case 60 ..< 80:
            0x5DADE2
        case 40 ..< 60:
            0xF5B041
        case 20 ..< 40:
            0xFF7A59
        default:
            0xEE3F3F
        }
    }

    static func color(for percent: Int) -> Color {
        Color(hex: hex(for: percent))
    }

    static func nsColor(for percent: Int) -> NSColor {
        NSColor(hex: hex(for: percent))
    }
}

nonisolated extension NSColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
