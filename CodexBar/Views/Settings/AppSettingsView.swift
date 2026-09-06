import AppKit
import SwiftUI

/// 设置窗口根视图, 按通用; 工作流和关于分页汇总设置与版本信息
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
    @ObservedObject var autoResetSettings: AutoResetSettings
    @ObservedObject var keepAliveController: KeepAliveController
    let onSyncChanged: (Bool) -> Void
    let onRebuildWorkflowData: WorkflowSyncScheduler.RebuildHandler
    let onOptionsAction: (SettingsOptionsPanelAction) -> Void
    let onContentHeightChanged: (CGFloat) -> Void
    @State private var selectedTab = SettingsTab.general
    @State private var isTabContentSettled = true
    @State private var notificationAnchorProvider = ScreenFrameProvider()
    @State private var autoResetAnchorProvider = ScreenFrameProvider()
    @State private var keepAliveAnchorProvider = ScreenFrameProvider()
    @State private var rebuildableDates = [String]()
    @State private var selectedRebuildRange: RebuildDateRange?
    @State private var isShowingRebuildConfirmation = false
    @State private var isRebuildingWorkflowData = false
    @State private var rebuildStatus: RebuildStatus?
    @State private var helperFeatureConfirmation: HelperFeatureConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            settingsTabBar
                .padding(.top, Metrics.padding)
                .padding(.bottom, Metrics.tabContentSpacing)

            ScrollView(.vertical) {
                selectedSettingsPage
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SettingsPageHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                    .padding(.horizontal, Metrics.padding)
                    .padding(.bottom, Metrics.padding)
            }
            .id(selectedTab)
            .scrollIndicators(.automatic)
            .scaleEffect(
                isTabContentSettled ? 1 : Metrics.tabContentInitialScale,
                anchor: .top
            )
            .offset(y: isTabContentSettled ? 0 : Metrics.tabContentInitialOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: Metrics.windowWidth)
        .frame(maxHeight: .infinity, alignment: .top)
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
            autoResetSettings.refresh()
            appUpdater.refreshAutomaticCheckSetting()
            refreshStatusRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexHookSettings.reconcileInstalledHooks()
            syncSettings.refresh()
            menuBarQuotaSettings.refresh()
            mainPanelSettings.refresh()
            autoResetSettings.refresh()
            refreshStatusRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowDidOpen)) { _ in
            selectedRebuildRange = nil
            isShowingRebuildConfirmation = false
            helperFeatureConfirmation = nil
            clearRebuildStatus()
        }
        .onChange(of: selectedTab) { _, _ in
            onOptionsAction(.closeAll)
        }
        .task(id: selectedTab) {
            guard !isTabContentSettled else {
                return
            }

            await Task.yield()
            guard !Task.isCancelled else {
                return
            }

            withAnimation(Metrics.tabContentTransition) {
                isTabContentSettled = true
            }
        }
        .onPreferenceChange(SettingsPageHeightPreferenceKey.self) { pageHeight in
            guard pageHeight.isFinite, pageHeight > 0 else {
                return
            }

            onContentHeightChanged(pageHeight + Metrics.windowChromeHeight)
        }
        .alert(
            LocalizedStringResource("workflow.rebuild.confirmation.title", defaultValue: "\(selectedRebuildDateKeys.count, specifier: "%lld")"),
            isPresented: $isShowingRebuildConfirmation
        ) {
            Button("common.action.cancel", role: .cancel) {}
            Button("workflow.rebuild.action", role: .destructive) {
                rebuildWorkflowData()
            }
        } message: {
            Text(LocalizedStringResource("workflow.rebuild.confirmation.message", defaultValue: "\(selectedRebuildRange?.displayText ?? "")"))
        }
        .alert(item: $helperFeatureConfirmation) { feature in
            feature.alert(helperStatus: keepAliveController.helperStatus) {
                switch feature {
                case .autoReset: autoResetSettings.setEnabled(true)
                case .keepAlive: keepAliveController.setEnabled(true)
                }
            }
        }
    }
}

