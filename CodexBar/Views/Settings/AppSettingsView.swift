import AppKit
import SwiftUI

/// 设置窗口根视图, 按通用、高级和关于分页汇总设置与版本信息
struct AppSettingsView: View {
    @EnvironmentObject private var statusViewModel: CodexStatusViewModel
    @EnvironmentObject private var appUpdater: AppUpdater
    @StateObject private var loginItemSettings = LoginItemSettings()
    @StateObject private var codexVersions = CodexVersionViewModel()
    @ObservedObject var syncSettings: SyncSettings
    @ObservedObject var globalHotKeySettings: GlobalHotKeySettings
    @ObservedObject var menuBarQuotaSettings: MenuBarQuotaSettings
    let mainPanelSettings: MainPanelSettings
    let taskGlowSettings: TaskGlowSettings
    @ObservedObject var notificationSettings: NotificationSettings
    @ObservedObject var autoResetSettings: AutoResetSettings
    @ObservedObject var keepAliveController: KeepAliveController
    let onSyncChanged: (Bool) -> Void
    let onRebuildHistoryData: SyncScheduler.RebuildHandler
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
    @State private var isRebuildingHistoryData = false
    @State private var rebuildResult: RebuildResult?
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
            taskGlowSettings.refresh()
            autoResetSettings.refresh()
            appUpdater.refreshAutomaticCheckSetting()
            refreshStatusRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncSettings.refresh()
            menuBarQuotaSettings.refresh()
            mainPanelSettings.refresh()
            taskGlowSettings.refresh()
            autoResetSettings.refresh()
            refreshStatusRows()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowDidOpen)) { _ in
            selectedRebuildRange = nil
            isShowingRebuildConfirmation = false
            helperFeatureConfirmation = nil
            rebuildResult = nil
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
            LocalizedStringResource("history.rebuild.confirmation.title", defaultValue: "\(selectedRebuildDateKeys.count, specifier: "%lld")"),
            isPresented: $isShowingRebuildConfirmation
        ) {
            Button("common.action.cancel", role: .cancel) {}
            Button("history.rebuild.action", role: .destructive) {
                rebuildHistoryData()
            }
        } message: {
            Text(LocalizedStringResource("history.rebuild.confirmation.message", defaultValue: "\(selectedRebuildRange?.displayText ?? "")"))
        }
        .alert(
            rebuildResult?.title ?? LocalizedStringResource("history.rebuild.result.completed"),
            isPresented: Binding(
                get: { rebuildResult != nil },
                set: {
                    if !$0 {
                        rebuildResult = nil
                    }
                }
            ),
            presenting: rebuildResult
        ) { _ in
            Button("common.action.close", role: .cancel) {}
        } message: { result in
            Text(verbatim: result.message)
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
        static let tabCornerRadius: CGFloat = 6
        static let tabVerticalPadding: CGFloat = 7
        static let tabContentSpacing = padding
        static let windowChromeHeight = padding * 2 + tabBarHeight + tabContentSpacing
        static let dataUpdateIntervalPickerWidth: CGFloat = 90
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
                let shape = RoundedRectangle(cornerRadius: Metrics.tabCornerRadius, style: .continuous)

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
                    .contentShape(shape)
                    .background {
                        if isSelected {
                            shape
                                .fill(.clear)
                                .liquidGlassBadge(tint: .accentColor, in: shape)
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
                notificationRow
                LiquidGlassDivider()
                MainPanelAnimationsSettingsRow(settings: mainPanelSettings)
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
            TaskGlowSettingsRow(
                settings: taskGlowSettings,
                onOptionsAction: onOptionsAction
            )
            LiquidGlassDivider()
            autoResetRow
            LiquidGlassDivider()
            keepAliveRow
            LiquidGlassDivider()
            syncRow
            LiquidGlassDivider()
            dataUpdateIntervalRow
            LiquidGlassDivider()
            rebuildHistoryDataRow
        }
        .padding(Metrics.panelPadding)
        .liquidGlassSurface(cornerRadius: Metrics.panelCornerRadius)
    }

    var aboutSettingsPage: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                codexVersionSection
                LiquidGlassDivider()
                HelperInstallationStatusRow(status: keepAliveController.helperInstallationStatus)
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
                .fixedSize(horizontal: true, vertical: false)
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

    // MARK: - 高级页各行

    var dataUpdateIntervalRow: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "timer")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)
            Text("settings.data-update.interval.title")
            Spacer()
            SettingsOptionsPicker(
                title: "settings.data-update.interval.title",
                selection: Binding(
                    get: { statusViewModel.dataUpdateInterval },
                    set: { statusViewModel.setDataUpdateInterval($0) }
                ),
                options: DataUpdateInterval.allCases,
                label: { $0.title },
                width: Metrics.dataUpdateIntervalPickerWidth
            )
        }
        .frame(minHeight: SettingsRowMetrics.optionsButtonSize)
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
        if let caption = helperInstallationCaption {
            return caption
        }
        guard let errorMessage = keepAliveController.helperRegistrationErrorMessage
            ?? keepAliveController.autoResetWakeScheduleErrorMessage else {
            return nil
        }
        return SettingsStatusCaption(message: errorMessage, isError: true)
    }

    var helperInstallationCaption: SettingsStatusCaption? {
        switch keepAliveController.helperInstallationStatus {
        case .requiresApproval:
            SettingsStatusCaption(
                message: String(localized: "helper.status.authorization-required"),
                showsSystemSettingsButton: true
            )
        case .notInstalled:
            SettingsStatusCaption(
                message: String(localized: "helper.status.not-registered")
            )
        case let .unavailable(message):
            SettingsStatusCaption(message: message, isError: true)
        case .authorized:
            nil
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
                )
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
    /// 正常运行时不必占一行说"一切正常", 是否正在防睡眠由主面板的太阳标记呈现
    var keepAliveCaption: SettingsStatusCaption? {
        guard keepAliveController.isEnabled else {
            return nil
        }
        if let caption = helperInstallationCaption {
            return caption
        }
        if let errorMessage = keepAliveController.errorMessage {
            return SettingsStatusCaption(message: errorMessage, isError: true)
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
        // 提示不写具体电量, 因为滞回会让保护持续到电量超过恢复阈值
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
            isActive: syncSettings.isEffectivelyActive,
            isSyncAvailable: syncSettings.isSyncAvailable,
            isSyncing: syncSettings.isSyncing
        )
    }

    // MARK: - 数据重建

    var rebuildHistoryDataRow: some View {
        HStack(spacing: SettingsRowMetrics.spacing) {
            Image(systemName: "arrow.clockwise.circle")
                .frame(width: SettingsRowMetrics.iconWidth)
                .foregroundStyle(.tint)

            Text("history.rebuild.title")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 4)

            RebuildDatePicker(
                selection: $selectedRebuildRange,
                dataDateKeys: Set(rebuildableDates),
                isEnabled: !isRebuildingHistoryData
            )
            .frame(
                width: RebuildLayoutMetrics.pickerWidth,
                height: RebuildLayoutMetrics.controlHeight,
                alignment: .leading
            )

            if isRebuildingHistoryData {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: RebuildLayoutMetrics.actionMinimumWidth)
            } else {
                Button("history.rebuild.action") {
                    isShowingRebuildConfirmation = true
                }
                .controlSize(.small)
                .frame(minWidth: RebuildLayoutMetrics.actionMinimumWidth)
                .disabled(selectedRebuildDateKeys.isEmpty)
            }
        }
        .frame(height: RebuildLayoutMetrics.controlHeight)
    }

    var selectedRebuildDateKeys: [String] {
        guard let selectedRebuildRange, selectedRebuildRange.isComplete else {
            return []
        }
        return selectedRebuildRange.dateKeys
    }

    func refreshRebuildableDates() {
        Task {
            let dates = await Task.detached(priority: .utility) {
                let eventDates = HistoryStorage.rebuildableEventDateKeys()
                let tokenDates = await (try? TokenHistoryStore().rebuildableDateKeys()) ?? []
                return Set(eventDates + tokenDates).sorted()
            }.value
            rebuildableDates = dates
        }
    }

    /// 防睡眠不在这里刷: 控制器自己订阅了 didBecomeActive, 窗口打开也走 refreshSettingsState
    /// 再调一次会让每次激活都多跑一遍电源读取 helper 状态查询和 helper 二进制哈希
    func refreshStatusRows() {
        refreshCodexVersionSection()
        refreshRebuildableDates()
    }

    func rebuildHistoryData() {
        let dateKeys = selectedRebuildDateKeys
        guard !dateKeys.isEmpty, !isRebuildingHistoryData else {
            return
        }

        isRebuildingHistoryData = true
        rebuildResult = nil
        onRebuildHistoryData(dateKeys) { result in
            isRebuildingHistoryData = false
            refreshRebuildableDates()

            switch result {
            case let .success(summary):
                rebuildResult = RebuildResult(
                    message: Self.rebuildSuccessMessage(for: summary),
                    isError: false
                )
            case let .failure(error):
                // 请求被后续请求顶替时工作本身并没有失败, 不该报错
                guard !(error is CancellationError) else {
                    rebuildResult = nil
                    return
                }

                rebuildResult = RebuildResult(
                    message: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    static let rebuildFailedDateListLimit = 3

    /// 未完成的日期只列前几个, 避免长范围重建时结果过长
    static func rebuildSuccessMessage(
        for summary: HistoryDataRebuildSummary
    ) -> String {
        var message = String(
            localized: "history.rebuild.summary.completed",
            defaultValue: "\(summary.rebuiltDateCount, specifier: "%lld")\(summary.eventCount, specifier: "%lld")"
        )
        message += String(localized: "history.rebuild.summary.token-record-count", defaultValue: "\(summary.tokenTurnCount, specifier: "%lld")")
        if summary.didFailTokenRebuild {
            let dates = summary.failedTokenDateKeys.prefix(rebuildFailedDateListLimit).joined(separator: ", ")
            message += String(localized: "history.rebuild.summary.token-history-incomplete", defaultValue: "\(dates)")
        }

        let retryDates = summary.failedDateKeys.filter { !summary.failedRequestDateKeys.contains($0) }
        if !retryDates.isEmpty {
            let listed = retryDates.prefix(rebuildFailedDateListLimit)
            var dates = listed.joined(separator: ", ")
            if retryDates.count > listed.count {
                dates += String(localized: "history.rebuild.summary.additional-dates")
            }
            message += String(localized: "history.rebuild.summary.incomplete-dates", defaultValue: "\(retryDates.count, specifier: "%lld")\(dates)")
            message += String(localized: "history.rebuild.summary.retry-later")
        }

        if !summary.failedRequestDateKeys.isEmpty {
            let dates = summary.failedRequestDateKeys.prefix(rebuildFailedDateListLimit).joined(separator: ", ")
            message += String(localized: "history.rebuild.summary.request-failed", defaultValue: "\(dates)")
        }
        if summary.isSyncReplacementPending {
            message += String(localized: "history.rebuild.summary.cloud-replacement-pending")
        }

        return message
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
        // 关掉总开关或被系统拒绝授权都会让 canShowOptions 转假, 收面板只需要认这一个信号
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
            isReconnecting: statusViewModel.isReconnecting,
            isBusy: statusViewModel.isRefreshing || statusViewModel.isReconnecting || codexVersions.isRefreshing,
            errorMessage: statusViewModel.connectionErrorMessage,
            onReconnect: {
                Task { @MainActor in
                    await statusViewModel.reconnectCodex()
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

private struct RebuildResult {
    let message: String
    let isError: Bool

    var title: LocalizedStringResource {
        isError ? "history.rebuild.result.failed" : "history.rebuild.result.completed"
    }
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
    /// 由 SyncSettings.isEffectivelyActive 统一判定, 视图层不再拼接业务谓词
    let isActive: Bool
    let isSyncAvailable: Bool
    let isSyncing: Bool

    var canToggle: Bool {
        isSyncAvailable
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
