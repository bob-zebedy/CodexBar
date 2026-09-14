import SwiftUI

/// token 数字展示组件, 负责 K/M/B 缩写和可选等宽保留
struct TokenCountText: View {
    let tokens: Int
    var font: Font = .caption.monospacedDigit().weight(.semibold)
    var reservedNumericWidth: CGFloat?
    var reservedUnitWidth: CGFloat?

    var body: some View {
        content
            .font(font)
            .lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        let parts = TokenCountFormatter.parts(from: tokens)

        if let reservedNumericWidth {
            HStack(spacing: 0) {
                Text(parts.number)
                    .contentTransition(.numericText(value: Double(tokens)))
                    .truncationMode(.tail)
                    .frame(minWidth: reservedNumericWidth, alignment: .trailing)

                if let unit = parts.unit {
                    Text(unit)
                        .frame(width: reservedUnitWidth, alignment: .trailing)
                }
            }
        } else {
            Text(parts.text)
        }
    }
}

/// 1K 以下显示完整整数, 1K 起使用 K/M/B
private enum TokenCountFormatter {
    static func parts(from tokens: Int) -> TokenCountParts {
        switch tokens {
        case 1000000000...:
            TokenCountParts(number: decimal(Double(tokens) / 1000000000), unit: "B")
        case 1000000...:
            TokenCountParts(number: decimal(Double(tokens) / 1000000), unit: "M")
        case 1000...:
            TokenCountParts(number: decimal(Double(tokens) / 1000), unit: "K")
        default:
            TokenCountParts(number: String(tokens), unit: nil)
        }
    }

    private static func decimal(_ value: Double) -> String {
        let roundingScale: Double = value >= 0.1 ? 10 : 100
        let rounded = (value * roundingScale).rounded() / roundingScale
        return formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.1f", rounded)
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .autoupdatingCurrent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    struct TokenCountParts {
        let number: String
        let unit: String?

        var text: String {
            number + (unit ?? "")
        }
    }
}
