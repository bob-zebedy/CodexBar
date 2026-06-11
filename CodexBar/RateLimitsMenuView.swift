//
//  RateLimitsMenuView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import AppKit
import SwiftUI

struct RateLimitsMenuView: View {
    static let menuWidth: CGFloat = 360
    
    @ObservedObject var viewModel: RateLimitsViewModel
    @StateObject private var loginItemSettings = LoginItemSettings()
    @State private var showsControls = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.verticalSpacing) {
            content
            // 未登录已有专属橙色提示, 不再重复显示同文案的红色错误行
            errorView(viewModel.requiresLogin ? nil : viewModel.errorMessage)
            errorView(loginItemSettings.errorMessage)
            controls
        }
        .padding(Metrics.padding)
        .onAppear {
            viewModel.refreshIfNeeded()
            loginItemSettings.refresh()
            showsControls = NSEvent.modifierFlags.contains(.option)
        }
    }
}

private extension RateLimitsMenuView {
    enum Metrics {
        static let padding: CGFloat = 12
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
                accountRow(title: snapshot.accountLabel, plan: snapshot.planLabel)
                
                VStack(spacing: 8) {
                    QuotaRow(window: snapshot.fiveHour)
                    QuotaRow(window: snapshot.weekly)
                }
                
                if let usage = snapshot.usage {
                    UsageSummaryView(usage: usage)
                }
                
                updatedAtRow(for: snapshot)
            }
            // 未登录时旧数据已过期, 置灰提示不可信
            .opacity(viewModel.requiresLogin ? 0.4 : 1)
        } else if viewModel.isRefreshing {
            accountRow(title: "Codex")
            loadingView
        } else {
            accountRow(title: "Codex")
            emptyView
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
    
    @ViewBuilder
    var controls: some View {
        if showsControls {
            Divider()
            settingsView
        }
    }
    
    var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            
            Text("正在获取数据")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Metrics.loadingVerticalPadding)
    }
    
    var emptyView: some View {
        Text("暂无数据")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Metrics.loadingVerticalPadding)
    }
    
    func accountRow(title: String, plan: String? = nil) -> some View {
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
            
            if viewModel.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }
            
            Spacer()
            
            if let plan {
                Text(plan.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
        }
    }
    
    func updatedAtRow(for snapshot: CodexQuotaSnapshot) -> some View {
        HStack {
            Text("更新时间 \(snapshot.generatedAt, formatter: Self.timeFormatter)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            Spacer()
        }
    }
    
    var settingsView: some View {
        HStack {
            loginItemToggle
            
            Spacer()
            
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .foregroundStyle(.red)
            .keyboardShortcut("q")
        }
    }
    
    var loginItemToggle: some View {
        settingsToggle(
            "开机自动启动",
            isEnabled: loginItemSettings.isEnabled,
            setEnabled: { loginItemSettings.setEnabled($0) }
        )
    }
    
    func settingsToggle(
        _ title: String,
        isEnabled: Bool,
        setEnabled: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(title, isOn: Binding(get: { isEnabled }, set: setEnabled))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)
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
    
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot
    private let recentDays: [CodexUsageSnapshot.Day]
    @State private var hoveredDay: CodexUsageSnapshot.Day?
    
    init(usage: CodexUsageSnapshot) {
        self.usage = usage
        self.recentDays = usage.recentDays(count: 14, endingDaysAgo: 1)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            
            HStack(alignment: .firstTextBaseline) {
                metric(label: "单日峰值", value: usage.summary.peakDailyTokens, alignment: .leading)
                Spacer()
                hoveredMetric
                Spacer()
                metric(label: "全时累计", value: usage.summary.lifetimeTokens, alignment: .trailing)
            }
            
            UsageBarChart(days: recentDays, hoveredDay: $hoveredDay)
        }
        .onAppear {
            hoveredDay = nil
        }
    }
    
    var hoveredMetric: some View {
        VStack(spacing: 2) {
            Text(hoveredDateText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            
            Text(hoveredTokensText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .opacity(hoveredDay == nil ? 0 : 1)
        .frame(width: 112, alignment: .center)
    }
    
    private var hoveredDateText: String {
        hoveredDay?.startDate ?? " "
    }
    
    private var hoveredTokensText: String {
        guard let hoveredDay else {
            return " "
        }
        
        return TokenCountFormatter.string(from: hoveredDay.tokens)
    }
    
    private func metric(label: String, value: Int, alignment: Alignment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: alignment)
            
            Text(TokenCountFormatter.string(from: value))
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .frame(width: 96)
    }
}

private struct UsageBarChart: View {
    let days: [CodexUsageSnapshot.Day]
    @Binding var hoveredDay: CodexUsageSnapshot.Day?
    
    private var peakTokens: Int {
        max(days.map(\.tokens).max() ?? 0, 1)
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { day in
                UsageBar(
                    day: day,
                    percent: Double(day.tokens) / Double(peakTokens),
                    isHovered: hoveredDay?.id == day.id
                )
                .onHover { isHovering in
                    if isHovering {
                        hoveredDay = day
                    } else if hoveredDay?.id == day.id {
                        hoveredDay = nil
                    }
                }
            }
        }
        .frame(height: 58)
    }
}

private struct UsageBar: View {
    let day: CodexUsageSnapshot.Day
    let percent: Double
    let isHovered: Bool
    
    var body: some View {
        GeometryReader { proxy in
            let barHeight = max(day.tokens > 0 ? 2 : 0, proxy.size.height * clampedPercent)
            
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(.secondary.opacity(isHovered ? 0.20 : 0.12))
                
                Rectangle()
                    .fill(Color.orange.opacity(day.tokens > 0 ? barOpacity : 0))
                    .frame(height: barHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
    
    private var clampedPercent: Double {
        min(max(percent, 0), 1)
    }
    
    private var barOpacity: Double {
        let opacity = 0.28 + clampedPercent * 0.62
        return isHovered ? min(opacity + 0.10, 1.0) : opacity
    }
}

private enum TokenCountFormatter {
    static func string(from tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return decimal(Double(tokens) / 1_000_000_000) + "B"
        }
        
        return decimal(Double(tokens) / 1_000_000) + "M"
    }
    
    private static func decimal(_ value: Double) -> String {
        let rounded = value >= 0.1 ? (value * 10).rounded() / 10 : (value * 100).rounded() / 100
        return formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.1f", rounded)
    }
    
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

#Preview {
    let viewModel = RateLimitsViewModel()
    return RateLimitsMenuView(viewModel: viewModel)
        .frame(width: RateLimitsMenuView.menuWidth)
}
