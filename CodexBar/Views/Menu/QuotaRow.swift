import SwiftUI

struct QuotaRow: View {
    let window: QuotaWindow

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(window.label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(Metrics.labelMinimumScaleFactor)
                .allowsTightening(true)
                .frame(width: Metrics.labelWidth, alignment: .center)

            SegmentedQuotaBar(percent: displayPercent)
                .padding(.leading, Metrics.labelBarSpacing)

            Text(percentText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(percentColor)
                .lineLimit(1)
                .frame(width: Metrics.percentWidth, alignment: .leading)
                .padding(.leading, Metrics.barPercentSpacing)

            Spacer(minLength: Metrics.percentResetSpacing)

            Text(resetText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Metrics.resetWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension QuotaRow {
    enum Metrics {
        static let labelWidth: CGFloat = 34
        static let labelMinimumScaleFactor: CGFloat = 0.75
        static let labelBarSpacing: CGFloat = 12
        static let barPercentSpacing: CGFloat = 8
        static let percentWidth: CGFloat = 37
        static let percentResetSpacing: CGFloat = 6
        static let resetWidth: CGFloat = 75
    }

    var resetText: String {
        guard window.hasData, let resetsAt = window.resetsAt else {
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

    static let placeholderColor = Color(hex: 0xE5E7EB)
    private static let green = Color(hex: 0x16A085)
    private static let teal = Color(hex: 0x5DADE2)
    private static let yellow = Color(hex: 0xF5B041)
    private static let orange = Color(hex: 0xFF7A59)
    private static let red = Color(hex: 0xEE3F3F)
}

private struct SegmentedQuotaBar: View {
    let percent: Int?

    var body: some View {
        let filledColor = QuotaBarPalette.filledColor(for: percent)

        HStack(spacing: Metrics.segmentSpacing) {
            ForEach(0..<Metrics.segmentCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index < filledSegments ? filledColor : QuotaBarPalette.placeholderColor)
                    .frame(width: Metrics.segmentWidth, height: Metrics.segmentHeight)
            }
        }
        .frame(width: Metrics.totalWidth, height: Metrics.segmentHeight, alignment: .leading)
    }
}

private extension SegmentedQuotaBar {
    enum Metrics {
        static let segmentCount = 50
        static let segmentWidth: CGFloat = 3.5
        static let segmentSpacing: CGFloat = 2
        static let segmentHeight: CGFloat = 12

        static var totalWidth: CGFloat {
            CGFloat(segmentCount) * segmentWidth + CGFloat(segmentCount - 1) * segmentSpacing
        }
    }

    var filledSegments: Int {
        guard let percent else {
            return 0
        }

        return Int((Double(percent) / 100.0 * Double(Metrics.segmentCount)).rounded())
    }
}
