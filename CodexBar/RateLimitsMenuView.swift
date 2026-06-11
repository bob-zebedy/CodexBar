//
//  RateLimitsMenuView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import AppKit
import SwiftUI

struct RateLimitsMenuView: View {
    static let menuWidth: CGFloat = Metrics.padding * 2 + UsageHeatmap.Metrics.totalWidth
    
    @ObservedObject var viewModel: RateLimitsViewModel
    @EnvironmentObject private var appUpdater: AppUpdater
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
            
            Text(appUpdater.statusMessage ?? Self.appVersionLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    appUpdater.checkForUpdates()
                }
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
    
    static let appVersionLabel: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "--"
        return "App 版本: v\(version)"
    }()
}

private struct UsageSummaryView: View {
    let usage: CodexUsageSnapshot
    private let days: [CodexUsageSnapshot.Day]
    @State private var hoveredDay: CodexUsageSnapshot.Day?
    
    init(usage: CodexUsageSnapshot) {
        self.usage = usage
        self.days = usage.recentDays(count: UsageHeatmap.Metrics.dayCount, endingDaysAgo: 1)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            
            HStack(alignment: .firstTextBaseline) {
                metric(label: "单日峰值", value: usage.summary.peakDailyTokens, alignment: .leading)
                Spacer()
                metric(label: "全时累计", value: usage.summary.lifetimeTokens, alignment: .trailing)
            }
            
            UsageHeatmap(days: days, hoveredDay: $hoveredDay)
        }
        .onAppear {
            hoveredDay = nil
        }
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

private struct UsageHeatmap: View {
    let days: [CodexUsageSnapshot.Day]
    @Binding var hoveredDay: CodexUsageSnapshot.Day?
    @State private var hoverLocation: CGPoint = .zero
    
    private var peakTokens: Int {
        max(days.lazy.map(\.tokens).max() ?? 0, 1)
    }
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            heatmapGrid
            
            if let hoveredDay {
                UsageHeatmapTooltip(day: hoveredDay)
                    .allowsHitTesting(false)
                    .offset(tooltipOffset)
                    .zIndex(1)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .frame(height: Metrics.height)
        .coordinateSpace(name: Metrics.coordinateSpaceName)
        .animation(.snappy(duration: 0.16), value: hoveredDay?.id)
    }
    
    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 \(days.count) 天")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                if let firstDate = days.first?.startDate, let lastDate = days.last?.startDate {
                    Text("\(firstDate) ~ \(lastDate)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            
            HStack(alignment: .top, spacing: Metrics.squareSpacing) {
                ForEach(0..<Metrics.columnCount, id: \.self) { column in
                    VStack(spacing: Metrics.squareSpacing) {
                        ForEach(0..<Metrics.rowCount, id: \.self) { row in
                            let index = column * Metrics.rowCount + row
                            
                            if days.indices.contains(index) {
                                let day = days[index]
                                UsageHeatmapSquare(
                                    day: day,
                                    percent: Double(day.tokens) / Double(peakTokens),
                                    isHovered: hoveredDay?.id == day.id
                                ) { hoveredDay, location in
                                    self.hoveredDay = hoveredDay
                                    hoverLocation = location
                                } onEnded: { day in
                                    if self.hoveredDay?.id == day.id {
                                        self.hoveredDay = nil
                                    }
                                }
                            } else {
                                Color.clear
                                    .frame(width: Metrics.squareSize, height: Metrics.squareSize)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var tooltipOffset: CGSize {
        CGSize(
            width: min(max(hoverLocation.x + 10, 0), max(0, Metrics.totalWidth - Metrics.tooltipWidth)),
            height: min(max(hoverLocation.y + 12, 0), max(0, Metrics.height - Metrics.tooltipHeight))
        )
    }
}

private extension UsageHeatmap {
    enum Metrics {
        static let coordinateSpaceName = "usageHeatmap"
        static let columnCount = 30
        static let rowCount = 7
        static let squareSize: CGFloat = 12
        static let squareSpacing: CGFloat = 3
        static let height: CGFloat = 120
        static let tooltipWidth: CGFloat = 78
        static let tooltipHeight: CGFloat = 38
        
        static var dayCount: Int { columnCount * rowCount }
        
        static var totalWidth: CGFloat {
            CGFloat(columnCount) * squareSize + CGFloat(columnCount - 1) * squareSpacing
        }
    }
}

private struct UsageHeatmapSquare: View {
    let day: CodexUsageSnapshot.Day
    let percent: Double
    let isHovered: Bool
    let onActive: (CodexUsageSnapshot.Day, CGPoint) -> Void
    let onEnded: (CodexUsageSnapshot.Day) -> Void
    
    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(fillColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(borderColor, lineWidth: isHovered ? 1.2 : 0.7)
                }
                .shadow(color: .blue.opacity(0.22), radius: isHovered ? 5 : 0, y: isHovered ? 2 : 0)
                .scaleEffect(isHovered ? 1.08 : 1)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let frame = proxy.frame(in: .named(UsageHeatmap.Metrics.coordinateSpaceName))
                        onActive(day, CGPoint(x: frame.minX + location.x, y: frame.minY + location.y))
                    case .ended:
                        onEnded(day)
                    }
                }
        }
        .frame(width: UsageHeatmap.Metrics.squareSize, height: UsageHeatmap.Metrics.squareSize)
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .animation(.snappy(duration: 0.14), value: isHovered)
    }
    
    private var clampedPercent: Double {
        min(max(percent, 0), 1)
    }
    
    private var fillColor: Color {
        guard day.tokens > 0 else {
            return Color.blue.opacity(isHovered ? 0.16 : 0.08)
        }
        
        let intensity = pow(clampedPercent, 0.62)
        let opacity = 0.18 + intensity * 0.68
        return Color.blue.opacity(isHovered ? min(opacity + 0.10, 1.0) : opacity)
    }
    
    private var borderColor: Color {
        if isHovered {
            return Color.blue.opacity(0.78)
        }
        
        return Color.blue.opacity(day.tokens > 0 ? 0.18 : 0.10)
    }
}

private struct UsageHeatmapTooltip: View {
    let day: CodexUsageSnapshot.Day
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.startDate)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            
            Text(TokenCountFormatter.string(from: day.tokens))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: UsageHeatmap.Metrics.tooltipWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
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
