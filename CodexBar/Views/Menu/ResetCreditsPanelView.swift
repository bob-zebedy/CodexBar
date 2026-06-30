import SwiftUI

/// 重置次数侧边面板需要的数据和锚点信息
nonisolated struct ResetCreditsPanelContext: Equatable {
    let expirationDates: [Date]
    let alignmentScreenFrame: CGRect?
    let preferredSide: UsageHeatmapDetailSide
    let maximumPanelHeight: CGFloat?

    init(
        expirationDates: [Date],
        alignmentScreenFrame: CGRect?,
        preferredSide: UsageHeatmapDetailSide,
        maximumPanelHeight: CGFloat? = nil
    ) {
        self.expirationDates = expirationDates
        self.alignmentScreenFrame = alignmentScreenFrame
        self.preferredSide = preferredSide
        self.maximumPanelHeight = maximumPanelHeight
    }

    func withPanelGeometry(
        alignmentScreenFrame: CGRect?,
        maximumPanelHeight: CGFloat?
    ) -> Self {
        Self(
            expirationDates: expirationDates,
            alignmentScreenFrame: alignmentScreenFrame,
            preferredSide: preferredSide,
            maximumPanelHeight: maximumPanelHeight
        )
    }
}

/// 重置次数侧边详情, 按过期时间从近到远展示
struct ResetCreditsPanelView: View {
    let context: ResetCreditsPanelContext
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let groups = expirationGroups
        let panelSize = Self.panelSize(for: context)

        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            if groups.isEmpty {
                emptyMessage
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            row(for: group)

                            if index < groups.count - 1 {
                                rowDivider
                                    .padding(.vertical, Metrics.dividerVerticalPadding)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .liquidGlassSurface(cornerRadius: Metrics.cornerRadius, isOuterSurface: true)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(panelBackingFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(panelBoundaryColor, lineWidth: Metrics.boundaryLineWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        .animation(Metrics.statusAnimation, value: context)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static var initialPanelSize: CGSize {
        panelSize(forGroupCount: 0)
    }

    static func panelSize(for context: ResetCreditsPanelContext) -> CGSize {
        panelSize(
            forGroupCount: ResetCreditExpirationGroup.grouped(from: context.expirationDates).count,
            maximumHeight: context.maximumPanelHeight
        )
    }

    private static func panelSize(forGroupCount rowCount: Int, maximumHeight: CGFloat? = nil) -> CGSize {
        let rowHeight = CGFloat(max(rowCount, 1)) * Metrics.rowHeight
        let rowSpacing = CGFloat(max(rowCount - 1, 0)) * Metrics.rowSpacing
        let rawHeight = Metrics.baseHeight + rowHeight + rowSpacing
        let maximumPanelHeight = maximumHeight.map {
            max($0, Metrics.minimumPanelHeight)
        } ?? Metrics.fallbackMaximumPanelHeight
        return CGSize(
            width: Metrics.panelWidth,
            height: min(max(rawHeight, Metrics.minimumPanelHeight), maximumPanelHeight)
        )
    }

    private var emptyMessage: some View {
        Text("未知过期时间")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
    }

    private var expirationGroups: [ResetCreditExpirationGroup] {
        ResetCreditExpirationGroup.grouped(from: context.expirationDates)
    }

    private func row(for group: ResetCreditExpirationGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            rowHeader(for: group)

            expirationText(group.expirationText)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: Metrics.rowHeight)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        .clear,
                        .primary.opacity(0.18),
                        .green.opacity(0.16),
                        .primary.opacity(0.18),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: Metrics.dividerHeight)
            .padding(.horizontal, 2)
    }

    private func rowHeader(for group: ResetCreditExpirationGroup) -> some View {
        expirationText(group.expirationText)
            .hidden()
            .overlay {
                HStack(alignment: .center, spacing: 8) {
                    Text("过期时间")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    availableValue(count: group.count)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private func expirationText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.codexLabel)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func availableValue(count: Int) -> some View {
        Text("可用: \(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.green)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .liquidGlassCapsule(tint: .green)
    }

    private var panelBackingFill: Color {
        Color(nsColor: .windowBackgroundColor)
            .opacity(colorScheme == .dark ? 0.90 : 0.86)
    }

    private var panelBoundaryColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.18)
            : .black.opacity(0.14)
    }

    private enum Metrics {
        static let expirationTextWidth: CGFloat = 123
        static let horizontalPadding: CGFloat = 12
        static let panelWidth: CGFloat = expirationTextWidth + horizontalPadding * 2
        static let minimumPanelHeight: CGFloat = 62
        static let fallbackMaximumPanelHeight: CGFloat = 260
        static let baseHeight: CGFloat = verticalPadding * 2
        static let rowHeight: CGFloat = 42
        static let rowSpacing: CGFloat = 7
        static let dividerHeight: CGFloat = 1
        static let dividerVerticalPadding: CGFloat = (rowSpacing - dividerHeight) / 2
        static let verticalPadding: CGFloat = 10
        static let cornerRadius: CGFloat = 12
        static let boundaryLineWidth: CGFloat = 0.8
        static let statusAnimation = Animation.codexStatus
    }
}

private struct ResetCreditExpirationGroup: Identifiable, Equatable {
    let expirationText: String
    var count: Int

    var id: String {
        expirationText
    }

    static func grouped(from dates: [Date]) -> [Self] {
        dates.sorted().reduce(into: [Self]()) { groups, date in
            let expirationText = expirationFormatter.string(from: date)

            if let lastIndex = groups.indices.last, groups[lastIndex].expirationText == expirationText {
                groups[lastIndex].count += 1
            } else {
                groups.append(Self(expirationText: expirationText, count: 1))
            }
        }
    }

    private static let expirationFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
