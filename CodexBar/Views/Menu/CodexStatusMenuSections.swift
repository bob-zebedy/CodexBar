import Foundation
import SwiftUI

/// 菜单面板内共享的固定尺寸, 保持各分区对齐
enum MenuMetrics {
    static let panelPadding: CGFloat = 10
    static let panelCornerRadius: CGFloat = 8
    static let accountIconSize: CGFloat = 14
    static let loadingVerticalPadding: CGFloat = 16
}

/// 已登录状态的账号行, 邮箱可双击模糊, 头像可双击刷新
struct AccountCard: View {
    let title: String
    let isEmail: Bool
    let plan: String?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    @State private var isEmailBlurred = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: MenuMetrics.accountIconSize, weight: .medium))
                .foregroundStyle(.tint)
                .onTapGesture(count: 2, perform: onRefresh)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .blur(radius: isEmail && isEmailBlurred ? 3 : 0)
                .animation(.snappy(duration: 0.20), value: isEmailBlurred)
                .onTapGesture(count: 2) {
                    guard isEmail else { return }
                    isEmailBlurred.toggle()
                }

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }

            Spacer()

            if let plan {
                Text(plan.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Self.planBadgeTint(for: plan))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, MenuMetrics.panelPadding)
        .padding(.vertical, 8)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        .onChange(of: title) { _, _ in
            isEmailBlurred = false
        }
    }

    private static func planBadgeTint(for plan: String) -> Color {
        let normalizedPlan = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return planTintRules.first { rule in
            rule.keywords.contains { normalizedPlan.contains($0) }
        }?.tint ?? .cyan
    }

    private static let planTintRules: [(keywords: [String], tint: Color)] = [
        (["enterprise"], Color(hex: 0x15803D)),
        (["team", "business"], Color(hex: 0xD97706)),
        (["pro"], Color(hex: 0xC026D3)),
        (["plus"], Color(hex: 0x2563EB)),
        (["edu"], Color(hex: 0x0891B2)),
        (["free"], Color(hex: 0x64748B))
    ]
}

/// 账户主链路不可用时的账号行, 不展示底层错误细节
struct StatusAccountCard: View {
    let loadState: CodexLoadState
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        let display = statusDisplay
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: MenuMetrics.accountIconSize, weight: .medium))
                .foregroundStyle(display.color)
                .onTapGesture(count: 2, perform: onRefresh)

            if let text = display.text {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(display.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }

            Spacer()
        }
        .padding(.horizontal, MenuMetrics.panelPadding)
        .padding(.vertical, 8)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
    }

    private var statusDisplay: (text: LocalizedStringResource?, color: Color) {
        switch loadState {
        case .notLoggedIn:
            ("未登录", .orange)
        case let .unsupportedVersion(minimum):
            ("需要 Codex \(minimum) 或更高版本", .red)
        case .initializationFailed:
            ("初始化失败", .red)
        case .loading, .loaded:
            (nil, .accentColor)
        }
    }
}

/// 额度和用量均无数据时的统一占位面板
struct EmptyDataPanel: View {
    var body: some View {
        Text("暂无数据")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, MenuMetrics.loadingVerticalPadding)
            .padding(MenuMetrics.panelPadding)
            .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
    }
}

/// 多个 limit 的额度区, 使用 stale 透明度标记缓存回退数据
struct QuotaLimitsSection: View {
    let limits: [CodexQuotaLimitSnapshot]
    let credits: RateLimitCreditsSnapshot?
    let resetCreditsAvailableCount: Int?
    let resetCreditExpirationDates: [Date]?
    let isStale: Bool
    let onResetCreditsTap: (ResetCreditsPanelContext) -> Void
    @State private var sectionFrameProvider = ScreenFrameProvider()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(limits) { limit in
                let isPrimary = limit.id == limits.first?.id
                if !isPrimary {
                    LiquidGlassDivider()
                }

                quotaLimitSection(limit, showsPrimaryMetadata: isPrimary)
            }
        }
        .markStale(isStale)
        .padding(MenuMetrics.panelPadding)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        .background {
            ScreenFrameReader(provider: sectionFrameProvider)
        }
    }

    private func quotaLimitSection(_ limit: CodexQuotaLimitSnapshot, showsPrimaryMetadata: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(limit.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if showsPrimaryMetadata, let credits, let value = creditsDisplayValue(credits) {
                    creditsBalance(value: value, credits: credits)
                }

                if showsPrimaryMetadata, let resetCreditsAvailableCount, resetCreditsAvailableCount > 0 {
                    resetCreditsButton(count: resetCreditsAvailableCount)
                }
            }

            VStack(spacing: 8) {
                ForEach(limit.windows) { window in
                    QuotaRow(window: window)
                }
            }
        }
    }

    @ViewBuilder
    private func creditsBalance(value: String, credits: RateLimitCreditsSnapshot) -> some View {
        let capsule = metadataCapsule(String(localized: "积分: \(value)"))

        if let helpText = creditsHelpText(value: value, credits: credits) {
            capsule.help(helpText)
        } else {
            capsule
        }
    }

    private func creditsDisplayValue(_ credits: RateLimitCreditsSnapshot) -> String? {
        if credits.unlimited {
            return String(localized: "无限")
        }

        if let balance = normalizedCreditsBalance(credits.balance) {
            return compactCreditsBalance(balance)
        }

        return credits.hasCredits ? String(localized: "可用") : nil
    }

    private func creditsHelpText(value: String, credits: RateLimitCreditsSnapshot) -> String? {
        guard value.hasSuffix("K") || value.hasSuffix("M"),
              let balance = normalizedCreditsBalance(credits.balance) else {
            return nil
        }

        return balance
    }

    private func normalizedCreditsBalance(_ balance: String?) -> String? {
        guard let balance = balance?.trimmingCharacters(in: .whitespacesAndNewlines), !balance.isEmpty else {
            return nil
        }

        return balance
    }

    private func compactCreditsBalance(_ balance: String) -> String {
        guard let amount = Double(balance), amount.isFinite else {
            return truncatedCreditsBalance(balance)
        }

        let magnitude = abs(amount)
        guard magnitude >= Self.compactCreditsThreshold else {
            return truncatedCreditsBalance(balance)
        }

        guard let unit = Self.compactCreditsUnits.first(where: { magnitude >= $0.divisor }),
              let formattedAmount = Self.compactCreditsFormatter.string(
                  from: NSNumber(value: amount / unit.divisor)
              ) else {
            return truncatedCreditsBalance(balance)
        }

        return truncatedCreditsBalance("\(formattedAmount)\(unit.suffix)")
    }

    private func truncatedCreditsBalance(_ balance: String) -> String {
        guard balance.count > Self.maximumFallbackCreditsCharacters else {
            return balance
        }

        return "\(balance.prefix(Self.maximumFallbackCreditsCharacters - 3))..."
    }

    private func resetCreditsButton(count: Int) -> some View {
        Button {
            onResetCreditsTap(
                ResetCreditsPanelContext(
                    expirationDates: resetCreditExpirationDates ?? [],
                    alignmentScreenFrame: sectionFrameProvider.currentScreenFrame(),
                    preferredSide: .right
                )
            )
        } label: {
            metadataCapsule(String(localized: "重置次数: \(count)"))
        }
        .buttonStyle(.plain)
    }

    private func metadataCapsule(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.green)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .liquidGlassCapsule(tint: .green)
    }

    private static let compactCreditsThreshold = 10000.0
    private static let maximumFallbackCreditsCharacters = 12
    private static let compactCreditsUnits: [(divisor: Double, suffix: String)] = [
        (1000000000000, "T"),
        (1000000000, "B"),
        (1000000, "M"),
        (1000, "K")
    ]

    private static let compactCreditsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

