import AppKit
import SwiftUI

/// 设置窗口根视图, 汇总启动项、显示、Hook、同步、通知、快捷键和版本信息
struct AppSettingsView: View {
    @EnvironmentObject private var statusViewModel: CodexStatusViewModel
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var loginItemSettings = LoginItemSettings()
    @StateObject private var codexVersions = CodexCLIVersionViewModel()
    @ObservedObject var codexHookSettings: CodexHookSettings
    @ObservedObject var syncSettings: WorkflowSyncSettings
    @ObservedObject var globalHotKeySettings: GlobalHotKeySettings
    @ObservedObject var menuBarQuotaSettings: MenuBarQuotaSettings
    @ObservedObject var mainPanelSettings: MainPanelSettings
    @ObservedObject var notificationSettings: NotificationSettings
    let onSyncChanged: (Bool) -> Void
    let onNotificationOptionsAction: (NotificationOptionsPanelAction) -> Void
    @State private var notificationRowFrame: CGRect?
    @State private var shouldOpenNotificationOptionsAfterAuthorization = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                launchAtLoginRow
                LiquidGlassDivider()
                automaticUpdateCheckRow
                LiquidGlassDivider()
                menuBarQuotaRow
                LiquidGlassDivider()
                codexHookRow
                LiquidGlassDivider()
                taskCenterRow
                LiquidGlassDivider()
                syncRow
                LiquidGlassDivider()
                notificationRow
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
            menuBarQuotaSettings.refresh()
            mainPanelSettings.refresh()
            appUpdater.refreshAutomaticCheckSetting()
            refreshCodexVersionSection()
            notificationSettings.refreshAuthorizationStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexHookSettings.refresh()
            syncSettings.refresh()
            menuBarQuotaSettings.refresh()
            mainPanelSettings.refresh()
            codexHookSettings.verifyInstalledHooks()
            refreshCodexVersionSection()
            notificationSettings.refreshAuthorizationStatus()
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
        static let notificationOptionsButtonSize: CGFloat = 22
        static let menuBarQuotaPickerWidth: CGFloat = 72
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

