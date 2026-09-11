import AppKit
import Combine
import os
import SwiftUI

/// 菜单栏入口控制器, 统一管理状态图标, 菜单面板, 右键菜单和全局快捷键
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let viewModel: CodexStatusViewModel
    private let workflowViewModel: WorkflowViewModel
    private let codexHookSettings: CodexHookSettings
    private let codexCLINotificationSettings: CodexCLINotificationSettings
    private let activityMonitor: CodexActivityMonitor
    private let syncSettings: WorkflowSyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let menuBarQuotaSettings: MenuBarQuotaSettings
    private let mainPanelSettings: MainPanelSettings
    private let notificationSettings: NotificationSettings
    private let autoResetSettings: AutoResetSettings
    private let keepAliveController: KeepAliveController
    private let proxySettings: CodexProxySettings
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menuSurfaceVisibility = MenuSurfaceVisibilityState()
    private let popoverAnimationState = MenuSurfaceAnimationState()
    private let fallbackPanelAnimationState = MenuSurfaceAnimationState()
    private let activityCenterPresentationState = CodexActivityCenterPresentationState()
    private let heatmapDetailPanelController = HeatmapDetailPanelController()
    private let resetCreditsPanelController = ResetCreditsPanelController()
    private lazy var activityCenterPanelController = ActivityCenterPanelController(
        activityMonitor: activityMonitor,
        presentationState: activityCenterPresentationState
    )
    private var activeMenuSurface = ActiveMenuSurface.none
    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.toggleMenuSurfaceFromHotKey()
    }

    private lazy var fallbackPanelController = FallbackPanelController { [unowned self] in
        makeMenuHostingController(animationState: fallbackPanelAnimationState, usesPreferredContentSize: false)
    }

    private lazy var settingsWindowController = SettingsWindowController(
        viewModel: viewModel,
        appUpdater: appUpdater,
        proxySettings: proxySettings,
        codexHookSettings: codexHookSettings,
        codexCLINotificationSettings: codexCLINotificationSettings,
        syncSettings: syncSettings,
        globalHotKeySettings: globalHotKeySettings,
        menuBarQuotaSettings: menuBarQuotaSettings,
        mainPanelSettings: mainPanelSettings,
        notificationSettings: notificationSettings,
        autoResetSettings: autoResetSettings,
        activityProtectionSettings: activityMonitor.activityProtectionSettings,
        keepAliveController: keepAliveController
    ) { [weak self] in
        self?.statusItem.button?.window?.screen
    } onSyncChanged: { [weak self] _ in
        // setEnabled 在回调之前已经写回属性, 现场求值就是新结论
        self?.workflowSyncScheduler.requestSync(trigger: .settings)
    } onRebuildWorkflowData: { [weak self] dateKeys, completion in
        guard let self else {
            completion(.failure(CancellationError()))
            return
        }
        workflowSyncScheduler.requestRebuild(for: dateKeys, completion: completion)
    }

    private lazy var logWindowController = LogWindowController { [weak self] in
        self?.statusItem.button?.window?.screen
    }

    private lazy var workflowSyncScheduler = WorkflowSyncScheduler(
        viewModel: workflowViewModel,
        syncActivation: { [weak self] in
            self?.workflowSyncActivation ?? .syncOff
        }
    )

    private lazy var menuSurfaceFadeCoordinator = MenuSurfaceFadeCoordinator(
        contentViewProvider: { [weak self] in
            self?.activeMenuSurfaceContentView
        },
        closeActiveMenuSurface: { [weak self] in
            self?.closeActiveMenuSurface()
        }
    )
    private lazy var menuSurfaceDismissMonitor = MenuSurfaceDismissMonitor(
        isPresented: { [weak self] in
            self?.isActiveMenuSurfaceVisible == true
        },
        windowProvider: { [weak self] in
            self?.activeMenuSurfaceWindow
        },
        statusButtonProvider: { [weak self] in
            self?.statusItem.button
        },
        isPointInExtraSurface: { [weak self] screenPoint in
            self?.isPointInDetailPanel(screenPoint) == true
        }
    )
    private var delayedStatusRefreshTask: Task<Void, Never>?
    private var menuSurfaceState = MenuSurfaceState.hidden
    private var cancellables = Set<AnyCancellable>()
    private var statusIconState: StatusIconState?
    private let statusIconPresentation = StatusItemIconPresentation()
    private var statusIconHostingView: StatusItemIconHostingView?
    private var statusIconExpirationTask: Task<Void, Never>?
    private var statusToolTipTask: Task<Void, Never>?
    private var registeredHotKeyShortcut: GlobalHotKeyShortcut?
    private var auxiliaryWindowFocusRestoreTask: Task<Void, Never>?
    private var activeStatusItemMenu: NSMenu?
    private var pendingStatusItemMenuAction: (@MainActor () -> Void)?

    init(
        viewModel: CodexStatusViewModel,
        workflowViewModel: WorkflowViewModel,
        codexHookSettings: CodexHookSettings,
        codexCLINotificationSettings: CodexCLINotificationSettings,
        activityMonitor: CodexActivityMonitor,
        syncSettings: WorkflowSyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        menuBarQuotaSettings: MenuBarQuotaSettings,
        mainPanelSettings: MainPanelSettings,
        notificationSettings: NotificationSettings,
        autoResetSettings: AutoResetSettings,
        keepAliveController: KeepAliveController,
        appUpdater: AppUpdater,
        proxySettings: CodexProxySettings
    ) {
        self.viewModel = viewModel
        self.workflowViewModel = workflowViewModel
        self.codexHookSettings = codexHookSettings
        self.codexCLINotificationSettings = codexCLINotificationSettings
        self.activityMonitor = activityMonitor
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.menuBarQuotaSettings = menuBarQuotaSettings
        self.mainPanelSettings = mainPanelSettings
        self.notificationSettings = notificationSettings
        self.autoResetSettings = autoResetSettings
        self.keepAliveController = keepAliveController
        self.appUpdater = appUpdater
        self.proxySettings = proxySettings
        super.init()
    }

    private struct StatusIconState: Equatable {
        let usesErrorImage: Bool
        let progress: StatusIconProgress?
        let activity: CodexActivitySnapshot

        func symbolName(at now: Date) -> String {
            if usesErrorImage {
                return "person.slash.fill"
            }
            switch activity.statusItemActivity(at: now) {
            case .waiting: return "person.badge.key.fill"
            case .running: return "person.badge.clock.fill"
            case .completed: return "person.badge.shield.checkmark.fill"
            case .terminated: return "person.badge.shield.exclamationmark.fill"
            case .idle: return "person.fill"
            }
        }

        var hasLiveDuration: Bool {
            activity.hasActiveTasks
        }

        func toolTip(at now: Date) -> String? {
            var lines: [String] = []
            if usesErrorImage {
                lines.append(String(localized: "codex-status.account.unavailable"))
            }

            if let activityText = activityToolTip(at: now) {
                lines.append(activityText)
            }
            if activity.activeCount > 1 {
                lines.append(
                    String(localized: "status-item.activity-summary", defaultValue: "\(activity.waitingCount, specifier: "%lld")\(activity.runningCount, specifier: "%lld")")
                )
            }
            if let progress {
                lines.append(progress.toolTip)
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }

        private func activityToolTip(at now: Date) -> String? {
            switch activity.statusItemActivity(at: now) {
            case let .waiting(task):
                var text = String(localized: "activity.status.codex-waiting-for-approval")
                if let projectName = task.projectName {
                    text += " • \(projectName)"
                }
                if let toolName = task.toolName {
                    text += " • \(toolName)"
                }
                text += " • \(CodexActivityDisplayFormat.waitingDurationFragment(since: task.stateChangedAt, now: now))"
                return text
            case let .running(task):
                var text = String(localized: "activity.status.codex-running")
                if let projectName = task.projectName {
                    text += " • \(projectName)"
                }
                if task.showsPreciseDuration, let startedAt = task.startedAt {
                    text += " • \(CodexActivityDisplayFormat.runningDurationFragment(since: startedAt, now: now))"
                }
                return text
            case let .completed(completion):
                var text = String(localized: "activity.status.codex-just-completed")
                if let projectName = completion.projectName {
                    text += " • \(projectName)"
                }
                if let duration = completion.duration {
                    text += " • \(CodexActivityDisplayFormat.elapsedDurationFragment(for: duration))"
                }
                return text
            case let .terminated(termination):
                var text = String(localized: "activity.status.codex-stopped")
                if let projectName = termination.projectName {
                    text += " • \(projectName)"
                }
                if let duration = termination.duration {
                    text += " • \(CodexActivityDisplayFormat.elapsedDurationFragment(for: duration))"
                }
                return text
            case .idle:
                return nil
            }
        }
    }

    private struct StatusIconProgress: Equatable {
        let label: String
        let percent: Int
        let isStale: Bool

        var toolTip: String {
            let percentText = CodexPercentageFormat.string(from: percent)
            return String(localized: "quota.status.remaining", defaultValue: "\(label)\(percentText)")
        }

        init?(snapshot: CodexQuotaSnapshot?, selection: MenuBarQuotaSelection) {
            guard let targetKind = selection.windowKind,
                  let snapshot,
                  let window = snapshot.codexLimit?.window(ofKind: targetKind),
                  window.hasData else {
                return nil
            }

            label = window.label
            percent = window.remainingPercent
            isStale = snapshot.isRateLimitsStale
        }
    }

    // MARK: - 装配与对外入口

    func install() {
        configureStatusButton()
        configurePopover()
        observeGlobalHotKeySettings()
        // 订阅时 CombineLatest 会同步发出当前值, 初始图标由订阅路径统一渲染
        observeViewModel()
        observeWorkflowSyncState()
        codexHookSettings.reconcileInstalledHooks()
        observeMainPanelHookState()
        viewModel.startAutoRefresh()
    }

    func uninstall() {
        closeMenuSurface(animated: false)
        auxiliaryWindowFocusRestoreTask?.cancel()
        statusIconExpirationTask?.cancel()
        statusIconHostingView?.removeFromSuperview()
        statusIconHostingView = nil
        statusToolTipTask?.cancel()
        workflowSyncScheduler.cancel()
        setAuxiliaryWindowKeyFocus(true)
        globalHotKeyController.uninstall()
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func openSettingsFromCommand() {
        closeMenuSurface(animated: false)
        openSettings()
    }

    /// 通知点击回调: 面板未展示时按快捷键路径打开(含 fallback 面板兜底)
    func openMenuSurfaceFromNotification() {
        guard menuSurfaceWillOpenOnToggle else {
            return
        }

        toggleMenuSurfaceFromHotKey()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // 让系统按图像宽度计算留白, 固定 statusItem 长度会额外扩大实际占位
        button.image = NSImage(size: StatusItemIconView.size, flipped: false) { _ in true }
        let hostingView = StatusItemIconHostingView(rootView: StatusItemIconView(presentation: statusIconPresentation))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            hostingView.widthAnchor.constraint(equalToConstant: StatusItemIconView.size.width),
            hostingView.heightAnchor.constraint(equalToConstant: StatusItemIconView.size.height)
        ])
        statusIconHostingView = hostingView

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusIconPresentation(animated: false)
                self?.scheduleStatusIconExpiration()
            }
            .store(in: &cancellables)
    }

    private func configurePopover() {
        let hostingController = makeMenuHostingController(animationState: popoverAnimationState, usesPreferredContentSize: true)

        popover.delegate = self
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = hostingController
    }

    private func makeMenuHostingController(
        animationState: MenuSurfaceAnimationState,
        usesPreferredContentSize: Bool
    ) -> NSHostingController<AnyView> {
        let rootView = CodexStatusMenuView(
            viewModel: viewModel,
            workflowViewModel: workflowViewModel,
            codexHookSettings: codexHookSettings,
            mainPanelSettings: mainPanelSettings,
            activityMonitor: activityMonitor,
            syncSettings: syncSettings,
            keepAliveController: keepAliveController,
            menuSurfaceVisibility: menuSurfaceVisibility,
            animationState: animationState,
            activityCenterPresentationState: activityCenterPresentationState,
            onUsageHeatmapHoverChange: { [weak self] context in
                self?.updateHeatmapDetailPanel(context)
            },
            onResetCreditsTap: { [weak self] context in
                self?.toggleResetCreditsPanel(context)
            },
            onActivityCenterTap: { [weak self] context in
                self?.toggleActivityCenterPanel(context)
            }
        )
        .environmentObject(appUpdater)
        .frame(width: CodexStatusMenuView.menuWidth)

        let hostingController = NSHostingController(rootView: AnyView(rootView))
        if usesPreferredContentSize {
            hostingController.sizingOptions = [.preferredContentSize]
        }
        return hostingController
    }

    // MARK: - 订阅与全局快捷键

    private func observeViewModel() {
        let hasQuotaSnapshot = viewModel.$snapshot
            .map { $0 != nil }
            .removeDuplicates()

        let hasTaskCenterContent = activityMonitor.$snapshot
            .map(\.hasTaskCenterContent)
            .removeDuplicates()

        let isTaskCenterVisible = Publishers.CombineLatest(
            codexHookSettings.$isEnabled,
            mainPanelSettings.$layout
        )
        .map { isHookEnabled, layout in
            isHookEnabled && layout.isVisible(.activity)
        }
        .removeDuplicates()

        Publishers.CombineLatest4(
            menuSurfaceVisibility.$isVisible,
            hasQuotaSnapshot,
            hasTaskCenterContent,
            isTaskCenterVisible
        )
        .map { isMenuVisible, hasQuotaSnapshot, hasActivity, isTaskCenterVisible in
            isMenuVisible && hasQuotaSnapshot && hasActivity && isTaskCenterVisible
        }
        .removeDuplicates()
        .sink { [weak self] isActive in
            self?.activityCenterPresentationState.setTimelineActive(isActive)
        }
        .store(in: &cancellables)

        Publishers.CombineLatest4(
            viewModel.$loadState,
            viewModel.$snapshot,
            menuBarQuotaSettings.$selection,
            activityMonitor.$snapshot
        )
        .map { loadState, snapshot, selection, activity in
            StatusIconState(
                usesErrorImage: loadState.isError || snapshot?.hasTrustedData == false,
                progress: StatusIconProgress(snapshot: snapshot, selection: selection),
                activity: snapshot == nil ? .empty : activity
            )
        }
        .removeDuplicates()
        .sink { [weak self] state in
            self?.updateStatusImage(state)
        }
        .store(in: &cancellables)

        viewModel.$autoRefreshCountdownStartedAt
            .compactMap(\.self)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                refreshWorkflowIfHookEnabled(performMaintenance: true)
            }
            .store(in: &cancellables)

        hasQuotaSnapshot
            .sink { [weak self] isAvailable in
                guard let self, !isAvailable else {
                    return
                }
                activityCenterPanelController.hide(immediate: true)
            }
            .store(in: &cancellables)

        mainPanelSettings.$layout
            .sink { [weak self] layout in
                guard let self else {
                    return
                }
                if !layout.isVisible(.activity) {
                    activityCenterPanelController.hide(immediate: true)
                }
                if !layout.isVisible(.quota) {
                    resetCreditsPanelController.hide(immediate: true)
                }
                if !layout.isVisible(.usage) {
                    heatmapDetailPanelController.hide(immediate: true)
                }
            }
            .store(in: &cancellables)
    }

    private func observeWorkflowSyncState() {
        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                guard let self else {
                    return
                }

                if isEnabled {
                    // 回调跑在 willSet, codexHookSettings.isEnabled 此刻还是旧值, 只能用参数
                    workflowSyncScheduler.requestSync(
                        trigger: .hookEnabled,
                        activation: syncSettings.activation(isHookEnabled: true)
                    )
                } else {
                    workflowSyncScheduler.clearPendingMaintenance()
                    activityCenterPanelController.hide(immediate: true)
                }
            }
            .store(in: &cancellables)

        syncSettings.$syncAvailability
            .removeDuplicates()
            .sink { [weak self] availability in
                self?.handleSyncChanged(isSyncAvailable: availability.isAvailable)
            }
            .store(in: &cancellables)
    }

    private func observeMainPanelHookState() {
        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.mainPanelSettings.updateHookEnabled(isEnabled)
            }
            .store(in: &cancellables)
    }

    private func observeGlobalHotKeySettings() {
        globalHotKeySettings.$shortcut
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.applyGlobalHotKey(shortcut)
            }
            .store(in: &cancellables)
    }

    private func applyGlobalHotKey(_ shortcut: GlobalHotKeyShortcut?) {
        guard shortcut != registeredHotKeyShortcut else {
            return
        }

        guard let shortcut else {
            globalHotKeyController.uninstall()
            registeredHotKeyShortcut = nil
            return
        }

        if globalHotKeyController.install(shortcut: shortcut) {
            registeredHotKeyShortcut = shortcut
            globalHotKeySettings.clearError()
            return
        }

        let message = hotKeyConflictMessage(for: shortcut)
        guard let previousShortcut = registeredHotKeyShortcut else {
            // 启动阶段冲突时还没有成功注册过任何快捷键
            // 此时 restoreShortcut(nil) 会清空用户保存的配置, 只能提示冲突
            globalHotKeySettings.setRegistrationError(message)
            return
        }

        globalHotKeySettings.restoreShortcut(previousShortcut, message: message)
    }

    private func hotKeyConflictMessage(for shortcut: GlobalHotKeyShortcut) -> String {
        if shortcut == .default {
            return String(localized: "hotkey.error.default-in-use", defaultValue: "\(shortcut.label)")
        }

        return String(localized: "hotkey.error.in-use")
    }

    // MARK: - 菜单栏图标

    private func updateStatusImage(_ state: StatusIconState) {
        let previousState = statusIconState
        guard previousState != state else { return }
        statusIconState = state
        if previousState?.hasLiveDuration != state.hasLiveDuration {
            configureStatusToolTipRefresh(for: state)
        }
        refreshStatusIconPresentation(animated: previousState != nil)
        scheduleStatusIconExpiration()
    }

    private func refreshStatusIconPresentation(animated: Bool = true) {
        guard let state = statusIconState else { return }
        let now = Date()
        let toolTip = state.toolTip(at: now)
        statusItem.button?.toolTip = toolTip
        statusIconPresentation.update(
            symbolName: state.symbolName(at: now),
            percent: state.progress?.percent,
            isStale: state.progress?.isStale ?? false,
            animated: animated
        )
    }

    /// 终态提示按墙上时间到期, 即使没有后续 Hook 事件也会恢复普通图标
    private func scheduleStatusIconExpiration() {
        statusIconExpirationTask?.cancel()
        statusIconExpirationTask = nil
        guard let expiration = statusIconState?.activity.statusItemActivityExpiration else { return }
        let delay = expiration.timeIntervalSinceNow
        guard delay > 0 else { return }
        statusIconExpirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            refreshStatusIconPresentation()
            scheduleStatusIconExpiration()
        }
    }

    private func configureStatusToolTipRefresh(for state: StatusIconState) {
        statusToolTipTask?.cancel()
        statusToolTipTask = nil
        guard state.hasLiveDuration else {
            return
        }

        statusToolTipTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self,
                      !Task.isCancelled,
                      let state = statusIconState,
                      state.hasLiveDuration else {
                    return
                }
                refreshStatusIconPresentation()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApplication.shared.currentEvent else {
            toggleMenuSurface(relativeTo: sender)
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(relativeTo: sender)
        } else {
            toggleMenuSurface(relativeTo: sender)
        }
    }

    // MARK: - 菜单面板开合

    private func toggleMenuSurface(relativeTo button: NSStatusBarButton) {
        toggleMenuSurface {
            openPopover(relativeTo: button)
        }
    }

    private func toggleMenuSurface(open: () -> Void) {
        switch menuSurfaceState {
        case .hidden:
            open()
        case .opening, .shown:
            closeMenuSurface()
        case .closing:
            completeMenuSurfaceClose()
            open()
        }
    }

    /// toggle 将走"打开"分支的状态谓词, 与 toggleMenuSurface 的分支口径一致
    private var menuSurfaceWillOpenOnToggle: Bool {
        menuSurfaceState == .hidden || menuSurfaceState == .closing
    }

    private func toggleMenuSurfaceFromHotKey() {
        let targetScreen = NSScreen.containingMouse() ?? NSScreen.main
        let opensMenuSurface = menuSurfaceWillOpenOnToggle
        if opensMenuSurface {
            suspendAuxiliaryWindowKeyFocus()
        }

        toggleMenuSurface {
            openMenuSurfaceFromHotKey(on: targetScreen)
        }

        if opensMenuSurface {
            scheduleAuxiliaryWindowKeyFocusRestore()
        }
    }

    private func openMenuSurfaceFromHotKey(on targetScreen: NSScreen?) {
        guard let button = statusItem.button,
              isTrustedStatusItemAnchor(button, on: targetScreen) else {
            openFallbackPanel(on: targetScreen)
            return
        }

        openPopover(relativeTo: button)
    }

    private func isTrustedStatusItemAnchor(
        _ button: NSStatusBarButton,
        on targetScreen: NSScreen?
    ) -> Bool {
        // 全局快捷键打开时必须确认 status item 锚点真实可用
        // 否则使用无箭头 fallback 面板
        guard let window = button.window,
              let screen = window.screen,
              !button.isHidden,
              !button.bounds.isEmpty else {
            return false
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = window.convertToScreen(buttonRectInWindow)
        guard buttonScreenRect.isValidScreenRect,
              buttonScreenRect.width >= Metrics.minimumTrustedAnchorLength,
              buttonScreenRect.height >= Metrics.minimumTrustedAnchorLength else {
            return false
        }

        let trustedScreenFrame = (targetScreen ?? screen).frame.insetBy(
            dx: -Metrics.anchorScreenTolerance,
            dy: -Metrics.anchorScreenTolerance
        )
        return trustedScreenFrame.intersects(buttonScreenRect)
    }

    private func cancelMenuSurfaceTasks() {
        delayedStatusRefreshTask?.cancel()
        delayedStatusRefreshTask = nil
        menuSurfaceFadeCoordinator.cancel()
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        cancelMenuSurfaceTasks()

        menuSurfaceState = .opening
        activeMenuSurface = .popover

        popoverAnimationState.allowsAnimations = true
        menuSurfaceFadeCoordinator.prepareForFadeIn()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completeMenuSurfaceOpen()
    }

    private func openFallbackPanel(on screen: NSScreen?) {
        cancelMenuSurfaceTasks()

        fallbackPanelAnimationState.allowsAnimations = true
        fallbackPanelController.prepareForDisplay(on: screen)
        menuSurfaceState = .opening
        activeMenuSurface = .fallbackPanel

        menuSurfaceFadeCoordinator.prepareForFadeIn()
        fallbackPanelController.show()
        completeMenuSurfaceOpen()
    }

    private func completeMenuSurfaceOpen() {
        menuSurfaceVisibility.beginPresentation()
        refreshWorkflowIfHookEnabled(performMaintenance: false)
        menuSurfaceDismissMonitor.install(
            onDismiss: { [weak self] in
                self?.closeMenuSurface()
            },
            onLogShortcut: { [weak self] in
                self?.openLogFromShortcut()
            }
        )

        menuSurfaceFadeCoordinator.fadeIn(duration: Metrics.fadeInDuration) { [weak self] in
            self?.menuSurfaceState = .shown
        }

        scheduleDelayedStatusRefresh()
    }

    // MARK: - 右键菜单

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        closeMenuSurface(animated: false)
        presentStatusItemMenu(makeContextMenu(), relativeTo: button)
    }

    private func presentStatusItemMenu(_ menu: NSMenu, relativeTo button: NSStatusBarButton) {
        pendingStatusItemMenuAction = nil
        activeStatusItemMenu = menu
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
        finishStatusItemMenuPresentation(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        finishStatusItemMenuPresentation(menu)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(
            title: "app.menu.settings",
            action: #selector(openSettings),
            keyEquivalent: ",",
            symbolName: "gearshape"
        ))

        menu.addItem(menuItem(
            title: "app.menu.log",
            action: #selector(openLog),
            keyEquivalent: "l",
            symbolName: "doc.text.magnifyingglass"
        ))

        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "common.action.quit",
            action: #selector(quit),
            keyEquivalent: "q",
            symbolName: "power"
        ))

        return menu
    }

    private func menuItem(
        title: LocalizedStringResource,
        action: Selector,
        keyEquivalent: String,
        symbolName: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: title),
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        item.target = self
        return item
    }

    @objc private func openSettings() {
        openAuxiliaryWindow { [weak self] in
            self?.settingsWindowController.open()
        }
    }

    @objc private func openLog() {
        openAuxiliaryWindow { [weak self] in
            self?.logWindowController.open()
        }
    }

    // MARK: - 辅助窗口与焦点

    private func openLogFromShortcut() {
        closeMenuSurface(animated: false)
        openLog()
    }

    private func openAuxiliaryWindow(_ open: @escaping @MainActor () -> Void) {
        guard activeStatusItemMenu == nil else {
            pendingStatusItemMenuAction = { [weak self] in
                self?.openAuxiliaryWindow(open)
            }
            return
        }

        auxiliaryWindowFocusRestoreTask?.cancel()
        auxiliaryWindowFocusRestoreTask = nil
        setAuxiliaryWindowKeyFocus(true)
        open()
    }

    private func runPendingStatusItemMenuAction() {
        guard let pendingStatusItemMenuAction else {
            return
        }

        self.pendingStatusItemMenuAction = nil
        DispatchQueue.main.async {
            pendingStatusItemMenuAction()
        }
    }

    private func finishStatusItemMenuPresentation(_ menu: NSMenu) {
        guard activeStatusItemMenu === menu else {
            return
        }

        menu.delegate = nil
        activeStatusItemMenu = nil

        if statusItem.menu === menu {
            statusItem.menu = nil
        }

        runPendingStatusItemMenuAction()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 关闭流程

    private func closeMenuSurface(animated: Bool = true) {
        if menuSurfaceState == .closing, animated {
            return
        }

        cancelMenuSurfaceTasks()
        hideSideDetailPanels()
        menuSurfaceDismissMonitor.remove()
        menuSurfaceVisibility.endPresentation()

        guard isActiveMenuSurfaceVisible else {
            popoverAnimationState.allowsAnimations = false
            fallbackPanelAnimationState.allowsAnimations = false
            menuSurfaceFadeCoordinator.resetAlpha()
            menuSurfaceState = .hidden
            activeMenuSurface = .none
            return
        }

        guard animated else {
            // 关闭菜单面板时短暂禁止辅助窗口抢回 key
            // 避免设置/日志窗口闪前
            suspendAuxiliaryWindowKeyFocus()
            completeMenuSurfaceClose(hidesDetailPanel: false)
            return
        }

        suspendAuxiliaryWindowKeyFocus()
        menuSurfaceState = .closing
        let didStartFadeOut = menuSurfaceFadeCoordinator.fadeOut(duration: Metrics.fadeOutDuration) { [weak self] in
            self?.menuSurfaceState = .hidden
            self?.scheduleAuxiliaryWindowKeyFocusRestore()
        }

        if !didStartFadeOut {
            completeMenuSurfaceClose()
        }
    }

    private func completeMenuSurfaceClose(hidesDetailPanel: Bool = true) {
        cancelMenuSurfaceTasks()
        if hidesDetailPanel {
            hideSideDetailPanels()
        }
        menuSurfaceDismissMonitor.remove()

        closeActiveMenuSurface()

        menuSurfaceVisibility.endPresentation()
        menuSurfaceFadeCoordinator.resetAlpha()
        menuSurfaceState = .hidden
        activeMenuSurface = .none
        scheduleAuxiliaryWindowKeyFocusRestore()
    }

    /// 侧边面板互斥名册: 新增面板只需要加入这里, 显隐与点击区域判定即可覆盖
    private var sideDetailPanels: [MenuSideDetailPanel] {
        [heatmapDetailPanelController, resetCreditsPanelController, activityCenterPanelController]
    }

    private func hideSideDetailPanels(
        except kept: MenuSideDetailPanel? = nil,
        immediate: Bool = true
    ) {
        for panel in sideDetailPanels where panel !== kept {
            panel.hide(immediate: immediate)
        }
    }

    private func isPointInDetailPanel(_ screenPoint: NSPoint) -> Bool {
        sideDetailPanels.contains { $0.containsScreenPoint(screenPoint) }
    }

    private func suspendAuxiliaryWindowKeyFocus() {
        auxiliaryWindowFocusRestoreTask?.cancel()
        auxiliaryWindowFocusRestoreTask = nil
        setAuxiliaryWindowKeyFocus(false)
    }

    private func scheduleAuxiliaryWindowKeyFocusRestore() {
        auxiliaryWindowFocusRestoreTask?.cancel()
        auxiliaryWindowFocusRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Metrics.auxiliaryWindowKeyFocusRestoreDelayMilliseconds))
            guard let self, !Task.isCancelled else {
                return
            }

            setAuxiliaryWindowKeyFocus(true)
            auxiliaryWindowFocusRestoreTask = nil
        }
    }

    private func setAuxiliaryWindowKeyFocus(_ allowsKeyFocus: Bool) {
        settingsWindowController.setAllowsKeyFocus(allowsKeyFocus)
        logWindowController.setAllowsKeyFocus(allowsKeyFocus)
    }

    // MARK: - 刷新与同步

    private func scheduleDelayedStatusRefresh() {
        delayedStatusRefreshTask?.cancel()
        delayedStatusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, isActiveMenuSurfaceVisible else {
                return
            }

            viewModel.refreshIfNeeded(trigger: .panelOpen)
        }
    }

    private func refreshWorkflowIfHookEnabled(performMaintenance: Bool) {
        // Hook 与额度使用同一刷新节奏, 配置和信任状态损坏后都能自动收敛
        codexHookSettings.reconcileInstalledHooks()
        guard codexHookSettings.isEnabled else {
            workflowSyncScheduler.clearPendingMaintenance()
            return
        }

        if performMaintenance {
            // 统计维护挂在额度刷新完成事件上, 触发来源继承那一次刷新
            workflowSyncScheduler.requestMaintenance(
                allowsSync: true,
                trigger: viewModel.lastRefreshTrigger
            )
        } else {
            workflowViewModel.refreshIfNeeded()
        }
    }

    /// isSyncAvailable 由调用方传入
    /// 从 $syncAvailability 的订阅进来时 syncSettings.isSyncAvailable 还是旧值, 只有回调参数是新的
    /// 不在这里判断该不该跳过: requestSync 的 guard 已经统一处理并记下 reason=
    private func handleSyncChanged(isSyncAvailable: Bool) {
        workflowSyncScheduler.requestSync(
            trigger: .settings,
            activation: syncSettings.activation(
                isHookEnabled: codexHookSettings.isEnabled,
                isSyncAvailable: isSyncAvailable
            )
        )
    }

    private var workflowSyncActivation: WorkflowSyncActivation {
        syncSettings.activation(isHookEnabled: codexHookSettings.isEnabled)
    }

    // MARK: - 侧边面板

    private func updateHeatmapDetailPanel(_ context: UsageHeatmapHoverContext?) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            heatmapDetailPanelController.hide(immediate: true)
            return
        }

        if context != nil {
            hideSideDetailPanels(except: heatmapDetailPanelController, immediate: false)
        }

        heatmapDetailPanelController.update(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: menuSurfaceContentView
        )
    }

    private func toggleResetCreditsPanel(_ context: ResetCreditsPanelContext) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            resetCreditsPanelController.hide(immediate: true)
            return
        }

        hideSideDetailPanels(except: resetCreditsPanelController)
        resetCreditsPanelController.toggle(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: menuSurfaceContentView
        )
    }

    private func toggleActivityCenterPanel(_ context: CodexActivityCenterPanelContext) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            activityCenterPanelController.hide(immediate: true)
            return
        }

        hideSideDetailPanels(except: activityCenterPanelController)
        activityCenterPanelController.toggle(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: menuSurfaceContentView
        )
    }

    private var isActiveMenuSurfaceVisible: Bool {
        switch activeMenuSurface {
        case .none:
            false
        case .popover:
            popover.isShown
        case .fallbackPanel:
            fallbackPanelController.isVisible
        }
    }

    private var activeMenuSurfaceContentView: NSView? {
        switch activeMenuSurface {
        case .none:
            nil
        case .popover:
            popover.contentViewController?.view
        case .fallbackPanel:
            fallbackPanelController.contentView
        }
    }

    private var activeMenuSurfaceWindow: NSWindow? {
        switch activeMenuSurface {
        case .none:
            nil
        case .popover:
            popover.contentViewController?.view.window
        case .fallbackPanel:
            fallbackPanelController.window
        }
    }

    private func closeActiveMenuSurface() {
        // 主动关闭先清除宿主身份, 避免同步的关闭回调重入清理流程
        activeMenuSurface = .none
        if popover.isShown {
            popover.performClose(nil)
        }

        fallbackPanelController.orderOut()

        popoverAnimationState.allowsAnimations = false
        fallbackPanelAnimationState.allowsAnimations = false
    }

    private enum Metrics {
        static let fadeInDuration: TimeInterval = 0.24
        static let fadeOutDuration: TimeInterval = 0.18
        static let auxiliaryWindowKeyFocusRestoreDelayMilliseconds: UInt64 = 120
        static let minimumTrustedAnchorLength: CGFloat = 1
        static let anchorScreenTolerance: CGFloat = 1
    }

    private enum MenuSurfaceState {
        case hidden
        case opening
        case shown
        case closing
    }

    private enum ActiveMenuSurface {
        case none
        case popover
        case fallbackPanel
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard notification.object as? NSPopover === popover, !popover.isShown else {
            return
        }

        popoverAnimationState.allowsAnimations = false
        guard activeMenuSurface == .popover else {
            return
        }

        completeMenuSurfaceClose()
    }
}

/// 菜单侧边面板的互斥名册接口; 面板间互斥和点击区域判定统一走名册遍历
private protocol MenuSideDetailPanel: AnyObject {
    func hide(immediate: Bool)
    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool
}

extension HeatmapDetailPanelController: MenuSideDetailPanel {}
extension ResetCreditsPanelController: MenuSideDetailPanel {}
extension ActivityCenterPanelController: MenuSideDetailPanel {}
