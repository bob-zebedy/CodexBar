import SwiftUI

/// 额度颜色按剩余百分比分档, 菜单栏图标与面板额度条共用同一套阈值和色值
nonisolated enum QuotaPalette {
    static let tiers: [(lowerBound: Int, hex: Int)] = [
        (0, 0xE8605B),
        (10, 0xF57349),
        (20, 0xFD8733),
        (30, 0xFD9A10),
        (40, 0xF2AA06),
        (50, 0xE0B503),
        (60, 0xC7BB06),
        (70, 0xA5BC1A),
        (80, 0x7CB939),
        (90, 0x46B250)
    ]

    static func hex(for percent: Int) -> Int {
        tiers.last(where: { percent >= $0.lowerBound })?.hex ?? tiers[0].hex
    }

    static func color(for percent: Int) -> Color {
        Color(hex: hex(for: percent))
    }
}
