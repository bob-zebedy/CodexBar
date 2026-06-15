//
//  AppSettingsView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-14.
//

import AppKit
import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var rateLimitsViewModel: RateLimitsViewModel
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var loginItemSettings = LoginItemSettings()
    @StateObject private var codexVersions = CodexCLIVersionViewModel()
    @State private var copiedPathResetTasks: [CodexCLIExecutableSource: Task<Void, Never>] = [:]
    
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                launchAtLoginRow
                LiquidGlassDivider()
                automaticUpdateCheckRow
                LiquidGlassDivider()
                versionRow
                LiquidGlassDivider()
                codexVersionSection
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
            
            HStack(alignment: .center, spacing: 12) {
                quitButton
                statusText
                Spacer()
                checkUpdateButton
            }
            .animation(Metrics.statusAnimation, value: loginItemSettings.errorMessage)
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .red)
        }
        .padding(Metrics.padding)
        .frame(width: Metrics.windowWidth)
        .liquidGlassSurface(
            cornerRadii: RectangleCornerRadii(
                topLeading: 0,
                bottomLeading: Metrics.surfaceCornerRadius,
                bottomTrailing: Metrics.surfaceCornerRadius,
                topTrailing: 0
            ),
            tint: .cyan,
            isOuterSurface: true
        )
        .onAppear {
            loginItemSettings.refresh()
            appUpdater.refreshAutomaticCheckSetting()
            refreshCodexVersionSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCodexVersionSection()
        }
        .onDisappear {
            copiedPathResetTasks.values.forEach { $0.cancel() }
        }
    }
}

private extension AppSettingsView {
    enum Metrics {
        static let padding: CGFloat = 20
        static let windowWidth: CGFloat = 430
        static let sectionSpacing: CGFloat = 18
        static let rowSpacing: CGFloat = 14
        static let panelPadding: CGFloat = 12
        static let surfaceCornerRadius: CGFloat = 16
        static let panelCornerRadius: CGFloat = 10
        static let iconWidth: CGFloat = 18
        static let codexChildIndent: CGFloat = 28
        static let codexVersionColumnWidth: CGFloat = 270
        static let statusAnimation = Animation.codexStatus
    }
    
    var launchAtLoginRow: some View {
        settingsToggleRow(
            icon: "power",
            title: "开机自动启动",
            isOn: Binding(
                get: { loginItemSettings.isEnabled },
                set: { loginItemSettings.setEnabled($0) }
            )
        )
    }
    
    var automaticUpdateCheckRow: some View {
        settingsToggleRow(
            icon: "arrow.triangle.2.circlepath",
            title: "自动检查更新",
            isOn: Binding(
                get: { appUpdater.automaticallyChecksForUpdates },
                set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
            ),
            isEnabled: appUpdater.canConfigureAutomaticChecks
        )
    }
    
    func settingsToggleRow(
        icon: String,
        title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.tint)
            
            Text(title)
            
            Spacer()
            
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
    }
    
    var versionRow: some View {
        let status = versionStatus
        
        return HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.secondary)
            
            Text("CodexBar 版本")
            
            Spacer()
            
            Text(status.text)
                .font(status.isVersionLabel ? .body.monospacedDigit() : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(Metrics.statusAnimation, value: status.text)
            
            if appUpdater.availableUpdateMessage != nil {
                Button {
                    appUpdater.startUpdate()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .imageScale(.large)
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("立即更新")
                .transition(.opacity)
            }
        }
        .animation(Metrics.statusAnimation, value: appUpdater.availableUpdateMessage != nil)
    }
    
    /// 版本行文案;无任何动态消息时回退到版本号 (此时用等宽数字)
    var versionStatus: (text: String, isVersionLabel: Bool) {
        if let message = appUpdater.settingsStatusMessage ?? appUpdater.availableUpdateMessage {
            return (message, false)
        }
        return (Bundle.main.displayVersionLabel, true)
    }
    
    var codexVersionSection: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "number.circle")
                    .frame(width: Metrics.iconWidth)
                    .foregroundStyle(.secondary)
                
                Text("Codex 版本")
                
                Spacer()
            }
            
            LiquidGlassDivider()
                .padding(.leading, Metrics.iconWidth + 10)
            
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                codexVersionRow(icon: "terminal", item: codexVersions.snapshot.global)
                
                codexVersionRow(icon: "app.badge", item: codexVersions.snapshot.bundled)
            }
            .padding(.leading, Metrics.codexChildIndent)
        }
    }
    
    func refreshCodexVersionSection() {
        // 版本探测是慢路径且自带并发合并; 连接信息只是一次缓存读取, 顺带刷新
        codexVersions.refresh()
        rateLimitsViewModel.refreshCodexConnectionInfo()
    }
    
    func codexVersionRow(icon: String, item: CodexCLIVersionItem) -> some View {
        let row = CodexCLIVersionDisplay(item: item, connection: rateLimitsViewModel.codexConnectionInfo)
        let isPathCopied = copiedPathResetTasks[item.source] != nil
        
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.tertiary)
            
            Text(item.source.displayName)
                .foregroundStyle(.secondary)
            
            Spacer(minLength: 28)
            
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 12) {
                    if row.isCurrent {
                        Text("当前使用")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .liquidGlassCapsule(tint: .green)
                            .transition(.opacity)
                    }
                    
                    Text(row.displayVersion)
                        .font(row.hasVersion ? .body.monospacedDigit() : .body)
                        .foregroundStyle(row.hasVersion ? .secondary : .tertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .animation(Metrics.statusAnimation, value: row.displayVersion)
                }
                .animation(Metrics.statusAnimation, value: row.isCurrent)
                
                if let newerInstalledVersion = row.newerInstalledVersion {
                    Text("已更新至 \(newerInstalledVersion)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                
                if let path = row.path {
                    copiedPathText(path: path, isCopied: isPathCopied)
                        .animation(Metrics.statusAnimation, value: isPathCopied)
                        .help(isPathCopied ? "已复制" : "点击复制")
                        .onTapGesture {
                            copyPathToPasteboard(path, source: item.source)
                        }
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: Metrics.codexVersionColumnWidth, alignment: .trailing)
            .animation(Metrics.statusAnimation, value: row.newerInstalledVersion)
            .animation(Metrics.statusAnimation, value: row.path)
        }
    }
    
    func copiedPathText(path: String, isCopied: Bool) -> some View {
        ZStack(alignment: .trailing) {
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .opacity(isCopied ? 0 : 1)
            
            Text("已复制")
                .font(.caption2)
                .foregroundStyle(.green)
                .lineLimit(1)
                .opacity(isCopied ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    
    func copyPathToPasteboard(_ path: String, source: CodexCLIExecutableSource) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        
        copiedPathResetTasks[source]?.cancel()
        copiedPathResetTasks[source] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            
            copiedPathResetTasks[source] = nil
        }
    }
    
    @ViewBuilder
    var statusText: some View {
        if let message = loginItemSettings.errorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
    
    var checkUpdateButton: some View {
        Button {
            appUpdater.checkForUpdates()
        } label: {
            Label("检查更新", systemImage: "arrow.down.circle")
        }
    }
    
    var quitButton: some View {
        Button(role: .destructive) {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("退出 CodexBar", systemImage: "power.circle")
        }
        .foregroundStyle(.red)
        .keyboardShortcut("q")
    }
}