private extension AppSettingsView {
    enum Metrics {
        static let padding: CGFloat = 12
        static let windowWidth: CGFloat = 430
        static let sectionSpacing: CGFloat = 18
        static let rowSpacing: CGFloat = 14
        static let panelPadding: CGFloat = 12
        static let surfaceCornerRadius: CGFloat = 16
        static let panelCornerRadius: CGFloat = 10
        static let tabBarWidth = windowWidth - padding * 2
        static let tabBarHeight: CGFloat = 38
        static let tabBarPadding: CGFloat = 4
        static let tabSpacing: CGFloat = 4
        static let tabVerticalPadding: CGFloat = 7
        static let tabContentSpacing = padding
        static let windowChromeHeight = padding * 2 + tabBarHeight + tabContentSpacing
        static let menuBarQuotaPickerWidth: CGFloat = 72
        static let syncStatusRowHeight: CGFloat = 16
        static let syncStatusValueWidth: CGFloat = 160
        static let tabContentInitialScale = 0.975
        static let tabContentInitialOffset: CGFloat = 8
        static let tabContentTransition = Animation.spring(
            response: 0.32,
            dampingFraction: 0.74,
            blendDuration: 0.08
        )
        static let statusAnimation = Animation.codexStatus
    }

    static let githubProjectURL = URL(string: "https://github.com/bob-zebedy/CodexBar")!

    // MARK: - 分页骨架

    var settingsTabBar: some View {
        HStack(spacing: Metrics.tabSpacing) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selectedTab == tab

                Button {
                    selectSettingsTab(tab)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                        Text(tab.title)
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.tabVerticalPadding)
                    .contentShape(Capsule(style: .continuous))
                    .background {
                        if isSelected {
                            Capsule(style: .continuous)
                                .fill(.clear)
                                .liquidGlassCapsule(tint: .accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Metrics.tabBarPadding)
        .frame(width: Metrics.tabBarWidth, height: Metrics.tabBarHeight)
        .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
    }

    func selectSettingsTab(_ tab: SettingsTab) {
        guard selectedTab != tab else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isTabContentSettled = false
            selectedTab = tab
        }
    }

    @ViewBuilder
    var selectedSettingsPage: some View {
        switch selectedTab {
        case .general:
            generalSettingsPage
        case .advanced:
            advancedSettingsPage
        case .about:
            aboutSettingsPage
        }
    }

    var generalSettingsPage: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                mainPanelLayoutRow
                LiquidGlassDivider()
                mainPanelEntranceAnimationsRow
                LiquidGlassDivider()
                launchAtLoginRow
                LiquidGlassDivider()
                automaticUpdateCheckRow
                LiquidGlassDivider()
                menuBarQuotaRow
                LiquidGlassDivider()
                hotKeyRow
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)

