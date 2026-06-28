import AppKit
import SwiftUI

/// 设置窗口根视图, 汇总启动项、更新、Hook、跨设备同步、快捷键和版本信息
struct AppSettingsView: View {
    @EnvironmentObject private var statusViewModel: CodexStatusViewModel
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var loginItemSettings = LoginItemSettings()
    @StateObject private var codexVersions = CodexCLIVersionViewModel()
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var syncSettings: WorkflowSyncSettings
    @ObservedObject var globalHotKeySettings: GlobalHotKeySettings
    let onSyncChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                launchAtLoginRow
                LiquidGlassDivider()
                automaticUpdateCheckRow
                LiquidGlassDivider()
                codexHookRow
                LiquidGlassDivider()
                syncRow
                LiquidGlassDivider()
                hotKeyRow
                LiquidGlassDivider()
                codexVersionSection
                LiquidGlassDivider()
                versionRow
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)

            settingsErrorPanel

            HStack(alignment: .center, spacing: 12) {
                quitButton
                Spacer()
                checkUpdateButton
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
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
            isOuterSurface: true
        )
        .onAppear {
            loginItemSettings.refresh()
            syncSettings.refresh()
            appUpdater.refreshAutomaticCheckSetting()
            refreshCodexVersionSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexHookSettings.refresh()
            syncSettings.refresh()
            codexHookSettings.verifyInstalledHooks()
            refreshCodexVersionSection()
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
        static let statusAnimation = Animation.codexStatus
    }

    var launchAtLoginRow: some View {
        SettingsToggleRow(
            icon: "power",
            title: "开机自动启动",
            isOn: Binding(
                get: { loginItemSettings.isEnabled },
                set: { loginItemSettings.setEnabled($0) }
            )
        )
    }

    var automaticUpdateCheckRow: some View {
        SettingsToggleRow(
            icon: "arrow.triangle.2.circlepath",
            title: "自动检查更新",
            isOn: Binding(
                get: { appUpdater.automaticallyChecksForUpdates },
                set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
            ),
            isEnabled: appUpdater.canConfigureAutomaticChecks
        )
    }

    var hotKeyRow: some View {
        HotKeyRecorderRow(settings: globalHotKeySettings)
    }

    var codexHookRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "link",
                title: "启用 Codex Hook",
                isOn: Binding(
                    get: { codexHookSettings.isEnabled },
                    set: { codexHookSettings.setEnabled($0) }
                ),
                isEnabled: !codexHookSettings.isUpdating
            )

            if let message = codexHookSettings.errorMessage {
                SettingsCaptionMessageRow(message: message)
            }
        }
    }

    var syncRow: some View {
        let state = syncRowState
        let lastSyncText = syncSettings.lastUploadAtText

        return VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "icloud",
                title: "跨设备同步",
                isOn: Binding(
                    get: { state.isActive },
                    set: { enabled in
                        guard codexHookSettings.isEnabled, state.isSyncAvailable else {
                            return
                        }
                        guard syncSettings.setEnabled(enabled) else {
                            return
                        }
                        onSyncChanged(enabled)
                    }
                ),
                isEnabled: state.canToggle
            )

            if let message = syncSettings.unavailableMessage {
                SettingsCaptionMessageRow(message: message)
            } else if state.shouldShowSyncStatus(lastSyncText: lastSyncText) {
                SettingsIndentedRow {
                    Text("最近同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    if syncSettings.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                            .help("正在同步")
                    } else if let lastSyncText {
                        Text(lastSyncText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    var syncRowState: SyncRowState {
        SyncRowState(
            isHookEnabled: codexHookSettings.isEnabled,
            isHookUpdating: codexHookSettings.isUpdating,
            isSyncEnabled: syncSettings.isEnabled,
            isSyncAvailable: syncSettings.isSyncAvailable,
            isSyncing: syncSettings.isSyncing
        )
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

    /// 版本行优先显示更新状态, 没有动态消息时回退到当前版本号
    var versionStatus: (text: String, isVersionLabel: Bool) {
        if let message = appUpdater.settingsStatusMessage ?? appUpdater.availableUpdateMessage {
            return (message, false)
        }
        return (Bundle.main.displayVersionLabel, true)
    }

    var codexVersionSection: some View {
        CodexVersionSection(
            snapshot: codexVersions.snapshot,
            connectionInfo: statusViewModel.codexConnectionInfo
        )
    }

    func refreshCodexVersionSection() {
        // 版本探测较慢且内部会合并并发请求; 连接信息只是缓存读取
        codexVersions.refresh()
        statusViewModel.refreshCodexConnectionInfo()
    }

    @ViewBuilder
    var settingsErrorPanel: some View {
        if let message = settingsErrorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.panelPadding)
                .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
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

    var settingsErrorMessage: String? {
        loginItemSettings.errorMessage
    }
}

private struct SyncRowState {
    let isHookEnabled: Bool
    let isHookUpdating: Bool
    let isSyncEnabled: Bool
    let isSyncAvailable: Bool
    let isSyncing: Bool

    var isActive: Bool {
        isHookEnabled && isSyncEnabled && isSyncAvailable
    }

    var canToggle: Bool {
        isHookEnabled && !isHookUpdating && isSyncAvailable
    }

    func shouldShowSyncStatus(lastSyncText: String?) -> Bool {
        isActive && (isSyncing || lastSyncText != nil)
    }
}
