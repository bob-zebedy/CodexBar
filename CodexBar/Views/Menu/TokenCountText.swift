import SwiftUI

/// token 数字展示组件, 负责 K/M/B 缩写和数字滚动过渡
struct TokenCountText: View {
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    let tokens: Int
    var font: Font = MenuMetrics.valueFont

    var body: some View {
        Text(TokenCountFormatter.text(from: tokens))
            .contentTransition(allowsAnimations ? .numericText(value: Double(tokens)) : .identity)
            .font(font)
            .lineLimit(1)
    }
}

struct TokenUsageText: View {
    let tokenUsage: TokenUsage

    var body: some View {
        HStack(spacing: 3) {
            TokenCountText(tokens: Int(tokenUsage.totalTokens), font: .caption2.monospacedDigit())
            Text(verbatim: "tokens")
                .font(.caption2)
        }
        .foregroundStyle(Color.codexSecondaryLabel)
        .fixedSize()
    }
}

/// 1K 以下显示完整整数, 1K 起使用 K/M/B
enum TokenCountFormatter {
    static func text(from tokens: Int) -> String {
        switch tokens {
        case 1000000000...:
            decimal(Double(tokens) / 1000000000) + "B"
        case 1000000...:
            decimal(Double(tokens) / 1000000) + "M"
        case 1000...:
            decimal(Double(tokens) / 1000) + "K"
        default:
            String(tokens)
        }
    }

    private static func decimal(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.formatted(.number.precision(.fractionLength(0 ... 1)).locale(.autoupdatingCurrent))
    }
}