            settingsErrorPanel
        }
    }

    var advancedSettingsPage: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            codexHookRow
            LiquidGlassDivider()
            notificationRow
            LiquidGlassDivider()
            autoResetRow
            LiquidGlassDivider()
            keepAliveRow
            LiquidGlassDivider()
            syncRow
            LiquidGlassDivider()
            rebuildWorkflowDataRow
        }
        .padding(Metrics.panelPadding)
        .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
    }

    var aboutSettingsPage: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                codexVersionSection
                LiquidGlassDivider()
                versionRow
                LiquidGlassDivider()
                githubProjectRow
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)

            HStack(alignment: .center, spacing: 12) {
                quitButton
                Spacer()
                checkUpdateButton
            }
            .padding(Metrics.panelPadding)
            .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
        }
    }

    // MARK: - 通用页各行

    var launchAtLoginRow: some View {
        SettingsToggleRow(
            icon: "power",
            title: "settings.general.launch-at-login",
            isOn: Binding(
                get: { loginItemSettings.isEnabled },
                set: { loginItemSettings.setEnabled($0) }
            )
        )
    }

    var automaticUpdateCheckRow: some View {
        SettingsToggleRow(
            icon: "arrow.triangle.2.circlepath",
            title: "settings.general.automatic-update-checks",
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
            title: "settings.menu-bar-quota.title",
            isOn: Binding(
                get: { isMenuBarQuotaEnabled },
                set: { menuBarQuotaSettings.setEnabled($0) }
            )
        ) {
            if isEnabled {
                Picker(
                    "settings.menu-bar-quota.window",
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

    var mainPanelLayoutRow: some View {
        MainPanelLayoutSettingsRow { anchorProvider in
            onOptionsAction(
                .toggle(panel: .mainPanel, anchorProvider: anchorProvider)
            )
        }
    }

    var mainPanelEntranceAnimationsRow: some View {
        SettingsToggleRow(
            icon: "sparkles",
            title: "settings.main-panel.entrance-animations",
            isOn: Binding(
                get: { mainPanelSettings.areEntranceAnimationsEnabled },
                set: { mainPanelSettings.setEntranceAnimationsEnabled($0) }
            )
        )
    }

    // MARK: - 高级页各行

    var codexHookRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "link",
                title: "hook.name",
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

    var autoResetRow: some View {
        let isEnabled = autoResetSettings.isEnabled
        let canShowOptions = isEnabled && keepAliveController.helperStatus == .enabled
        let caption = autoResetCaption

        return VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "arrow.counterclockwise.circle",
                title: "settings.auto-reset.title",
                isOn: Binding(
                    get: { autoResetSettings.isEnabled },
                    set: { enabled in
                        if enabled {
                            helperFeatureConfirmation = .autoReset
                        } else {
                            autoResetSettings.setEnabled(enabled)
                        }
                    }
                )
            ) {
                SettingsOptionsButton(isAvailable: canShowOptions) {
                    onOptionsAction(
                        .toggle(
                            panel: .autoReset,
                            anchorProvider: autoResetAnchorProvider
                        )
                    )
                }
            }

            settingsStatusCaptionRow(caption)
        }
        .background {
            ScreenFrameReader(provider: autoResetAnchorProvider)
        }
        .animation(Metrics.statusAnimation, value: caption)
        .animation(Metrics.statusAnimation, value: isEnabled)
        .onChange(of: canShowOptions) { _, canShowOptions in
            guard !canShowOptions else {
                return
            }

            onOptionsAction(.close(panel: .autoReset))
        }
    }

    var autoResetCaption: SettingsStatusCaption? {
        guard autoResetSettings.isEnabled else {
            return nil
        }
        if let errorMessage = keepAliveController.helperRegistrationErrorMessage {
            return SettingsStatusCaption(message: errorMessage, isError: true)
        }

        switch keepAliveController.helperStatus {
        case .requiresApproval:
            return SettingsStatusCaption(
                message: String(localized: "helper.status.authorization-required"),
                showsSystemSettingsButton: true
            )
        case .notRegistered, .notFound:
            return SettingsStatusCaption(
                message: String(localized: "helper.status.not-registered")
            )
        case .enabled:
            guard let errorMessage = keepAliveController
                .autoResetWakeScheduleErrorMessage else {
                return nil
            }
            return SettingsStatusCaption(message: errorMessage, isError: true)
        }
    }

    // MARK: - 防睡眠

    var keepAliveRow: some View {
        let caption = keepAliveCaption

        return VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "moon.zzz",
                title: "settings.keep-alive.title",
                isOn: Binding(
                    get: { keepAliveController.isEnabled },
                    set: { enabled in
                        if enabled {
                            helperFeatureConfirmation = .keepAlive
                        } else {
                            keepAliveController.setEnabled(false)
                        }
                    }
                ),
                isEnabled: codexHookSettings.isOperable && !codexHookSettings.isUpdating
            ) {
                SettingsOptionsButton(isAvailable: canShowKeepAliveOptions) {
                    onOptionsAction(
                        .toggle(panel: .keepAlive, anchorProvider: keepAliveAnchorProvider)
                    )
                }
            }

            settingsStatusCaptionRow(caption)
        }
        .background {
            ScreenFrameReader(provider: keepAliveAnchorProvider)
        }
        .animation(Metrics.statusAnimation, value: caption)
        .animation(Metrics.statusAnimation, value: keepAliveController.isEnabled)
        .onChange(of: canShowKeepAliveOptions) { _, canShowOptions in
            guard !canShowOptions else {
                return
            }

            onOptionsAction(.close(panel: .keepAlive))
        }
    }

    @ViewBuilder
    func settingsStatusCaptionRow(_ caption: SettingsStatusCaption?) -> some View {
        if let caption {
            SettingsIndentedRow(alignment: .top) {
                Text(caption.message)
                    .font(.caption)
                    .foregroundStyle(caption.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)

                Spacer(minLength: 8)

                if caption.showsSystemSettingsButton {
                    Button("common.action.open-system-settings") {
                        keepAliveController.openSystemSettings()
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .transition(.opacity)
        }
    }

    /// 判定收在 KeepAliveController 里由 sleepBlockReason 派生, 这里只读结论
    /// 在 View 里手抄那几个条件会漏掉后来新增的阻断项, 入口会亮着但点开不生效
    var canShowKeepAliveOptions: Bool {
        keepAliveController.canShowOptions
    }

    /// 返回 nil 表示这一行整个收起
    /// 正常运行时不必占一行说"一切正常", 是否正在防睡眠由主面板的咖啡杯标记呈现
    var keepAliveCaption: SettingsStatusCaption? {
        guard keepAliveController.isEnabled else {
            return nil
        }
        if keepAliveController.helperStatus == .requiresApproval {
            return SettingsStatusCaption(
                message: String(localized: "helper.status.authorization-required"),
                showsSystemSettingsButton: true
            )
        }
        if let errorMessage = keepAliveController.errorMessage {
            return SettingsStatusCaption(message: errorMessage, isError: true)
        }
        guard keepAliveController.helperStatus == .enabled else {
            return SettingsStatusCaption(message: String(localized: "helper.status.not-registered"))
        }
        guard codexHookSettings.isVerified else {
            return SettingsStatusCaption(message: String(localized: "hook.status.inactive"))
        }

        if keepAliveController.isActivelyPreventingSleep,
           keepAliveController.sleepPreventionSource == .external {
            return SettingsStatusCaption(
                message: String(localized: "keep-alive.status.disabled-by-other-source")
            )
        }

        // 低电量拦下时开关开着却不防睡眠, 不留一句无从解释
        // 判定用 isLowBatteryBlocking 而不是 isLowBatteryActive: 后者在没有任务时也成立, 那时无话可说
        // 它成立即意味着 helper 已就绪, 所以排在下面那个 switch 之前不影响 helper 类问题的呈现
        // 不写具体阈值: 滞回让保护一直持续到阈值加 5, 说死数字会与用户看到的电量对不上
        if keepAliveController.isLowBatteryBlocking {
            return SettingsStatusCaption(message: String(localized: "keep-alive.status.low-battery"))
        }

        // 上限之外的运行态都收起; 达到上限要留一句, 否则开关开着却没生效无从解释
        guard keepAliveController.hasReachedMaximumDuration else {
            return nil
        }
        let duration = keepAliveController.maximumDuration.title
        return SettingsStatusCaption(
            message: String(localized: "keep-alive.status.duration-limit-reached", defaultValue: "\(duration)")
        )
    }

    var syncRow: some View {
        let state = syncRowState
        let lastSyncText = syncSettings.lastUploadAtText

        return VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "icloud",
                title: "settings.sync.title",
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
                    .frame(minHeight: Metrics.syncStatusRowHeight, alignment: .top)
            } else if state.isActive {
                let showsSyncStatus = state.shouldShowSyncStatus(lastSyncText: lastSyncText)

                SettingsIndentedRow {
                    Text("sync.status.last-sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    ZStack(alignment: .trailing) {
                        if syncSettings.isSyncing {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(
                                    width: Metrics.syncStatusRowHeight,
                                    height: Metrics.syncStatusRowHeight
                                )
                                .help("sync.status.syncing")
                                .transition(.opacity)
                        } else if let lastSyncText {
                            Text(lastSyncText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .frame(
                        width: Metrics.syncStatusValueWidth,
                        height: Metrics.syncStatusRowHeight,
                        alignment: .trailing
                    )
                    .animation(Metrics.statusAnimation, value: syncSettings.isSyncing)
                }
                .frame(height: Metrics.syncStatusRowHeight)
                .opacity(showsSyncStatus ? 1 : 0)
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

    // MARK: - 数据重建

    var rebuildWorkflowDataRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SettingsRowMetrics.spacing) {
                Image(systemName: "arrow.clockwise.circle")
                    .frame(width: SettingsRowMetrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("workflow.rebuild.title")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 4)

                RebuildDatePicker(
                    selection: $selectedRebuildRange,
                    dataDateKeys: Set(rebuildableDates),
                    isEnabled: !isRebuildingWorkflowData
                )
                .frame(
                    width: RebuildLayoutMetrics.pickerWidth,
                    height: RebuildLayoutMetrics.controlHeight,
                    alignment: .leading
                )

                if isRebuildingWorkflowData {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: RebuildLayoutMetrics.actionMinimumWidth)
                } else {
                    Button("workflow.rebuild.action") {
                        isShowingRebuildConfirmation = true
                    }
                    .controlSize(.small)
                    .frame(minWidth: RebuildLayoutMetrics.actionMinimumWidth)
                    .disabled(selectedRebuildDateKeys.isEmpty)
                }
            }
            .frame(height: RebuildLayoutMetrics.controlHeight)

            let caption = rebuildCaption
            SettingsCaptionMessageRow(
                message: caption.message,
                color: caption.isError ? .red : .secondary
            )
        }
    }

    var rebuildCaption: RebuildStatus {
        if let rebuildStatus {
            return rebuildStatus
        }
        guard let selectedRebuildRange else {
            return RebuildStatus(message: String(localized: "workflow.rebuild.selection.none"), isError: false)
        }
        guard selectedRebuildRange.isComplete else {
            return RebuildStatus(message: String(localized: "date-picker.select-end"), isError: false)
        }
        if selectedRebuildDateKeys.isEmpty {
            return RebuildStatus(
                message: String(localized: "workflow.rebuild.error.source-unavailable"),
                isError: true
            )
        }
        return RebuildStatus(
            message: String(localized: "workflow.rebuild.selection.day-count", defaultValue: "\(selectedRebuildRange.dayCount, specifier: "%lld")"),
            isError: false
        )
    }

    var selectedRebuildDateKeys: [String] {
        guard let selectedRebuildRange, selectedRebuildRange.isComplete else {
            return []
        }
        return rebuildableDates.filter(selectedRebuildRange.contains)
    }

    func refreshRebuildableDates() {
        rebuildableDates = WorkflowStorage.rebuildableEventDateKeys()
    }

    /// 防睡眠不在这里刷: 控制器自己订阅了 didBecomeActive, 窗口打开也走 refreshSettingsState
    /// 再调一次会让每次激活都多跑一遍电源读取 helper 状态查询和 helper 二进制哈希
    func refreshStatusRows() {
        refreshCodexVersionSection()
        refreshRebuildableDates()
    }

    func rebuildWorkflowData() {
        let dateKeys = selectedRebuildDateKeys
        guard !dateKeys.isEmpty, !isRebuildingWorkflowData else {
            return
        }

        isRebuildingWorkflowData = true
        clearRebuildStatus()
        onRebuildWorkflowData(dateKeys) { result in
            isRebuildingWorkflowData = false
            refreshRebuildableDates()

            switch result {
            case let .success(summary):
                rebuildStatus = RebuildStatus(
                    message: Self.rebuildSuccessMessage(
                        for: summary,
                        autoRetryAvailable: codexHookSettings.isEnabled
                    ),
                    isError: false
                )
            case let .failure(error):
                // 请求被后续请求顶替时工作本身并没有失败, 不该报错
                guard !(error is CancellationError) else {
                    clearRebuildStatus()
                    return
                }

                rebuildStatus = RebuildStatus(
                    message: String(localized: "workflow.rebuild.status.failed", defaultValue: "\(error.localizedDescription)"),
                    isError: true
                )
            }
        }
    }

    static let rebuildFailedDateListLimit = 3

    /// 未完成的日期只列前几个, 避免长范围重建时提示挤满整行
    /// autoRetryAvailable: 常规维护只在 Hook 开启时运行, 关闭时不能承诺自动重试
    static func rebuildSuccessMessage(
        for summary: WorkflowDataRebuildSummary,
        autoRetryAvailable: Bool
    ) -> String {
        var message = String(
            localized: "workflow.rebuild.summary.completed",
            defaultValue: "\(summary.rebuiltDateCount, specifier: "%lld")\(summary.eventCount, specifier: "%lld")"
        )
        if summary.corruptLineCount > 0 {
            message += String(localized: "workflow.rebuild.summary.skipped-invalid-events", defaultValue: "\(summary.corruptLineCount, specifier: "%lld")")
        }

        if !summary.failedDateKeys.isEmpty {
            let listed = summary.failedDateKeys.prefix(rebuildFailedDateListLimit)
            var dates = listed.joined(separator: ", ")
            if summary.failedDateKeys.count > listed.count {
                dates += String(localized: "workflow.rebuild.summary.additional-dates")
            }
            message += String(localized: "workflow.rebuild.summary.incomplete-dates", defaultValue: "\(summary.failedDateKeys.count, specifier: "%lld")\(dates)")
            message += autoRetryAvailable
                ? String(localized: "workflow.rebuild.summary.retry-later")
                : String(localized: "workflow.rebuild.summary.retry-after-hook-enabled")
        }

        if summary.didFailSyncReplacementMarking {
            message += String(localized: "workflow.rebuild.summary.sync-replacement-marking-failed")
        } else if summary.isSyncReplacementPending {
            message += String(localized: "workflow.rebuild.summary.cloud-replacement-pending")
        }

        return message
    }

    func clearRebuildStatus() {
        rebuildStatus = nil
    }

    // MARK: - 通知

    /// 主开关行保留在设置窗口内, 子选项在右侧子面板中展开
    var notificationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsToggleRow(
                icon: "bell.badge",
                title: "settings.notifications.system.title",
                isOn: Binding(
                    get: { notificationSettings.isEnabled },
                    set: { notificationSettings.setEnabled($0) }
                )
            ) {
                SettingsOptionsButton(isAvailable: notificationSettings.canShowOptions) {
                    onOptionsAction(
                        .toggle(panel: .notification, anchorProvider: notificationAnchorProvider)
                    )
                }
            }

            if notificationSettings.needsAuthorization {
                NotificationAuthorizationRow(settings: notificationSettings)
                    .transition(.identity)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .background {
            ScreenFrameReader(provider: notificationAnchorProvider)
        }
        // 关掉总开关或被系统拒授权都会让 canShowOptions 转假, 收面板只需要认这一个信号
        .onChange(of: notificationSettings.canShowOptions) { _, canShowOptions in
            guard !canShowOptions else {
                return
            }

            onOptionsAction(.close(panel: .notification))
        }
    }

    // MARK: - 关于页

    var versionRow: some View {
        let status = versionStatus

        return HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "info.circle")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            Text("settings.about.version")

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
                .help("updater.action.install")
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
            connectionInfo: statusViewModel.codexConnectionInfo,
            sourceSelection: statusViewModel.pendingCodexSourceSelection ?? statusViewModel.codexSourceSelection,
            isReconnecting: statusViewModel.isReconnecting,
            isBusy: statusViewModel.isRefreshing || statusViewModel.isReconnecting || codexVersions.isRefreshing,
            errorMessage: statusViewModel.connectionErrorMessage,
            unavailableSource: statusViewModel.unavailableConnectionSource,
            onReconnect: { selection in
                Task { @MainActor in
                    if await statusViewModel.reconnectCodex(selection: selection, requiresHooks: codexHookSettings.isEnabled) {
                        codexHookSettings.reconcileInstalledHooks()
                    }
                    codexVersions.refresh(force: true)
                }
            }
        )
    }

    var githubProjectRow: some View {
        Link(destination: Self.githubProjectURL) {
            HStack(spacing: SettingsRowMetrics.spacing) {
                Image(systemName: "globe")
                    .frame(width: SettingsRowMetrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("settings.about.github-project")
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func refreshCodexVersionSection() {
        // 版本检测较慢且内部会合并并发请求; 连接信息只是缓存读取
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
            Label("updater.action.check", systemImage: "arrow.down.circle")
        }
    }

    var quitButton: some View {
        Button(role: .destructive) {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("app.action.quit", systemImage: "power.circle")
        }
        .foregroundStyle(.red)
        .keyboardShortcut("q")
    }
}

private enum RebuildLayoutMetrics {
    static let pickerWidth: CGFloat = 190
    static let controlHeight: CGFloat = 26
    static let actionMinimumWidth: CGFloat = 42
}

private struct RebuildDatePicker: View {
    @Binding var selection: RebuildDateRange?
    let dataDateKeys: Set<String>
    let isEnabled: Bool

    @State private var isPresented = false
    @State private var displayedMonth = Date()

    private enum Metrics {
        static let daySize: CGFloat = 28
        static let columnSpacing: CGFloat = 6
        static let visibleWeekCount = 6
        static let popoverWidth: CGFloat = 260
        static let popoverHeight: CGFloat = 296
    }

    private static let columns = Array(
        repeating: GridItem(.fixed(Metrics.daySize), spacing: Metrics.columnSpacing),
        count: 7
    )
    var body: some View {
        Button {
            let focusedDateKey = selection?.endDateKey ?? selection?.startDateKey
            if let focusedDateKey,
               let selectedDate = CodexDateFormat.dayDate(from: focusedDateKey) {
                displayedMonth = startOfMonth(for: selectedDate)
            }
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)

                Group {
                    if let selection {
                        Text(verbatim: selection.displayText)
                    } else {
                        Text("date-picker.select-range")
                    }
                }
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: RebuildLayoutMetrics.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isPresented ? Color.accentColor.opacity(0.70) : Color.primary.opacity(0.12),
                        lineWidth: isPresented ? 1.2 : 0.8
                    )
            }
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help("date-picker.select-range")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            calendarPopover
        }
    }

    private var calendarPopover: some View {
        let weekdaySymbols = weekdaySymbols

        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                monthNavigationButton(
                    systemImage: "chevron.left",
                    help: "date-picker.previous-month",
                    offset: -1
                )

                Spacer()

                Text(monthTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()

                Spacer()

                monthNavigationButton(
                    systemImage: "chevron.right",
                    help: "date-picker.next-month",
                    offset: 1
                )
            }

            LazyVGrid(columns: Self.columns, spacing: 5) {
                ForEach(weekdaySymbols.indices, id: \.self) { index in
                    Text(verbatim: weekdaySymbols[index])
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Metrics.daySize, height: 18)
                }

                ForEach(monthDates, id: \.self) { date in
                    dayButton(for: date)
                }
            }

            Group {
                if selection?.isComplete == false {
                    Text("date-picker.select-end")
                } else {
                    Text("date-picker.select-start")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 14)
        }
        .padding(12)
        .frame(width: Metrics.popoverWidth, height: Metrics.popoverHeight)
    }

    private func monthNavigationButton(
        systemImage: String,
        help: LocalizedStringResource,
        offset: Int
    ) -> some View {
        Button {
            guard let nextMonth = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
                return
            }
            displayedMonth = nextMonth
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                }
        }
        .buttonStyle(.plain)
        .disabled(!canMoveMonth(by: offset))
        .help(help)
    }

    private func dayButton(for date: Date) -> some View {
        let dateKey = WorkflowStorage.dateKey(for: date)
        let isSelectable = selectableDateRange.contains(calendar.startOfDay(for: date))
        let hasData = dataDateKeys.contains(dateKey)
        let isInDisplayedMonth = calendar.isDate(
            date,
            equalTo: displayedMonth,
            toGranularity: .month
        )
        let isStart = selection?.startDateKey == dateKey
        let isEnd = selection?.endDateKey == dateKey
        let isEndpoint = isStart || isEnd
        let isInCompletedRange = selection?.contains(dateKey) == true
        let day = calendar.component(.day, from: date)

        return Button {
            select(dateKey)
        } label: {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(dayBackgroundColor(
                        isEndpoint: isEndpoint,
                        isInCompletedRange: isInCompletedRange
                    ))

                Text(String(day))
                    .font(.system(size: 11, weight: isEndpoint ? .semibold : .regular))
                    .foregroundStyle(dayTextColor(
                        isSelectable: isSelectable,
                        isEndpoint: isEndpoint,
                        isInDisplayedMonth: isInDisplayedMonth
                    ))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if hasData, !isEndpoint {
                    Circle()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: 2.5, height: 2.5)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: Metrics.daySize, height: Metrics.daySize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }

    private var monthTitle: String {
        Self.monthFormatter.string(from: displayedMonth)
    }

    private var monthDates: [Date] {
        let monthStart = startOfMonth(for: displayedMonth)
        let leadingDayCount = (
            calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7
        ) % 7
        guard let gridStart = calendar.date(
            byAdding: .day,
            value: -leadingDayCount,
            to: monthStart
        ) else {
            return []
        }

        let visibleDayCount = Self.columns.count * Metrics.visibleWeekCount
        return (0 ..< visibleDayCount).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: gridStart)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols

        let firstIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[firstIndex...] + symbols[..<firstIndex])
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMMM")
        return formatter
    }()

    private var selectableDateRange: ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        let cutoff = WorkflowStorage.retentionCutoffDate(today: today, calendar: calendar)
        return cutoff ... today
    }

    private func startOfMonth(for date: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private func canMoveMonth(by offset: Int) -> Bool {
        guard let candidate = calendar.date(byAdding: .month, value: offset, to: displayedMonth) else {
            return false
        }

        let month = startOfMonth(for: candidate)
        return month >= startOfMonth(for: selectableDateRange.lowerBound)
            && month <= startOfMonth(for: selectableDateRange.upperBound)
    }

    private func select(_ dateKey: String) {
        if let selection, !selection.isComplete {
            self.selection = selection.completing(with: dateKey)
            isPresented = false
        } else {
            selection = .starting(at: dateKey)
        }
    }

    private func dayBackgroundColor(
        isEndpoint: Bool,
        isInCompletedRange: Bool
    ) -> Color {
        if isEndpoint {
            return .accentColor
        }
        return isInCompletedRange ? Color.accentColor.opacity(0.16) : .clear
    }

    private func dayTextColor(
        isSelectable: Bool,
        isEndpoint: Bool,
        isInDisplayedMonth: Bool
    ) -> Color {
        if isEndpoint {
            return .white
        }
        if !isInDisplayedMonth {
            return .codexSecondaryLabel.opacity(isSelectable ? 0.58 : 0.24)
        }
        return isSelectable ? .codexLabel : .codexSecondaryLabel.opacity(0.36)
    }
}

