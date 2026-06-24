import AppKit
import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var statusViewModel: CodexStatusViewModel
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var loginItemSettings = LoginItemSettings()
    @StateObject private var codexVersions = CodexCLIVersionViewModel()
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var globalHotKeySettings: GlobalHotKeySettings

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                launchAtLoginRow
                LiquidGlassDivider()
                automaticUpdateCheckRow
                LiquidGlassDivider()
                hotKeyRow
                LiquidGlassDivider()
                codexHookRow
                LiquidGlassDivider()
                versionRow
                LiquidGlassDivider()
                codexVersionSection
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
        .animation(Metrics.statusAnimation, value: loginItemSettings.errorMessage)
        .animation(Metrics.statusAnimation, value: codexHookSettings.errorMessage)
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
            codexHookSettings.refresh()
            appUpdater.refreshAutomaticCheckSetting()
            refreshCodexVersionSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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
                )
            )

            HStack(alignment: .top, spacing: 10) {
                Color.clear
                    .frame(width: Metrics.iconWidth)

                Text("开启后将会写入全局 Codex Hook 配置\n用于近 30 周数据中展示更多统计数据\n该数据仅保存在本机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    // 版本行优先显示更新状态, 没有动态消息时回退到当前版本号
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

    var settingsErrorMessage: String? {
        loginItemSettings.errorMessage ?? codexHookSettings.errorMessage
    }
}
