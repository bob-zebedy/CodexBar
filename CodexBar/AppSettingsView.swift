//
//  AppSettingsView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-14.
//

import AppKit
import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var loginItemSettings = LoginItemSettings()
    
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                launchAtLoginRow
                LiquidGlassDivider()
                automaticUpdateCheckRow
                LiquidGlassDivider()
                versionRow
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius, tint: .cyan)
            
            HStack(alignment: .center, spacing: 12) {
                quitButton
                statusText
                Spacer()
                checkUpdateButton
            }
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
        }
    }
}

private extension AppSettingsView {
    enum Metrics {
        static let padding: CGFloat = 20
        static let windowWidth: CGFloat = 380
        static let sectionSpacing: CGFloat = 18
        static let rowSpacing: CGFloat = 14
        static let panelPadding: CGFloat = 12
        static let surfaceCornerRadius: CGFloat = 16
        static let panelCornerRadius: CGFloat = 10
        static let iconWidth: CGFloat = 18
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
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .frame(width: Metrics.iconWidth)
                .foregroundStyle(.secondary)
            
            Text("当前 APP 版本")
            
            Spacer()
            
            Text(versionStatus.text)
                .font(versionStatus.isVersionLabel ? .body.monospacedDigit() : .body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
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
                .accessibilityLabel("立即更新")
            }
        }
    }
    
    /// 版本行文案;无任何动态消息时回退到版本号(此时用等宽数字)
    var versionStatus: (text: String, isVersionLabel: Bool) {
        if let message = appUpdater.settingsStatusMessage ?? appUpdater.availableUpdateMessage {
            return (message, false)
        }
        return (Bundle.main.displayVersionLabel, true)
    }
    
    @ViewBuilder
    var statusText: some View {
        if let message = loginItemSettings.errorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
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
