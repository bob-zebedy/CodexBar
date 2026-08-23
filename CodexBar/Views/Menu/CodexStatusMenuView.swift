import Combine
import SwiftUI

/// 菜单面板可见状态, 用于控制逐秒时间更新
@MainActor
final class MenuSurfaceVisibilityState: ObservableObject {
    @Published var isVisible = false
}

/// 菜单栏弹出面板根视图, 汇总账号; 实时活动; 额度; token; 同步状态和更新时间
struct CodexStatusMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + MenuMetrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth

    @ObservedObject var viewModel: CodexStatusViewModel
    @ObservedObject var workflowViewModel: WorkflowViewModel
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var mainPanelSettings: MainPanelSettings
    // 活动状态与逐秒时间只被活动卡片消费, 由卡片自行观察, 避免 1Hz tick 让整个菜单树每秒重算
    let activityMonitor: CodexActivityMonitor
    @ObservedObject var syncSettings: WorkflowSyncSettings
    // 同 activityMonitor, 交给活动卡片自行观察, 不让 helper 状态变化重算整个菜单树
    let keepAliveController: KeepAliveController
    @ObservedObject var menuSurfaceVisibility: MenuSurfaceVisibilityState
    let activityCenterPresentationState: CodexActivityCenterPresentationState
    let onUsageHeatmapHoverChange: (UsageHeatmapHoverContext?) -> Void
    let onResetCreditsTap: (ResetCreditsPanelContext) -> Void
    let onActivityCenterTap: (CodexActivityCenterPanelContext) -> Void
    @EnvironmentObject private var appUpdater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.verticalSpacing) {
            content
        }
        .padding(Metrics.padding)
        .liquidGlassSurface(cornerRadius: Metrics.surfaceCornerRadius, isOuterSurface: true)
        .animation(Metrics.statusAnimation, value: viewModel.loadState)
        .animation(Metrics.statusAnimation, value: codexHookSettings.isEnabled)
        .animation(Metrics.statusAnimation, value: mainPanelSettings.layout)
        .animation(Metrics.statusAnimation, value: syncSettings.isEnabled)
        .animation(Metrics.statusAnimation, value: syncSettings.isSyncing)
        .animation(Metrics.statusAnimation, value: syncSettings.hasSyncFailure)
    }
}

private extension CodexStatusMenuView {
    enum Metrics {
        static let padding: CGFloat = 12
        static let surfaceCornerRadius: CGFloat = 14
        static let verticalSpacing: CGFloat = 10
        static let statusAnimation = Animation.codexStatus
    }

    @ViewBuilder
    var content: some View {
        let visibleSections = mainPanelSettings.layout.visibleSections
        let dataPlaceholderSection = dataPlaceholderSection(in: visibleSections)

        ForEach(visibleSections) { section in
            sectionView(section, dataPlaceholderSection: dataPlaceholderSection)
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

    @ViewBuilder
    var activitySection: some View {
        if codexHookSettings.isEnabled {
            CodexActivityCard(
                activityMonitor: activityMonitor,
                presentationState: activityCenterPresentationState,
                keepAliveController: keepAliveController,
                showsUnavailableState: viewModel.snapshot == nil,
                onTaskCenterTap: { anchorProvider in
                    onActivityCenterTap(
                        CodexActivityCenterPanelContext(
                            anchorProvider: anchorProvider,
                            preferredSide: .right
                        )
                    )
                }
            )
        }
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
        } else if dataPlaceholderSection == .quota {
            EmptyDataPanel()
        }
    }

    @ViewBuilder
    func usageSection(dataPlaceholderSection: MainPanelSection?) -> some View {
        if let snapshot = viewModel.snapshot, let usage = snapshot.usage {
            UsageSummaryView(
                usage: usage,
                workflow: workflowViewModel.snapshot,
                showsWorkflow: codexHookSettings.isEnabled,
                isStale: snapshot.isUsageStale,
                onHoverContextChange: onUsageHeatmapHoverChange
            )
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
            viewModel.snapshot?.usage != nil
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
                codexHookSettings.isEnabled
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
            syncDisplayState: WorkflowSyncDisplayState(
                isHookEnabled: codexHookSettings.isEnabled,
                settings: syncSettings
            ),
            updateMessage: appUpdater.panelUpdateMessage,
            startUpdate: appUpdater.startUpdate
        )
    }
}
