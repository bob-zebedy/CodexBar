import SwiftUI

/// Display P3 额度颜色按剩余百分比分档, 菜单栏图标与面板额度条共用同一套阈值和色值
nonisolated enum QuotaPalette {
    static let tiers: [(lowerBound: Int, hex: Int)] = [
        (0, 0xD86960),
        (10, 0xE57A54),
        (20, 0xED8D48),
        (30, 0xEF9F3C),
        (40, 0xE7AD3C),
        (50, 0xD9B73D),
        (60, 0xBBBE4D),
        (70, 0x99C266),
        (80, 0x79C282),
        (90, 0x5DBE9C)
    ]

    static func hex(for percent: Int) -> Int {
        tiers.last(where: { percent >= $0.lowerBound })?.hex ?? tiers[0].hex
    }

    static func color(for percent: Int) -> Color {
        Color(displayP3Hex: hex(for: percent))
    }
}
