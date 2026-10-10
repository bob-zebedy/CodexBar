import Combine
import SwiftUI

extension EnvironmentValues {
    // 持续动画需要显式停用, 不能只依赖 transaction 的动画禁用
    @Entry var mainPanelAnimationsEnabled: Bool = false
    @Entry var mainPanelEntranceAnimationsEnabled: Bool = true
}

/// 菜单面板展示状态, 可见性控制逐秒更新, 展示代次区分快速重开
@MainActor
final class MenuSurfaceVisibilityState: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var presentationGeneration: UInt = 0

    func beginPresentation() {
        presentationGeneration &+= 1
        isVisible = true
    }

    func endPresentation() {
        isVisible = false
    }
}

/// 每个宿主独立控制动画, 淡出完成前仍保留可见内容的过渡
@MainActor
final class MenuSurfaceAnimationState: ObservableObject {
    @Published var allowsAnimations = false
}

/// 菜单栏弹出面板根视图, 汇总账号; 实时活动; 额度; token; 同步状态和更新时间
struct CodexStatusMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + MenuMetrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth

    @ObservedObject var viewModel: CodexStatusViewModel
    @ObservedObject var historyViewModel: HistoryViewModel
    @ObservedObject var mainPanelSettings: MainPanelSettings
    // 活动状态与时间变化由卡片自行观察, 避免刷新整个菜单树
    let activityMonitor: ActivityMonitor
    @ObservedObject var syncSettings: SyncSettings
    // 同 activityMonitor, 交给活动卡片自行观察, 不让 helper 状态变化重算整个菜单树
    let keepAliveController: KeepAliveController
    @ObservedObject var menuSurfaceVisibility: MenuSurfaceVisibilityState
    @ObservedObject var animationState: MenuSurfaceAnimationState
    let activityCenterPresentationState: ActivityCenterPresentationState
    let onUsageHeatmapHoverChange: (UsageHeatmapHoverContext?) -> Void
    let onResetCreditsTap: (ResetCreditsPanelContext) -> Void
    let onActivityCenterTap: (ActivityCenterPanelContext) -> Void
    @EnvironmentObject private var appUpdater: AppUpdater
    @State private var activitySectionVisibility: Bool?

    private var showsActivitySection: Bool {
        // 订阅建立前直接读取当前状态, 避免首次打开时先显示空卡片再收回
        activitySectionVisibility
            ?? (activityMonitor.snapshot.hasTaskCenterContent || !activityMonitor.isActivitySourceHealthy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.verticalSpacing) {
            content
        }
        .environment(
            \.mainPanelAnimationsEnabled,
            animationState.allowsAnimations && mainPanelSettings.areAnimationsEnabled
        )
        .environment(
            \.mainPanelEntranceAnimationsEnabled,
            mainPanelSettings.areAnimationsEnabled
        )
        .padding(Metrics.padding)
        .liquidGlassSurface(cornerRadius: Metrics.surfaceCornerRadius, isOuterSurface: true)
        .animation(Metrics.statusAnimation, value: viewModel.loadState)
        .animation(Metrics.statusAnimation, value: mainPanelSettings.layout)
        .animation(Metrics.statusAnimation, value: syncSettings.isEnabled)
        .animation(Metrics.statusAnimation, value: syncSettings.isSyncing)
        .animation(Metrics.statusAnimation, value: syncSettings.hasSyncFailure)
        .animation(
            mainPanelSettings.areAnimationsEnabled ? Metrics.activityExpansionAnimation : nil,
            value: showsActivitySection
        )
        .onReceive(
            activityMonitor.$snapshot
                .combineLatest(activityMonitor.$isActivitySourceHealthy)
                .map { snapshot, isHealthy in snapshot.hasTaskCenterContent || !isHealthy }
                .removeDuplicates()
        ) { activitySectionVisibility = $0 }
        .transaction { transaction in
            // 已关闭的 NSPopover 仍可能绘制数字过渡, 让字体缓存逐轮增长
            guard !animationState.allowsAnimations else {
                return
            }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}

private extension CodexStatusMenuView {
    enum Metrics {
        static let padding: CGFloat = 12
        static let surfaceCornerRadius: CGFloat = 14
        static let verticalSpacing: CGFloat = 10
        static let statusAnimation = Animation.codexStatus
        static let activityExpansionAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
    }

    @ViewBuilder
    var content: some View {
        let visibleSections = mainPanelSettings.layout.visibleSections.filter { section in
            section != .activity || showsActivitySection
        }
        let dataPlaceholderSection = dataPlaceholderSection(in: visibleSections)

        ForEach(visibleSections) { section in
            sectionView(section, dataPlaceholderSection: dataPlaceholderSection)
                .transition(section == .activity ? .modifier(
                    active: ActivitySectionReveal(progress: 0),
                    identity: ActivitySectionReveal(progress: 1)
                ) : .opacity)
        }

        if !hasRenderableContent(
            in: visibleSections,
            dataPlaceholderSection: dataPlaceholderSection
        ) {
            EmptyDataPanel()
        }
    }

    @ViewBuilder
    func sectionView(
        _ section: MainPanelSection,
        dataPlaceholderSection: MainPanelSection?
    ) -> some View {
        switch section {
        case .account:
            accountSection
        case .activity:
            activitySection
        case .quota:
            quotaSection(dataPlaceholderSection: dataPlaceholderSection)
        case .usage:
            usageSection(dataPlaceholderSection: dataPlaceholderSection)
        case .status:
            statusSection
        }
    }

    @ViewBuilder
    var accountSection: some View {
        if let snapshot = viewModel.snapshot {
            AccountCard(
                title: snapshot.accountLabel,
                isEmail: snapshot.account.hasEmail,
                plan: snapshot.planLabel,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: { viewModel.refresh(trigger: .manual) }
            )
        } else {
            // 展示用户可处理的账户主链路状态, 其余错误只进日志
            StatusAccountCard(
                loadState: viewModel.loadState,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: { viewModel.refresh(trigger: .manual) }
            )
        }
    }

    var activitySection: some View {
        ActivityCard(
            activityMonitor: activityMonitor,
            presentationState: activityCenterPresentationState,
            keepAliveController: keepAliveController,
            onTaskCenterTap: { anchorProvider in
                onActivityCenterTap(
                    ActivityCenterPanelContext(
                        anchorProvider: anchorProvider,
                        preferredSide: .right
                    )
                )
            }
        )
    }

    @ViewBuilder
    func quotaSection(dataPlaceholderSection: MainPanelSection?) -> some View {
        if let snapshot = viewModel.snapshot, !snapshot.limits.isEmpty {
            QuotaLimitsSection(
                limits: snapshot.limits,
                credits: snapshot.credits,
                resetCreditsAvailableCount: snapshot.resetCreditsAvailableCount,
                resetCreditExpirationDates: snapshot.resetCreditExpirationDates,
                isStale: snapshot.isRateLimitsStale,
                onResetCreditsTap: onResetCreditsTap
            )
            .id(menuSurfaceVisibility.presentationGeneration)
        } else if dataPlaceholderSection == .quota {
            EmptyDataPanel()
        }
    }

    @ViewBuilder
    func usageSection(dataPlaceholderSection: MainPanelSection?) -> some View {
        if hasData(for: .usage) {
            UsageSummaryView(
                usage: viewModel.snapshot?.usage,
                history: historyViewModel.snapshot,
                isStale: viewModel.snapshot?.isUsageStale ?? false,
                onHoverContextChange: onUsageHeatmapHoverChange
            )
            .id(menuSurfaceVisibility.presentationGeneration)
        } else if dataPlaceholderSection == .usage {
            EmptyDataPanel()
        }
    }

    @ViewBuilder
    var statusSection: some View {
        if let snapshot = viewModel.snapshot {
            updatedAtRow(for: snapshot)
                .padding(.horizontal, MenuMetrics.panelPadding)
                .padding(.vertical, 7)
                .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        }
    }

    func dataPlaceholderSection(in visibleSections: [MainPanelSection]) -> MainPanelSection? {
        let visibleDataSections = visibleSections.filter { section in
            section == .quota || section == .usage
        }
        guard !visibleDataSections.isEmpty,
              !visibleDataSections.contains(where: hasData(for:)) else {
            return nil
        }

        return visibleDataSections.first
    }

    func hasData(for section: MainPanelSection) -> Bool {
        switch section {
        case .quota:
            viewModel.snapshot?.limits.isEmpty == false
        case .usage:
            viewModel.snapshot != nil || !historyViewModel.snapshot.dailyMetrics.isEmpty
                || !historyViewModel.snapshot.tokenUsageByDate.isEmpty
        case .account, .activity, .status:
            false
        }
    }

    func hasRenderableContent(
        in visibleSections: [MainPanelSection],
        dataPlaceholderSection: MainPanelSection?
    ) -> Bool {
        visibleSections.contains { section in
            switch section {
            case .account:
                true
            case .activity:
                true
            case .quota, .usage:
                hasData(for: section) || dataPlaceholderSection == section
            case .status:
                viewModel.snapshot != nil
            }
        }
    }

    func updatedAtRow(for snapshot: CodexQuotaSnapshot) -> some View {
        UpdatedAtRow(
            snapshot: snapshot,
            countdownStartedAt: viewModel.autoRefreshCountdownStartedAt ?? snapshot.generatedAt,
            countdownInterval: viewModel.autoRefreshInterval,
            isCountdownActive: menuSurfaceVisibility.isVisible,
            syncDisplayState: SyncDisplayState(
                settings: syncSettings
            ),
            updateMessage: appUpdater.panelUpdateMessage,
            startUpdate: appUpdater.startUpdate
        )
    }
}

private struct ActivitySectionReveal: AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        ActivitySectionRevealLayout(progress: progress) {
            content
        }
        // 完全展开后为玻璃表面的外投影留出空间, 不裁掉边缘高光和阴影
        .clipShape(Rectangle().inset(by: progress < 1 ? 0 : -64))
    }
}

private struct ActivitySectionRevealLayout: Layout {
    var progress: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * min(1, max(0, progress)))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        // 保留内容的自然高度, 只改变裁剪区域, 避免展开和收回时压缩文字
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}
