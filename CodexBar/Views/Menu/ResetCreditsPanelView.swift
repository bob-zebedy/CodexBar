import SwiftUI

/// 重置次数侧边详情, 按过期时间从近到远展示
struct ResetCreditsPanelView: View {
    let content: ResetCreditsPanelContent
    @ObservedObject var mainPanelSettings: MainPanelSettings
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        TimelineView(.animation(paused: content.startedAt == nil)) { timeline in
            let progress = content.progress(at: timeline.date)
            drawer(at: progress)
                .onChange(of: progress == 1 ? content.startedAt : nil, initial: true) { _, completed in
                    if let completed, completed == content.startedAt {
                        content.finish()
                    }
                }
        }
        .id(ObjectIdentifier(content))
        .contentAnimations(settings: mainPanelSettings)
        .onChange(of: mainPanelSettings.areAnimationsEnabled) { _, enabled in
            if !enabled {
                content.finish()
            }
        }
    }

    func drawer(at progress: CGFloat) -> some View {
        let size = panelSize(at: progress)

        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(content.rows) { entry in
                    let visibility = entry.visibility(at: progress)
                    VStack(spacing: 0) {
                        if let group = entry.group {
                            row(for: group, visibility: visibility)
                        } else {
                            emptyMessage.frame(height: Metrics.rowHeight)
                        }
                        rowDivider.padding(.vertical, Metrics.dividerVerticalPadding)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // 每行只在自己的可见高度内滑动, 相邻日期始终占据独立区域
                    .offset(y: -Metrics.revealOffset * (1 - visibility))
                    .frame(height: Metrics.slotHeight * visibility, alignment: .top)
                    .clipped()
                    .opacity(visibility)
                }
            }
            .padding(.bottom, -Metrics.rowSpacing)
            .clipped()
        }
        .scrollIndicators(.never)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
        .frame(width: size.width, height: size.height, alignment: .top)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        // 宿主窗口跟随同一帧的内容高度, 取整产生的余量留在底部
        .frame(maxHeight: .infinity, alignment: .top)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static var initialPanelSize: CGSize {
        CGSize(width: Metrics.panelWidth, height: Metrics.minimumPanelHeight)
    }

    func panelSize(at progress: CGFloat) -> CGSize {
        let slots = content.rows.reduce(CGFloat.zero) { $0 + $1.visibility(at: progress) }
        let height = Metrics.baseHeight + Metrics.slotHeight * slots - Metrics.rowSpacing
        let limit = max(Metrics.minimumPanelHeight, (content.maximumHeight ?? Metrics.fallbackMaximumPanelHeight).rounded(.down))
        return CGSize(width: Metrics.panelWidth, height: min(max(height.rounded(.up), Metrics.minimumPanelHeight), limit))
    }

    private var emptyMessage: some View {
        Text("banked-reset.expiration.unknown")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
    }

    private func row(for group: ResetCreditExpirationGroup, visibility: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            rowHeader(for: group)

            expirationText(group.expirationText)
                // 第二行有足够空间时再显出日期, 收起时也先淡去以免露出半截数字
                .opacity(min(1, max(0, (visibility - 0.60) / 0.35)))
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
                        Color.clear,
                        Color.primary.opacity(0.18),
                        Color.green.opacity(0.16),
                        Color.primary.opacity(0.18),
                        Color.clear
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
                HStack(alignment: .center, spacing: 0) {
                    Text("banked-reset.expiration.label")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    availableValue(for: group)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private func expirationText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.codexLabel)
            .numericTransition(value: text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func availableValue(for group: ResetCreditExpirationGroup) -> some View {
        let tint = if group.isExpiringUrgently {
            Color.red
        } else if group.isExpiringSoon {
            Color.orange
        } else {
            Color.green
        }

        return Text(LocalizedStringResource("banked-reset.available-count", defaultValue: "\(group.count, specifier: "%lld")"))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(tint)
            .numericTransition(value: group.count, comparison: Double(group.count))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .liquidGlassCapsule(tint: tint)
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
        static let slotHeight = rowHeight + rowSpacing
        static let revealOffset: CGFloat = 5
    }
}

/// 保留正在收起的日期行, 如果动画中途又收到更新, 各行就从当前高度继续展开或收起
@Observable
final class ResetCreditsPanelContent {
    struct Row: Identifiable {
        let group: ResetCreditExpirationGroup?
        var start: CGFloat
        let end: CGFloat
        var id: TimeInterval? {
            group?.id
        }

        func visibility(at progress: CGFloat) -> CGFloat {
            start + (end - start) * progress
        }
    }

    private(set) var rows: [Row] = []
    private(set) var startedAt: Date?
    var maximumHeight: CGFloat?

    func update(_ dates: [Date], animated: Bool, now: Date = Date()) {
        let groups = ResetCreditExpirationGroup.grouped(from: dates, now: now)
        var next = groups.map { Row(group: $0, start: 1, end: 1) }
        if next.isEmpty {
            next = [Row(group: nil, start: 1, end: 1)]
        }

        if animated, !rows.isEmpty {
            let progress = progress(at: now)
            var previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            for index in next.indices {
                next[index].start = previous.removeValue(forKey: next[index].id)?.visibility(at: progress) ?? 0
            }
            for row in previous.values {
                let visibility = row.visibility(at: progress)
                if visibility > 0 {
                    next.append(Row(group: row.group, start: visibility, end: 0))
                }
            }
            next.sort { ($0.group?.date ?? .distantPast) < ($1.group?.date ?? .distantPast) }
        }
        rows = next
        startedAt = next.contains { $0.start != $0.end } ? now : nil
    }

    func progress(at now: Date) -> CGFloat {
        guard let startedAt else { return 1 }
        let t = min(1, max(0, now.timeIntervalSince(startedAt) / 0.30))
        return t * t * (3 - 2 * t)
    }

    func finish() {
        guard startedAt != nil else { return }
        rows.removeAll { $0.end == 0 }
        startedAt = nil
    }
}

struct ResetCreditExpirationGroup: Identifiable, Equatable {
    let date: Date
    let expirationText: String
    var count: Int
    let isExpiringSoon: Bool
    let isExpiringUrgently: Bool

    var id: TimeInterval {
        date.timeIntervalSinceReferenceDate.rounded(.down)
    }

    static func grouped(from dates: [Date], now: Date = Date()) -> [Self] {
        dates.sorted().reduce(into: [Self]()) { groups, date in
            let expirationText = CodexDateFormat.localDisplayString(from: date)

            if let lastIndex = groups.indices.last, groups[lastIndex].expirationText == expirationText {
                groups[lastIndex].count += 1
            } else {
                let remainingTime = date.timeIntervalSince(now)
                let isExpiringSoon = remainingTime > 0 && remainingTime <= expiringSoonInterval
                groups.append(
                    Self(
                        date: date, expirationText: expirationText,
                        count: 1,
                        isExpiringSoon: isExpiringSoon,
                        isExpiringUrgently: isExpiringSoon && remainingTime < expiringUrgentlyInterval
                    )
                )
            }
        }
    }

    private static let expiringSoonInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let expiringUrgentlyInterval: TimeInterval = 24 * 60 * 60
}
