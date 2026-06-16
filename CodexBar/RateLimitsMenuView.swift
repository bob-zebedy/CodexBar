//
//  RateLimitsMenuView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Combine
import SwiftUI

@MainActor
final class PopoverVisibilityState: ObservableObject {
    @Published var isVisible = false
}

struct RateLimitsMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + Metrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth
    
    @ObservedObject var viewModel: RateLimitsViewModel
    @ObservedObject var popoverVisibility: PopoverVisibilityState
    @EnvironmentObject private var appUpdater: AppUpdater
    @State private var isEmailBlurred = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.verticalSpacing) {
            content
            // 未登录已有专属橙色提示, 不再重复显示同文案的红色错误行
            errorView(viewModel.requiresLogin ? nil : viewModel.errorMessage)
        }
        .padding(Metrics.padding)
        .liquidGlassSurface(cornerRadius: Metrics.surfaceCornerRadius, tint: .cyan, isOuterSurface: true)
        .animation(Metrics.statusAnimation, value: viewModel.requiresLogin)
        .animation(Metrics.statusAnimation, value: viewModel.errorMessage)
        .onChange(of: viewModel.snapshot?.account.email) { _, _ in
            isEmailBlurred = false
        }
    }
}

private extension RateLimitsMenuView {
    enum Metrics {
        static let padding: CGFloat = 12
        static let panelPadding: CGFloat = 10
        static let surfaceCornerRadius: CGFloat = 14
        static let panelCornerRadius: CGFloat = 8
        static let verticalSpacing: CGFloat = 10
        static let accountIconSize: CGFloat = 14
        static let loadingVerticalPadding: CGFloat = 16
        static let statusAnimation = Animation.codexStatus
    }
    
    @ViewBuilder
    var content: some View {
        if viewModel.requiresLogin {
            loginRequiredNotice
                .transition(.opacity)
        }
        
        if let snapshot = viewModel.snapshot {
            Group {
                accountCard(
                    title: snapshot.accountLabel,
                    isEmail: snapshot.account.hasEmail,
                    plan: snapshot.planLabel
                )
                
                quotaLimitsView(snapshot.limits)
                
                if let usage = snapshot.usage {
                    UsageSummaryView(usage: usage)
                }
                
                updatedAtRow(for: snapshot)
                    .padding(.horizontal, Metrics.panelPadding)
                    .padding(.vertical, 7)
                    .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .mint)
            }
            // 未登录时旧数据已过期, 置灰提示不可信
            .opacity(viewModel.requiresLogin ? 0.4 : 1)
        } else {
            accountCard(title: "")
            emptyView
                .padding(Metrics.panelPadding)
                .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
        }
    }
    
    var loginRequiredNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            
            Text("Codex 未登录")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
    }
    
    var emptyView: some View {
        Text("暂无数据")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Metrics.loadingVerticalPadding)
    }
    
    func quotaLimitsView(_ limits: [CodexQuotaLimitSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(limits) { limit in
                if limit.id != limits.first?.id {
                    LiquidGlassDivider()
                }
                
                quotaLimitSection(limit)
            }
        }
        .padding(Metrics.panelPadding)
        .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .green)
    }
    
    func quotaLimitSection(_ limit: CodexQuotaLimitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(limit.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            VStack(spacing: 8) {
                ForEach(limit.windows) { window in
                    QuotaRow(window: window)
                }
            }
        }
    }
    
    func accountCard(title: String, isEmail: Bool = false, plan: String? = nil) -> some View {
        accountRow(title: title, isEmail: isEmail, plan: plan)
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 8)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
    }
    
    func accountRow(title: String, isEmail: Bool = false, plan: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: Metrics.accountIconSize, weight: .medium))
                .foregroundStyle(.tint)
                .onTapGesture(count: 2) {
                    viewModel.refresh()
                }
            
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .blur(radius: isEmail && isEmailBlurred ? 3 : 0)
                .animation(.snappy(duration: 0.18), value: isEmailBlurred)
                .onTapGesture(count: 2) {
                    guard isEmail else { return }
                    isEmailBlurred.toggle()
                }
            
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }
            
            Spacer()
            
            if let plan {
                let tint = planBadgeTint(for: plan)
                
                Text(plan.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
    }
    
    func updatedAtRow(for snapshot: CodexQuotaSnapshot) -> some View {
        HStack {
            HStack(spacing: 5) {
                AutoRefreshCountdownTimeline(
                    startedAt: viewModel.autoRefreshCountdownStartedAt ?? snapshot.generatedAt,
                    interval: viewModel.autoRefreshInterval,
                    isActive: popoverVisibility.isVisible,
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
            
            if let message = appUpdater.panelUpdateMessage {
                Text(message)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .transition(.opacity)
                    .onTapGesture(count: 2) {
                        appUpdater.startUpdate()
                    }
            }
        }
        .animation(Metrics.statusAnimation, value: appUpdater.panelUpdateMessage)
    }
    
    @ViewBuilder
    func errorView(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .transition(.opacity)
        }
    }
    
    func planBadgeTint(for plan: String) -> Color {
        let normalizedPlan = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if normalizedPlan.contains("enterprise") {
            return .green
        }
        
        if normalizedPlan.contains("team") || normalizedPlan.contains("business") {
            return .orange
        }
        
        if normalizedPlan.contains("pro") {
            return .purple
        }
        
        if normalizedPlan.contains("plus") {
            return .blue
        }
        
        if normalizedPlan.contains("edu") {
            return .teal
        }
        
        if normalizedPlan.contains("free") {
            return .secondary
        }
        
        return .cyan
    }
    
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    static let secondaryTextColor = Color.codexSecondaryLabel
}

private struct AutoRefreshCountdownTimeline: View {
    let startedAt: Date
    let interval: TimeInterval
    let isActive: Bool
    let color: Color
    
    var body: some View {
        if isActive {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                circle(now: timeline.date)
            }
        } else {
            circle(now: Date())
        }
    }
    
    private func circle(now: Date) -> AutoRefreshCountdownCircle {
        AutoRefreshCountdownCircle(
            startedAt: startedAt,
            interval: interval,
            now: now,
            isActive: isActive,
            color: color
        )
    }
}

private struct AutoRefreshCountdownCircle: View {
    let startedAt: Date
    let interval: TimeInterval
    let now: Date
    let isActive: Bool
    let color: Color
    
    private var progress: Double {
        guard interval > 0 else {
            return 0
        }
        
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        return max(0, 1 - elapsed / interval)
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 1.4)
            
            Circle()
                .trim(from: 1 - progress, to: 1)
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 8, height: 8)
        // 仅在 startedAt 变化(刷新重置)时播放恢复动画; 普通 tick 只改 now/progress, 直接跳变。
        // popover 隐藏(isActive == false)时不开启动画事务, 避免不可见状态下的无谓渲染。
        .animation(isActive ? .linear(duration: Metrics.resetAnimationDuration) : nil, value: startedAt)
    }
    
    private enum Metrics {
        static let resetAnimationDuration: TimeInterval = 0.50
    }
}
