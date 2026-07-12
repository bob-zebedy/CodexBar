import Combine
import SwiftUI

/// 菜单面板可见状态，用于控制逐秒时间更新。
@MainActor
final class MenuSurfaceVisibilityState: ObservableObject {
    @Published var isVisible = false
}

/// 菜单栏弹出面板根视图, 汇总账号、实时活动、额度、token、同步状态和更新时间
struct CodexStatusMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + MenuMetrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth

    @ObservedObject var viewModel: CodexStatusViewModel
    @ObservedObject var workflowViewModel: WorkflowViewModel
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var activityMonitor: CodexActivityMonitor
    @ObservedObject var syncSettings: WorkflowSyncSettings
    @ObservedObject var menuSurfaceVisibility: MenuSurfaceVisibilityState
    @ObservedObject var activityCenterPresentationState: CodexActivityCenterPresentationState
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
        if let snapshot = viewModel.snapshot {
            AccountCard(
                title: snapshot.accountLabel,
                isEmail: snapshot.account.hasEmail,
                plan: snapshot.planLabel,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: viewModel.refresh
            )

            activityCard

            dataSection(snapshot)
        } else {
            // 仅展示未登录 / 初始化失败两种特殊状态, 其余错误只进日志
            StatusAccountCard(
                loadState: viewModel.loadState,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: viewModel.refresh
            )
            activityCard
            EmptyDataPanel()
        }
    }

    @ViewBuilder
    var activityCard: some View {
        if codexHookSettings.isEnabled {
            let hasQuotaSnapshot = viewModel.snapshot != nil
            CodexActivityCard(
                activityMonitor: activityMonitor,
                timelineDate: activityCenterPresentationState.timelineDate,
                showsUnavailableState: !hasQuotaSnapshot,
                isTaskCenterPresented: activityCenterPresentationState.isPresented,
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
    func dataSection(_ snapshot: CodexQuotaSnapshot) -> some View {
        if snapshot.limits.isEmpty, snapshot.usage == nil {
            EmptyDataPanel()
        } else {
            if !snapshot.limits.isEmpty {
                QuotaLimitsSection(
                    limits: snapshot.limits,
                    resetCreditsAvailableCount: snapshot.resetCreditsAvailableCount,
                    resetCreditExpirationDates: snapshot.resetCreditExpirationDates,
                    isStale: snapshot.isRateLimitsStale,
                    onResetCreditsTap: onResetCreditsTap
                )
            }

            if let usage = snapshot.usage {
                UsageSummaryView(
                    usage: usage,
                    workflow: workflowViewModel.snapshot,
                    showsWorkflow: codexHookSettings.isEnabled,
                    isStale: snapshot.isUsageStale,
                    onHoverContextChange: onUsageHeatmapHoverChange
                )
            }
        }

        updatedAtRow(for: snapshot)
            .padding(.horizontal, MenuMetrics.panelPadding)
            .padding(.vertical, 7)
            .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
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
