import SwiftUI

struct TokenCountText: View {
    let tokens: Int
    var font: Font = .caption.monospacedDigit().weight(.semibold)
    
    var body: some View {
        Text(TokenCountFormatter.string(from: tokens))
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private enum TokenCountFormatter {
    static func string(from tokens: Int) -> String {
        switch tokens {
        case 1_000_000_000...:
            return decimal(Double(tokens) / 1_000_000_000) + "B"
        case 1_000_000...:
            return decimal(Double(tokens) / 1_000_000) + "M"
        case 1_000...:
            return decimal(Double(tokens) / 1_000) + "K"
        default:
            return String(tokens)
        }
    }
    
    private static func decimal(_ value: Double) -> String {
        let rounded = value >= 0.1 ? (value * 10).rounded() / 10 : (value * 100).rounded() / 100
        return formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.1f", rounded)
    }
    
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