    var menuBarQuotaRow: some View {
        let isEnabled = isMenuBarQuotaEnabled

        return SettingsToggleRow(
            icon: "gauge.with.dots.needle.50percent",
            title: "菜单栏额度指示",
            isOn: Binding(
                get: { isMenuBarQuotaEnabled },
                set: { menuBarQuotaSettings.setEnabled($0) }
            )
        ) {
            if isEnabled {
                Picker(
                    "额度窗口",
                    selection: Binding(
                        get: { menuBarQuotaSettings.activeWindowSelection },
                        set: { menuBarQuotaSettings.setSelection($0) }
                    )
                ) {
                    ForEach(menuBarQuotaWindowOptions) { option in
                        Text(option.title).tag(option.selection)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: Metrics.menuBarQuotaPickerWidth)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(Metrics.statusAnimation, value: isEnabled)
    }

    var menuBarQuotaWindowOptions: [MenuBarQuotaOption] {
        var options = (statusViewModel.snapshot?.codexLimit?.windows ?? [])
            .map { window in
                MenuBarQuotaOption(
                    selection: MenuBarQuotaSelection(windowKind: window.kind),
                    title: window.label
                )
            }

        let selectedWindow = menuBarQuotaSettings.activeWindowSelection
        if !options.contains(where: { $0.selection == selectedWindow }) {
            options.append(
                MenuBarQuotaOption(
                    selection: selectedWindow,
                    title: selectedWindow.fallbackTitle
                )
            )
        }

        return options
    }

    var isMenuBarQuotaEnabled: Bool {
        menuBarQuotaSettings.selection != .off
    }

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 showsTaskCenter。
    var taskCenterRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && mainPanelSettings.showsTaskCenter

        return SettingsToggleRow(
            icon: "list.bullet.rectangle",
            title: "主面板任务中心",
            isOn: Binding(
                get: { isDisplayedOn },
                set: { mainPanelSettings.setShowsTaskCenter($0) }
            ),
            isEnabled: codexHookSettings.isEnabled && !codexHookSettings.isUpdating
        )
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
            isActive: syncSettings.isEffectivelyActive(isHookEnabled: codexHookSettings.isEnabled),
            isHookEnabled: codexHookSettings.isEnabled,
            isHookUpdating: codexHookSettings.isUpdating,
            isSyncAvailable: syncSettings.isSyncAvailable,
            isSyncing: syncSettings.isSyncing
        )
    }

    /// 主开关行保留在设置窗口内, 子选项在右侧子面板中展开
    var notificationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "bell.badge",
                title: "系统通知",
                isOn: Binding(
                    get: { notificationSettings.isEnabled },
                    set: { setNotificationsEnabled($0) }
                )
            ) {
                Button {
                    onNotificationOptionsAction(.toggle(alignmentScreenFrame: notificationRowFrame))
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundStyle(.tint)
                .frame(
                    width: Metrics.notificationOptionsButtonSize,
                    height: Metrics.notificationOptionsButtonSize
                )
                .opacity(notificationSettings.canShowOptions ? 1 : 0)
                .disabled(!notificationSettings.canShowOptions)
                .accessibilityHidden(!notificationSettings.canShowOptions)
                .help("通知选项")
                .animation(Metrics.statusAnimation, value: notificationSettings.canShowOptions)
            }
            .background(
                ScreenFrameReader { frame in
                    notificationRowFrame = frame
                }
            )

            if notificationSettings.isEnabled, notificationSettings.isAuthorizationDenied {
                notificationDeniedRows
                    .transition(.identity)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .onChange(of: notificationSettings.canShowOptions) { _, canShowOptions in
            guard canShowOptions else {
                onNotificationOptionsAction(.close)
                return
            }

            if shouldOpenNotificationOptionsAfterAuthorization {
                shouldOpenNotificationOptionsAfterAuthorization = false
                onNotificationOptionsAction(.open(alignmentScreenFrame: notificationRowFrame))
            }
        }
        .onChange(of: notificationSettings.isAuthorizationDenied) { _, isDenied in
            if isDenied {
                shouldOpenNotificationOptionsAfterAuthorization = false
                onNotificationOptionsAction(.close)
            }
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationSettings.setEnabled(enabled)
        if enabled, notificationSettings.canShowOptions {
            shouldOpenNotificationOptionsAfterAuthorization = false
            onNotificationOptionsAction(.open(alignmentScreenFrame: notificationRowFrame))
        } else {
            shouldOpenNotificationOptionsAfterAuthorization = enabled
                && !notificationSettings.isAuthorizationDenied
            onNotificationOptionsAction(.close)
        }
    }

    @ViewBuilder
    var notificationDeniedRows: some View {
        SettingsCaptionMessageRow(message: "系统通知权限未开启, 请在系统设置中允许 CodexBar 发送通知")
        SettingsIndentedRow {
            Button("打开系统设置") {
                notificationSettings.openSystemNotificationSettings()
            }
            .controlSize(.small)
        }
    }

    var versionRow: some View {
        let status = versionStatus

        return HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "info.circle")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

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
        if let message = loginItemSettings.errorMessage {
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
}

private struct SyncRowState {
    /// 由 WorkflowSyncSettings.isEffectivelyActive 统一判定, 视图层不再拼接业务谓词
    let isActive: Bool
    let isHookEnabled: Bool
    let isHookUpdating: Bool
    let isSyncAvailable: Bool
    let isSyncing: Bool

    var canToggle: Bool {
        isHookEnabled && !isHookUpdating && isSyncAvailable
    }

    func shouldShowSyncStatus(lastSyncText: String?) -> Bool {
        isActive && (isSyncing || lastSyncText != nil)
    }
}

private struct MenuBarQuotaOption: Identifiable {
    let selection: MenuBarQuotaSelection
    let title: String

    var id: String {
        selection.id
    }
}
