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
    @Environment(\.colorScheme) private var colorScheme
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
                    .foregroundStyle(
                        Self.planBadgeTint(for: plan, colorScheme: colorScheme)
                    )
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

    private static func planBadgeTint(for plan: String, colorScheme: ColorScheme) -> Color {
        let normalizedPlan = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let colors = planTints.first { $0.plans.contains(normalizedPlan) }?.colors
            ?? (light: 0x69717A, dark: 0xB1B7C0)
        return Color(hex: colorScheme == .dark ? colors.dark : colors.light)
    }

    /// 按完整套餐名归入产品系列, 避免复合名称被其他系列匹配
    private static let planTints: [(plans: [String], colors: (light: Int, dark: Int))] = [
        (["free"], (0x527566, 0xA3C8B5)),
        (["go"], (0x237D72, 0x77C9B6)),
        (["plus"], (0x366FA8, 0x8FBCEB)),
        (["prolite"], (0x6676AF, 0xB0BCEB)),
        (["pro"], (0x8055AB, 0xC5A5E8)),
        (["promax"], (0x986B2F, 0xE2BF7F)),
        (["team"], (0x287D94, 0x83C9DC)),
        (["business", "self_serve_business_prolite", "self_serve_business_usage_based"], (0xA1654B, 0xDDAF95)),
        (["enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based"], (0x566780, 0xAABBD5)),
        (["edu", "edu_plus", "edu_pro"], (0xA0567C, 0xDEABC9))
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
            ("codex-status.account.not-signed-in", .orange)
        case let .unsupportedVersion(minimum):
            (LocalizedStringResource("codex-version.requirement", defaultValue: "\(minimum)"), .red)
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
        Text("common.empty.no-data")
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
                    .layoutPriority(-1)

                Spacer(minLength: 8)

                if showsPrimaryMetadata, let credits {
                    let value = creditsDisplayValue(credits)
                    metadataCapsule(
                        String(localized: "quota.credits.value", defaultValue: "\(value)"),
                        tint: credits.unlimited || credits.hasCredits ? .green : .orange
                    )
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

    private func creditsDisplayValue(_ credits: RateLimitCreditsSnapshot) -> String {
        if credits.unlimited {
            return String(localized: "quota.value.unlimited")
        }

        return normalizedCreditsBalance(credits.balance)
            ?? String(localized: "common.status.available")
    }

    private func normalizedCreditsBalance(_ balance: String?) -> String? {
        guard let balance = balance?.trimmingCharacters(in: .whitespacesAndNewlines), !balance.isEmpty else {
            return nil
        }

        guard let value = Double(balance), value.isFinite else {
            return balance
        }

        if value > 0, value < 1 {
            return "< 1"
        }

        return value.rounded(.towardZero).formatted(.number.grouping(.never).precision(.fractionLength(0)))
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
            metadataCapsule(String(localized: "banked-reset.count", defaultValue: "\(count, specifier: "%lld")"))
        }
        .buttonStyle(.plain)
    }

    private func metadataCapsule(_ text: String, tint: Color = .green) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .liquidGlassCapsule(tint: tint)
    }
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

                Text("usage.status.last-updated")
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

    init(isAdvancedModeEnabled: Bool, settings: WorkflowSyncSettings) {
        guard settings.isEffectivelyActive(isAdvancedModeEnabled: isAdvancedModeEnabled) else {
            self = .disabled
            return
        }

        if settings.isSyncing {
            self = .syncing
        } else if settings.hasSyncFailure {
            self.init(
                symbolName: "exclamationmark.icloud",
                tint: .orange,
                helpText: settings.syncFailureMessage ?? WorkflowSyncFailureReason.retryLater.message
            )
        } else {
            self.init(
                symbolName: "icloud",
                tint: .codexSecondaryLabel,
                helpText: settings.lastUploadAtText.map { String(localized: "sync.status.last-sync-time", defaultValue: "\($0)") }
                    ?? String(localized: "sync.status.no-history")
            )
        }
    }

    private init(symbolName: String, tint: Color, helpText: String) {
        self.symbolName = symbolName
        self.tint = tint
        self.helpText = helpText
    }

    private static let disabled = WorkflowSyncDisplayState(
        symbolName: "icloud.slash",
        tint: .codexSecondaryLabel,
        helpText: String(localized: "sync.status.disabled")
    )

    private static let syncing = WorkflowSyncDisplayState(
        symbolName: "arrow.trianglehead.clockwise.icloud",
        tint: .blue,
        helpText: String(localized: "sync.status.syncing")
    )
}
