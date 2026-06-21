import Combine
import SwiftUI

@MainActor
final class PopoverVisibilityState: ObservableObject {
    @Published var isVisible = false
}

struct CodexStatusMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + MenuMetrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth
    
    @ObservedObject var viewModel: CodexStatusViewModel
    @ObservedObject var workflowStatsViewModel: WorkflowStatsViewModel
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var popoverVisibility: PopoverVisibilityState
    @EnvironmentObject private var appUpdater: AppUpdater
    
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.verticalSpacing) {
            content
        }
        .padding(Metrics.padding)
        .liquidGlassSurface(cornerRadius: Metrics.surfaceCornerRadius, isOuterSurface: true)
        .animation(Metrics.statusAnimation, value: viewModel.loadState)
        .animation(Metrics.statusAnimation, value: codexHookSettings.isEnabled)
    }
}

private extension CodexStatusMenuView {
    enum Metrics {
        static let padding: CGFloat = 12
        static let panelPadding: CGFloat = 10
        static let surfaceCornerRadius: CGFloat = 14
        static let panelCornerRadius: CGFloat = 8
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
            
            dataSection(snapshot)
        } else {
            // 仅展示未登录 / 初始化失败两种特殊状态, 其余错误只进日志
            StatusAccountCard(
                loadState: viewModel.loadState,
                isRefreshing: viewModel.isRefreshing,
                onRefresh: viewModel.refresh
            )
            EmptyDataPanel()
        }
    }
    
    @ViewBuilder
    func dataSection(_ snapshot: CodexQuotaSnapshot) -> some View {
        if snapshot.limits.isEmpty, snapshot.usage == nil {
            EmptyDataPanel()
        } else {
            if !snapshot.limits.isEmpty {
                QuotaLimitsSection(limits: snapshot.limits, isStale: snapshot.isRateLimitsStale)
            }
            
            if let usage = snapshot.usage {
                UsageSummaryView(
                    usage: usage,
                    workflowStats: workflowStatsViewModel.snapshot,
                    showsWorkflowStats: codexHookSettings.isEnabled,
                    isStale: snapshot.isUsageStale
                )
            }
        }
        
        updatedAtRow(for: snapshot)
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 7)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
    }
    
    func updatedAtRow(for snapshot: CodexQuotaSnapshot) -> some View {
        UpdatedAtRow(
            snapshot: snapshot,
            countdownStartedAt: viewModel.autoRefreshCountdownStartedAt ?? snapshot.generatedAt,
            countdownInterval: viewModel.autoRefreshInterval,
            isCountdownActive: popoverVisibility.isVisible,
            updateMessage: appUpdater.panelUpdateMessage,
            startUpdate: appUpdater.startUpdate
        )
    }
}
