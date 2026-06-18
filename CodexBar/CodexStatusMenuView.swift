import Combine
import SwiftUI

@MainActor
final class PopoverVisibilityState: ObservableObject {
    @Published var isVisible = false
}

struct CodexStatusMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + Metrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth

    @ObservedObject var viewModel: CodexStatusViewModel
    @ObservedObject var popoverVisibility: PopoverVisibilityState
    @EnvironmentObject private var appUpdater: AppUpdater
    @State private var isEmailBlurred = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.verticalSpacing) {
            content
        }
        .padding(Metrics.padding)
        .liquidGlassSurface(cornerRadius: Metrics.surfaceCornerRadius, tint: .cyan, isOuterSurface: true)
        .animation(Metrics.statusAnimation, value: viewModel.loadState)
        .onChange(of: viewModel.snapshot?.account.email) { _, _ in
            isEmailBlurred = false
        }
    }
}

private extension CodexStatusMenuView {
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
        if let snapshot = viewModel.snapshot {
            accountCard(
                title: snapshot.accountLabel,
                isEmail: snapshot.account.hasEmail,
                plan: snapshot.planLabel
            )

            dataSection(snapshot)
        } else {
            // 仅展示未登录 / 初始化失败两种特殊状态, 其余错误只进日志
            statusAccountCard
            emptyView
                .padding(Metrics.panelPadding)
                .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
        }
    }

    @ViewBuilder
    func dataSection(_ snapshot: CodexQuotaSnapshot) -> some View {
        if snapshot.limits.isEmpty, snapshot.usage == nil {
            emptyView
                .padding(Metrics.panelPadding)
                .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
        } else {
            if !snapshot.limits.isEmpty {
                quotaLimitsView(snapshot.limits)
            }

            if let usage = snapshot.usage {
                UsageSummaryView(usage: usage)
            }
        }

        updatedAtRow(for: snapshot)
            .padding(.horizontal, Metrics.panelPadding)
            .padding(.vertical, 7)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .mint)
    }

    var statusAccountCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: Metrics.accountIconSize, weight: .medium))
                .foregroundStyle(statusDisplay.color)
                .onTapGesture(count: 2) {
                    viewModel.refresh()
                }

            if let text = statusDisplay.text {
                Text(text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusDisplay.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }

            Spacer()
        }
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.vertical, 8)
        .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
    }

    var statusDisplay: (text: String?, color: Color) {
        switch viewModel.loadState {
        case .notLoggedIn:
            return ("未登录", .orange)
        case .initializationFailed:
            return ("初始化失败", .red)
        case .loading, .loaded:
            return (nil, .accentColor)
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

    func planBadgeTint(for plan: String) -> Color {
        let normalizedPlan = plan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.planTintRules.first { rule in
            rule.keywords.contains { normalizedPlan.contains($0) }
        }?.tint ?? .cyan
    }

    static let planTintRules: [(keywords: [String], tint: Color)] = [
        (["enterprise"], .green),
        (["team", "business"], .orange),
        (["pro"], .purple),
        (["plus"], .blue),
        (["edu"], .teal),
        (["free"], .secondary)
    ]

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
        // 只让刷新起点变化触发动画, 避免每秒 tick 被补间
        .animation(isActive ? .linear(duration: Metrics.resetAnimationDuration) : nil, value: startedAt)
    }

    private enum Metrics {
        static let resetAnimationDuration: TimeInterval = 0.50
    }
}