private struct RebuildDateRange: Equatable {
    let startDateKey: String
    let endDateKey: String?

    static func starting(at dateKey: String) -> RebuildDateRange {
        RebuildDateRange(startDateKey: dateKey, endDateKey: nil)
    }

    var isComplete: Bool {
        endDateKey != nil
    }

    var dayCount: Int {
        guard let endDateKey,
              let startDate = CodexDateFormat.dayDate(from: startDateKey),
              let endDate = CodexDateFormat.dayDate(from: endDateKey) else {
            return 0
        }

        guard let dayDifference = CodexDateFormat.localGregorianCalendar.dateComponents(
            [.day],
            from: startDate,
            to: endDate
        ).day else {
            return 0
        }
        return dayDifference + 1
    }

    var displayText: String {
        guard let startDate = CodexDateFormat.dayDate(from: startDateKey) else {
            return startDateKey
        }
        let startText = CodexDateFormat.localDayDisplayString(from: startDate)
        guard let endDateKey else {
            return String(localized: "date-range.open-ended", defaultValue: "\(startText)")
        }
        guard startDateKey != endDateKey,
              let endDate = CodexDateFormat.dayDate(from: endDateKey) else {
            return startText
        }
        let endText = CodexDateFormat.localDayDisplayString(from: endDate)
        return String(localized: "date-range.closed", defaultValue: "\(startText)\(endText)")
    }

    func completing(with dateKey: String) -> RebuildDateRange {
        RebuildDateRange(
            startDateKey: min(startDateKey, dateKey),
            endDateKey: max(startDateKey, dateKey)
        )
    }

    func contains(_ dateKey: String) -> Bool {
        guard let endDateKey else {
            return false
        }
        return dateKey >= startDateKey && dateKey <= endDateKey
    }
}

private struct RebuildStatus {
    let message: String
    let isError: Bool
}

private struct SettingsStatusCaption: Equatable {
    let message: String
    var isError = false
    var showsSystemSettingsButton = false
}

private enum SettingsTab: CaseIterable, Identifiable {
    case general
    case advanced
    case about

    var id: Self {
        self
    }

    var title: LocalizedStringResource {
        switch self {
        case .general:
            "settings.tab.general"
        case .advanced:
            "settings.tab.advanced"
        case .about:
            "settings.tab.about"
        }
    }

    var icon: String {
        switch self {
        case .general:
            "gearshape"
        case .advanced:
            "gearshape.2"
        case .about:
            "info.circle"
        }
    }
}

private struct SettingsPageHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
