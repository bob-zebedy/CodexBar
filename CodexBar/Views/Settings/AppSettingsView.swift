import AppKit
import SwiftUI

/// 设置窗口根视图, 汇总启动项; 显示; Hook; 同步; 通知; 快捷键和版本信息
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
    let onRebuildWorkflowData: WorkflowSyncScheduler.RebuildHandler
    let onNotificationOptionsAction: (NotificationOptionsPanelAction) -> Void
    @State private var notificationRowFrame: CGRect?
    @State private var shouldOpenNotificationOptionsAfterAuthorization = false
    @State private var rebuildableDates = [String]()
    @State private var selectedRebuildRange: RebuildDateRange?
    @State private var isShowingRebuildConfirmation = false
    @State private var isRebuildingWorkflowData = false
    @State private var rebuildStatus: RebuildStatus?

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
                rebuildWorkflowDataRow
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
            refreshRebuildableDates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexHookSettings.refresh()
            syncSettings.refresh()
            menuBarQuotaSettings.refresh()
            mainPanelSettings.refresh()
            codexHookSettings.verifyInstalledHooks()
            refreshCodexVersionSection()
            notificationSettings.refreshAuthorizationStatus()
            refreshRebuildableDates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowDidOpen)) { _ in
            selectedRebuildRange = nil
            isShowingRebuildConfirmation = false
            clearRebuildStatus()
        }
        .alert(
            "批量重建 \(selectedRebuildDateKeys.count) 天的数据?",
            isPresented: $isShowingRebuildConfirmation
        ) {
            Button("取消", role: .cancel) {}
            Button("重建", role: .destructive) {
                rebuildWorkflowData()
            }
        } message: {
            Text("将从本机原始 Hook 事件重新统计 \(selectedRebuildRange?.displayText ?? "")\n并在下次同步时替换当前设备对应日期的云端聚合")
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

    /// Hook 未开启时显示为关闭并置灰, 不修改持久化的 showsTaskCenter
    var taskCenterRow: some View {
        let isDisplayedOn = codexHookSettings.isEnabled && mainPanelSettings.showsTaskCenter

        return SettingsToggleRow(
            icon: "list.bullet.rectangle",
            title: "任务中心",
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

    var rebuildWorkflowDataRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: SettingsRowMetrics.spacing) {
                Image(systemName: "arrow.clockwise.circle")
                    .frame(width: SettingsRowMetrics.iconWidth)
                    .foregroundStyle(.tint)

                Text("重建数据")
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
                        .frame(width: RebuildLayoutMetrics.actionWidth)
                } else {
                    Button("重建") {
                        isShowingRebuildConfirmation = true
                    }
                    .controlSize(.small)
                    .frame(width: RebuildLayoutMetrics.actionWidth)
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
            return RebuildStatus(message: "未选择重建日期范围", isError: false)
        }
        guard selectedRebuildRange.isComplete else {
            return RebuildStatus(message: "选择结束日期", isError: false)
        }
        if selectedRebuildDateKeys.isEmpty {
            return RebuildStatus(message: "没有可重建的本地数据", isError: true)
        }
        return RebuildStatus(
            message: "已选择 \(selectedRebuildRange.dayCount) 天",
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
                var message = "共处理 \(summary.rebuiltDateCount) 天, 包含 \(summary.eventCount) 条数据"
                if summary.corruptLineCount > 0 {
                    message += ", 跳过 \(summary.corruptLineCount) 条无效数据"
                }
                if summary.isSyncReplacementPending {
                    message += "; 云端替换将在同步可用后继续"
                }
                rebuildStatus = RebuildStatus(message: message, isError: false)
            case let .failure(error):
                rebuildStatus = RebuildStatus(
                    message: "重建失败: \(error.localizedDescription)",
                    isError: true
                )
            }
        }
    }

    func clearRebuildStatus() {
        rebuildStatus = nil
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

private enum RebuildLayoutMetrics {
    static let pickerWidth: CGFloat = 190
    static let controlHeight: CGFloat = 26
    static let actionWidth: CGFloat = 42
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
    private static let weekdaySymbols = ["一", "二", "三", "四", "五", "六", "日"]

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

                Text(selection?.displayText ?? "选择日期范围")
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
        .help("选择日期范围")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            calendarPopover
        }
    }

    private var calendarPopover: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                monthNavigationButton(
                    systemImage: "chevron.left",
                    help: "上个月",
                    offset: -1
                )

                Spacer()

                Text(monthTitle)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()

                Spacer()

                monthNavigationButton(
                    systemImage: "chevron.right",
                    help: "下个月",
                    offset: 1
                )
            }

            LazyVGrid(columns: Self.columns, spacing: 5) {
                ForEach(Self.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Metrics.daySize, height: 18)
                }

                ForEach(monthDates, id: \.self) { date in
                    dayButton(for: date)
                }
            }

            Text(selection?.isComplete == false ? "选择结束日期" : "选择开始日期")
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
        help: String,
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
        let components = calendar.dateComponents([.year, .month], from: displayedMonth)
        guard let year = components.year, let month = components.month else {
            return ""
        }
        return String(format: "%04d-%02d", year, month)
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

        let visibleDayCount = Self.weekdaySymbols.count * Metrics.visibleWeekCount
        return (0 ..< visibleDayCount).compactMap { dayOffset in
            calendar.date(byAdding: .day, value: dayOffset, to: gridStart)
        }
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = 2
        return calendar
    }

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

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let dayDifference = calendar.dateComponents(
            [.day],
            from: startDate,
            to: endDate
        ).day else {
            return 0
        }
        return dayDifference + 1
    }

    var displayText: String {
        guard let endDateKey else {
            return "\(startDateKey) ~"
        }
        return startDateKey == endDateKey
            ? startDateKey
            : "\(startDateKey) ~ \(endDateKey)"
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
