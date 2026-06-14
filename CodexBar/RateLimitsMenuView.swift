//
//  RateLimitsMenuView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import SwiftUI

struct RateLimitsMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + Metrics.panelPadding * 2 + UsageHeatmap.Metrics.totalWidth

    @ObservedObject var viewModel: RateLimitsViewModel
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
    }

    @ViewBuilder
    var content: some View {
        if viewModel.requiresLogin {
            loginRequiredNotice
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
                    .font(.caption2)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .liquidGlassCapsule(tint: tint)
            }
        }
    }

    func updatedAtRow(for snapshot: CodexQuotaSnapshot) -> some View {
        HStack {
            Text("数据更新时间 \(snapshot.generatedAt, formatter: Self.timeFormatter)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if let message = appUpdater.panelUpdateMessage {
                Text(message)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        appUpdater.startUpdate()
                    }
            }
        }
    }

    @ViewBuilder
    func errorView(_ message: String?) -> some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
}
