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
            errorView(viewModel.errorMessage)
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
        if let snapshot = viewModel.snapshot {
            accountRow(title: snapshot.accountLabel, plan: snapshot.planLabel)
            
            VStack(spacing: 8) {
                QuotaRow(window: snapshot.fiveHour)
                QuotaRow(window: snapshot.weekly)
            }
            
            updatedAtRow(for: snapshot)
        } else if viewModel.isRefreshing {
            accountRow(title: "Codex")
            loadingView
        } else {
            accountRow(title: "Codex")
            emptyView
        }
    }
    
    @ViewBuilder
    var controls: some View {
        if showsControls {
            Divider()
            controlsRow
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
    
    var controlsRow: some View {
        HStack {
            loginItemToggle
            
            Spacer()
            
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
    
    var loginItemToggle: some View {
        Toggle(
            "开机启动",
            isOn: Binding(
                get: { loginItemSettings.isEnabled },
                set: { loginItemSettings.setEnabled($0) }
            )
        )
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

#Preview {
    let viewModel = RateLimitsViewModel()
    return RateLimitsMenuView(viewModel: viewModel)
        .frame(width: RateLimitsMenuView.menuWidth)
}