/// 底部更新时间行, 同时承载 Sparkle 被动更新提示
struct UpdatedAtRow: View {
    let snapshot: CodexQuotaSnapshot
    let countdownStartedAt: Date
    let countdownInterval: TimeInterval
    let isCountdownActive: Bool
    let syncDisplayState: WorkflowSyncDisplayState
    let updateMessage: String?
    let startUpdate: () -> Void

    var body: some View {
        HStack {
            HStack(spacing: 5) {
                AutoRefreshCountdownTimeline(
                    startedAt: countdownStartedAt,
                    interval: countdownInterval,
                    isActive: isCountdownActive,
                    color: .blue
                )

                Text("数据更新时间")
                    .foregroundStyle(Self.secondaryTextColor)

                Text(Self.timeFormatter.string(from: snapshot.generatedAt))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(Self.secondaryTextColor)
            }
            .font(.caption2)
            .animation(Metrics.statusAnimation, value: snapshot.generatedAt)

            Spacer()

            if let updateMessage {
                Text(updateMessage)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .transition(.opacity)
                    .onTapGesture(count: 2, perform: startUpdate)
            }

            Image(systemName: syncDisplayState.symbolName)
                .font(.caption2)
                .foregroundStyle(syncDisplayState.tint)
                .frame(width: Metrics.syncIconWidth)
                .contentTransition(.opacity)
                .help(syncDisplayState.helpText)
        }
        .animation(Metrics.statusAnimation, value: updateMessage)
        .animation(Metrics.statusAnimation, value: syncDisplayState)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let secondaryTextColor = Color.codexSecondaryLabel

    private enum Metrics {
        static let statusAnimation = Animation.codexStatus
        static let syncIconWidth: CGFloat = 16
    }
}

struct WorkflowSyncDisplayState: Equatable {
    let symbolName: String
    let tint: Color
    let helpText: String

    static func == (lhs: WorkflowSyncDisplayState, rhs: WorkflowSyncDisplayState) -> Bool {
        lhs.symbolName == rhs.symbolName && lhs.helpText == rhs.helpText
    }

    init(isHookEnabled: Bool, settings: WorkflowSyncSettings) {
        guard settings.isEffectivelyActive(isHookEnabled: isHookEnabled) else {
            self = .disabled
            return
        }

        if settings.isSyncing {
            self = .syncing
        } else if settings.hasSyncFailure {
            self = .failed(message: settings.syncFailureMessage)
        } else {
            self = .enabled(settings.lastUploadAtText)
        }
    }

    private init(symbolName: String, tint: Color, helpText: String) {
        self.symbolName = symbolName
        self.tint = tint
        self.helpText = helpText
    }

    private static func enabled(_ lastSyncText: String?) -> WorkflowSyncDisplayState {
        WorkflowSyncDisplayState(
            symbolName: "icloud",
            tint: .codexSecondaryLabel,
            helpText: lastSyncText.map { String(localized: "最近同步: \($0)") }
                ?? String(localized: "暂无同步记录")
        )
    }

    private static let disabled = WorkflowSyncDisplayState(
        symbolName: "icloud.slash",
        tint: .codexSecondaryLabel,
        helpText: String(localized: "同步未开启")
    )

    private static let syncing = WorkflowSyncDisplayState(
        symbolName: "arrow.trianglehead.clockwise.icloud",
        tint: .blue,
        helpText: String(localized: "正在同步")
    )

    private static func failed(message: String?) -> WorkflowSyncDisplayState {
        WorkflowSyncDisplayState(
            symbolName: "exclamationmark.icloud",
            tint: .orange,
            helpText: message ?? WorkflowSyncFailureReason.retryLater.message
        )
    }
}
