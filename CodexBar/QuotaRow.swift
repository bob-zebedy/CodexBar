import SwiftUI

struct QuotaRow: View {
    let window: QuotaWindow
    
    var body: some View {
        HStack(alignment: .center, spacing: Metrics.spacing) {
            Text(window.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(width: Metrics.labelWidth, alignment: .leading)
            
            SegmentedQuotaBar(percent: displayPercent)
                .frame(height: Metrics.barHeight)
            
            Text(percentText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(percentColor)
                .lineLimit(1)
                .frame(width: Metrics.percentWidth, alignment: .leading)
            
            Text(resetText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Metrics.resetWidth, alignment: .trailing)
        }
    }
}

private extension QuotaRow {
    enum Metrics {
        static let spacing: CGFloat = 8
        static let labelWidth: CGFloat = 52
        static let barHeight: CGFloat = 12
        static let percentWidth: CGFloat = 32
        static let resetWidth: CGFloat = 76
    }
    
    var resetText: String {
        guard window.hasData else {
            return "--"
        }
        
        guard let resetsAt = window.resetsAt else {
            return "--"
        }
        
        return Self.resetFormatter.string(from: resetsAt)
    }
    
    var percentText: String {
        guard window.hasData else {
            return "--"
        }
        
        return "\(window.remainingPercent)%"
    }
    
    var displayPercent: Int? {
        window.hasData ? window.remainingPercent : nil
    }
    
    var percentColor: Color {
        guard window.hasData else {
            return .secondary
        }
        
        return QuotaBarPalette.filledColor(for: window.remainingPercent)
    }
    
    static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

private enum QuotaBarPalette {
    static func filledColor(for percent: Int?) -> Color {
        guard let percent else {
            return placeholderColor
        }
        
        switch percent {
        case 80...:
            return green
        case 60..<80:
            return teal
        case 40..<60:
            return yellow
        case 20..<40:
            return orange
        default:
            return red
        }
    }
    
    static let placeholderColor = color(hex: 0xE5E7EB)
    private static let green = color(hex: 0x22C55E)
    private static let teal = color(hex: 0x14B8A6)
    private static let yellow = color(hex: 0xEAB308)
    private static let orange = color(hex: 0xFF7A59)
    private static let red = color(hex: 0xEF4444)
    
    private static func color(hex: Int) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

private struct SegmentedQuotaBar: View {
    let percent: Int?
    
    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = segmentWidth(for: proxy.size.width)
            let filledSegments = filledSegments()
            let filledColor = QuotaBarPalette.filledColor(for: percent)
            
            HStack(spacing: Metrics.segmentSpacing) {
                ForEach(0..<Metrics.segmentCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index < filledSegments ? filledColor : QuotaBarPalette.placeholderColor)
                        .frame(width: segmentWidth, height: proxy.size.height)
                }
            }
        }
    }
}

private extension SegmentedQuotaBar {
    enum Metrics {
        static let segmentCount = 33
        static let segmentSpacing: CGFloat = 2
    }
    
    func segmentWidth(for width: CGFloat) -> CGFloat {
        let availableWidth = max(width, 0)
        let totalSpacing = CGFloat(Metrics.segmentCount - 1) * Metrics.segmentSpacing
        return max(0, (availableWidth - totalSpacing) / CGFloat(Metrics.segmentCount))
    }
    
    func filledSegments() -> Int {
        guard let percent else {
            return 0
        }
        
        return Int((Double(percent) / 100.0 * Double(Metrics.segmentCount)).rounded())
    }
}
