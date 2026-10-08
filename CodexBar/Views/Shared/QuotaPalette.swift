import SwiftUI

/// 额度颜色按剩余百分比分档, 菜单栏图标与面板额度条共用同一套阈值和色值
nonisolated enum QuotaPalette {
    static let tiers: [(lowerBound: Int, hex: Int)] = [
        (0, 0xEE3F3F),
        (20, 0xFF7A59),
        (40, 0xF5B041),
        (60, 0x5DADE2),
        (80, 0x16A085)
    ]

    static func hex(for percent: Int) -> Int {
        tiers.last(where: { percent >= $0.lowerBound })?.hex ?? tiers[0].hex
    }

    static func color(for percent: Int) -> Color {
        Color(hex: hex(for: percent))
    }
}
