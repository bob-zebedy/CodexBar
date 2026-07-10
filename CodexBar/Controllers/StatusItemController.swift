import AppKit
import Combine
import SwiftUI

/// 应用级对象装配点, 持有共享服务和 ViewModel 生命周期
@MainActor
final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    private let codexStatusService = CodexStatusService()
    lazy var viewModel = CodexStatusViewModel(service: codexStatusService)
    let workflowViewModel = WorkflowViewModel()
    lazy var codexHookSettings = CodexHookSettings(codexStatusService: codexStatusService)
    let syncSettings = WorkflowSyncSettings()
    let globalHotKeySettings = GlobalHotKeySettings()
    let menuBarQuotaSettings = MenuBarQuotaSettings()
    let notificationSettings = NotificationSettings()
    let appUpdater = AppUpdater()

    private var statusItemController: StatusItemController?
    private var notificationService: CodexNotificationService?

    func applicationDidFinishLaunching(_: Notification) {
        let controller = StatusItemController(
            viewModel: viewModel,
            workflowViewModel: workflowViewModel,
            codexHookSettings: codexHookSettings,
            syncSettings: syncSettings,
            globalHotKeySettings: globalHotKeySettings,
            menuBarQuotaSettings: menuBarQuotaSettings,
            notificationSettings: notificationSettings,
            appUpdater: appUpdater
        )
        controller.install()
        statusItemController = controller

        let notificationService = CodexNotificationService(
            settings: notificationSettings,
            statusViewModel: viewModel,
            codexHookSettings: codexHookSettings
        ) { [weak controller] in
            controller?.openMenuSurfaceFromNotification()
        }
        notificationService.start()
        self.notificationService = notificationService
    }

    func applicationWillTerminate(_: Notification) {
        statusItemController?.uninstall()
    }

    func openSettingsFromCommand() {
        statusItemController?.openSettingsFromCommand()
    }
}

/// 菜单栏入口控制器, 统一管理状态图标, 菜单面板, 右键菜单和全局快捷键
@MainActor
private final class StatusItemController: NSObject, NSMenuDelegate {
    private let viewModel: CodexStatusViewModel
    private let workflowViewModel: WorkflowViewModel
    private let codexHookSettings: CodexHookSettings
    private let syncSettings: WorkflowSyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let menuBarQuotaSettings: MenuBarQuotaSettings
    private let notificationSettings: NotificationSettings
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menuSurfaceVisibility = MenuSurfaceVisibilityState()
    private let heatmapDetailPanelController = HeatmapDetailPanelController()
    private let resetCreditsPanelController = ResetCreditsPanelController()
    private var activeMenuSurface = ActiveMenuSurface.none
    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.toggleMenuSurfaceFromHotKey()
    }

    private lazy var fallbackPanelController = FallbackPanelController { [unowned self] in
        makeMenuHostingController(usesPreferredContentSize: false)
    }

    private lazy var settingsWindowController = SettingsWindowController(
        viewModel: viewModel,
        appUpdater: appUpdater,
        codexHookSettings: codexHookSettings,
        syncSettings: syncSettings,
        globalHotKeySettings: globalHotKeySettings,
        menuBarQuotaSettings: menuBarQuotaSettings,
        notificationSettings: notificationSettings
    ) { [weak self] in
        self?.statusItem.button?.window?.screen
    } onSyncChanged: { [weak self] enabled in
        self?.handleSyncChanged(enabled)
    }

    private lazy var logWindowController = LogWindowController { [weak self] in
        self?.statusItem.button?.window?.screen
    }

    private lazy var workflowSyncScheduler = WorkflowSyncScheduler(
        viewModel: workflowViewModel,
        canSynchronize: { [weak self] in
            self?.canSynchronizeWorkflow == true
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
    private var statusIconAnimationTask: Task<Void, Never>?
    private var registeredHotKeyShortcut: GlobalHotKeyShortcut?
    private var auxiliaryWindowFocusRestoreTask: Task<Void, Never>?
    private var activeStatusItemMenu: NSMenu?
    private var pendingStatusItemMenuAction: (@MainActor () -> Void)?

    init(
        viewModel: CodexStatusViewModel,
        workflowViewModel: WorkflowViewModel,
        codexHookSettings: CodexHookSettings,
        syncSettings: WorkflowSyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        menuBarQuotaSettings: MenuBarQuotaSettings,
        notificationSettings: NotificationSettings,
        appUpdater: AppUpdater
    ) {
        self.viewModel = viewModel
        self.workflowViewModel = workflowViewModel
        self.codexHookSettings = codexHookSettings
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.menuBarQuotaSettings = menuBarQuotaSettings
        self.notificationSettings = notificationSettings
        self.appUpdater = appUpdater
        super.init()
    }

    private static func makeStatusImage(
        _ symbolName: String,
        progress: StatusIconProgress? = nil,
        progressVisibility: CGFloat = 1
    ) -> NSImage? {
        guard let symbolImage = makeStatusSymbolImage(symbolName) else {
            return nil
        }

        let usesTemplateRendering = progress == nil
        let resolvedProgressVisibility = clampedProgressVisibility(progressVisibility)
        let statusImage = NSImage(size: Metrics.progressStatusImageSize, flipped: false) { _ in
            Self.drawStatusSymbol(
                symbolImage,
                in: Metrics.progressStatusSymbolRect,
                tint: usesTemplateRendering ? .black : .labelColor,
                alpha: progress?.isStale == true ? Metrics.staleIconAlpha : 1
            )
            if let progress {
                Self.drawProgress(
                    progress,
                    visibility: resolvedProgressVisibility
                )
            }
            return true
        }
        statusImage.isTemplate = usesTemplateRendering
        statusImage.alignmentRect = Self.statusImageAlignmentRect(for: symbolImage)
        return statusImage
    }

    private static func makeStatusSymbolImage(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .regular,
            scale: .medium
        )
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func drawStatusSymbol(
        _ image: NSImage,
        in rect: NSRect,
        tint: NSColor,
        alpha: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        tint.withAlphaComponent(alpha).setFill()
        rect.fill()
        image.draw(
            in: rect,
            from: .zero,
            operation: .destinationIn,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func statusImageAlignmentRect(for symbolImage: NSImage) -> NSRect {
        NSRect(
            x: 0,
            y: symbolImage.alignmentRect.minY,
            width: Metrics.progressStatusImageSize.width,
            height: symbolImage.alignmentRect.height
        )
    }

    private static func drawProgress(
        _ progress: StatusIconProgress,
        visibility: CGFloat
    ) {
        let visibility = clampedProgressVisibility(visibility)
        guard visibility > 0 else {
            return
        }

        let trackRect = Metrics.progressTrackRect
        let cornerRadius = Metrics.progressTrackCornerRadius
        let progressAlpha = (progress.isStale ? Metrics.staleProgressAlpha : 1) * visibility
        NSColor.tertiaryLabelColor
            .withAlphaComponent(Metrics.progressTrackAlpha * progressAlpha)
            .setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        .fill()

        let fillHeight = trackRect.height * CGFloat(progress.percent) / 100
        guard fillHeight > 0 else {
            return
        }

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: trackRect.width,
            height: fillHeight
        )
        QuotaPalette.nsColor(for: progress.percent)
            .withAlphaComponent(progressAlpha)
            .setFill()
        NSBezierPath(
            roundedRect: fillRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        .fill()
    }

    private static func clampedProgressVisibility(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private static func easedProgressVisibility(_ value: CGFloat) -> CGFloat {
        let value = clampedProgressVisibility(value)
        return value * value * (3 - 2 * value)
    }

    private struct StatusIconState: Equatable {
        let usesErrorImage: Bool
        let progress: StatusIconProgress?

        var symbolName: String {
            usesErrorImage ? Metrics.errorStatusSymbolName : Metrics.normalStatusSymbolName
        }

        var toolTip: String? {
            progress?.toolTip
        }
    }

    private struct StatusIconProgress: Equatable {
        let label: String
        let percent: Int
        let isStale: Bool

        var toolTip: String {
            "\(label) 剩余 \(percent)%"
        }

        init?(snapshot: CodexQuotaSnapshot?, selection: MenuBarQuotaSelection) {
            guard let targetWindowId = selection.windowId,
                  let snapshot,
                  let window = snapshot.codexLimit?.windows.first(where: {
                      $0.id == targetWindowId
                  }),
                  window.hasData else {
                return nil
            }

            label = window.label
            percent = window.remainingPercent
            isStale = snapshot.isRateLimitsStale
        }
    }

    func install() {
        configureStatusButton()
        configurePopover()
        observeGlobalHotKeySettings()
        // 订阅时 CombineLatest 会同步发出当前值, 初始图标由订阅路径统一渲染
        observeViewModel()
        observeWorkflowSyncState()
        codexHookSettings.refresh()
        viewModel.startAutoRefresh()
    }

    func uninstall() {
        closeMenuSurface(animated: false)
        auxiliaryWindowFocusRestoreTask?.cancel()
        statusIconAnimationTask?.cancel()
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
    }

    private func configurePopover() {
        let hostingController = makeMenuHostingController(usesPreferredContentSize: true)

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = hostingController
    }

    private func makeMenuHostingController(usesPreferredContentSize: Bool) -> NSHostingController<AnyView> {
        let rootView = CodexStatusMenuView(
            viewModel: viewModel,
            workflowViewModel: workflowViewModel,
            codexHookSettings: codexHookSettings,
            syncSettings: syncSettings,
            menuSurfaceVisibility: menuSurfaceVisibility,
            onUsageHeatmapHoverChange: { [weak self] context in
                self?.updateHeatmapDetailPanel(context)
            },
            onResetCreditsTap: { [weak self] context in
                self?.toggleResetCreditsPanel(context)
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

    private func observeViewModel() {
        Publishers.CombineLatest3(
            viewModel.$loadState,
            viewModel.$snapshot,
            menuBarQuotaSettings.$selection
        )
        .map { loadState, snapshot, selection in
            StatusIconState(
                usesErrorImage: loadState.isError || snapshot?.hasTrustedData == false,
                progress: StatusIconProgress(snapshot: snapshot, selection: selection)
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
    }

    private func observeWorkflowSyncState() {
        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                guard let self else {
                    return
                }

                if isEnabled {
                    workflowSyncScheduler.requestSync()
                } else {
                    workflowSyncScheduler.clearPendingMaintenance()
                }
            }
            .store(in: &cancellables)

        syncSettings.$syncAvailability
            .removeDuplicates()
            .sink { [weak self] availability in
                guard let self else {
                    return
                }

                if availability.isAvailable {
                    workflowSyncScheduler.requestSync()
                } else {
                    workflowSyncScheduler.clearPendingSync()
                }
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
        globalHotKeySettings.restoreShortcut(registeredHotKeyShortcut, message: message)
    }

    private func hotKeyConflictMessage(for shortcut: GlobalHotKeyShortcut) -> String {
        if shortcut == .default {
            return "默认快捷键 \(shortcut.label) 已被占用"
        }

        return "快捷键已被占用"
    }

    private func updateStatusImage(_ state: StatusIconState) {
        statusItem.button?.toolTip = state.toolTip

        guard state != statusIconState else {
            return
        }

        let previousState = statusIconState
        statusIconAnimationTask?.cancel()
        statusIconState = state

        guard let previousState else {
            statusItem.button?.image = Self.makeStatusImage(state.symbolName, progress: state.progress)
            return
        }

        if let animation = statusProgressAnimation(
            from: previousState.progress,
            to: state.progress
        ) {
            animateStatusProgress(
                symbolName: state.symbolName,
                progress: animation.progress,
                finalState: state,
                fromVisibility: animation.fromVisibility,
                toVisibility: animation.toVisibility
            )
            return
        }

        statusItem.button?.image = Self.makeStatusImage(state.symbolName, progress: state.progress)
    }

    private func statusProgressAnimation(
        from previousProgress: StatusIconProgress?,
        to progress: StatusIconProgress?
    ) -> (progress: StatusIconProgress, fromVisibility: CGFloat, toVisibility: CGFloat)? {
        switch (previousProgress, progress) {
        case (nil, let progress?):
            (progress, 0, 1)
        case (let progress?, nil):
            (progress, 1, 0)
        default:
            nil
        }
    }

    private func animateStatusProgress(
        symbolName: String,
        progress: StatusIconProgress,
        finalState: StatusIconState,
        fromVisibility: CGFloat,
        toVisibility: CGFloat
    ) {
        statusIconAnimationTask = Task { @MainActor [weak self] in
            for frame in 0 ... Metrics.statusIconProgressAnimationFrameCount {
                guard let self,
                      !Task.isCancelled,
                      statusIconState == finalState else {
                    return
                }

                let rawProgress = CGFloat(frame) / CGFloat(Metrics.statusIconProgressAnimationFrameCount)
                let easedProgress = Self.easedProgressVisibility(rawProgress)
                let visibility = fromVisibility + (toVisibility - fromVisibility) * easedProgress
                statusItem.button?.image = Self.makeStatusImage(
                    symbolName,
                    progress: progress,
                    progressVisibility: visibility
                )

                if frame < Metrics.statusIconProgressAnimationFrameCount {
                    try? await Task.sleep(
                        nanoseconds: Metrics.statusIconProgressAnimationFrameDelayNanoseconds
                    )
                }
            }

            guard let self,
                  !Task.isCancelled,
                  statusIconState == finalState else {
                return
            }

            statusItem.button?.image = Self.makeStatusImage(symbolName, progress: finalState.progress)
            statusIconAnimationTask = nil
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

    /// toggle 将走「打开」分支的状态谓词, 与 toggleMenuSurface 的分支口径一致
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

        menuSurfaceFadeCoordinator.prepareForFadeIn()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completeMenuSurfaceOpen()
    }

    private func openFallbackPanel(on screen: NSScreen?) {
        cancelMenuSurfaceTasks()

        fallbackPanelController.prepareForDisplay(on: screen)
        menuSurfaceState = .opening
        activeMenuSurface = .fallbackPanel

        menuSurfaceFadeCoordinator.prepareForFadeIn()
        fallbackPanelController.show()
        completeMenuSurfaceOpen()
    }

    private func completeMenuSurfaceOpen() {
        menuSurfaceVisibility.isVisible = true
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
            title: "设置",
            action: #selector(openSettings),
            keyEquivalent: ",",
            symbolName: "gearshape"
        ))

        menu.addItem(menuItem(
            title: "日志",
            action: #selector(openLog),
            keyEquivalent: "l",
            symbolName: "doc.text.magnifyingglass"
        ))

        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q",
            symbolName: "power"
        ))

        return menu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        symbolName: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
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

    private func closeMenuSurface(animated: Bool = true) {
        if menuSurfaceState == .closing, animated {
            return
        }

        cancelMenuSurfaceTasks()
        hideSideDetailPanels()
        menuSurfaceDismissMonitor.remove()
        menuSurfaceVisibility.isVisible = false

        guard isActiveMenuSurfaceVisible else {
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

        menuSurfaceVisibility.isVisible = false
        menuSurfaceFadeCoordinator.resetAlpha()
        menuSurfaceState = .hidden
        activeMenuSurface = .none
        scheduleAuxiliaryWindowKeyFocusRestore()
    }

    private func hideSideDetailPanels() {
        heatmapDetailPanelController.hide(immediate: true)
        resetCreditsPanelController.hide(immediate: true)
    }

    private func isPointInDetailPanel(_ screenPoint: NSPoint) -> Bool {
        heatmapDetailPanelController.containsScreenPoint(screenPoint)
            || resetCreditsPanelController.containsScreenPoint(screenPoint)
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

    private func scheduleDelayedStatusRefresh() {
        delayedStatusRefreshTask?.cancel()
        delayedStatusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, isActiveMenuSurfaceVisible else {
                return
            }

            viewModel.refreshIfNeeded()
        }
    }

    private func refreshWorkflowIfHookEnabled(performMaintenance: Bool) {
        // Hook 开关可能被外部 Codex 配置改动, 每次需要统计前都先读 hooks.json
        codexHookSettings.refresh()
        guard codexHookSettings.isEnabled else {
            workflowSyncScheduler.clearPendingMaintenance()
            return
        }

        if performMaintenance {
            workflowSyncScheduler.requestMaintenance(allowsSync: true)
        } else {
            workflowViewModel.refreshIfNeeded()
        }
    }

    private func handleSyncChanged(_ isEnabled: Bool) {
        if isEnabled {
            workflowSyncScheduler.requestSync()
        } else {
            workflowSyncScheduler.clearPendingSync()
        }
    }

    private var canSynchronizeWorkflow: Bool {
        syncSettings.isEffectivelyActive(isHookEnabled: codexHookSettings.isEnabled)
    }

    private func updateHeatmapDetailPanel(_ context: UsageHeatmapHoverContext?) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            heatmapDetailPanelController.hide(immediate: true)
            return
        }

        if context != nil {
            resetCreditsPanelController.hide()
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

        heatmapDetailPanelController.hide(immediate: true)
        resetCreditsPanelController.toggle(
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
        if popover.isShown {
            popover.performClose(nil)
        }

        fallbackPanelController.orderOut()

        activeMenuSurface = .none
    }

    private enum Metrics {
        static let normalStatusSymbolName = "person.fill.checkmark"
        static let errorStatusSymbolName = "person.fill.xmark"
        static let fadeInDuration: TimeInterval = 0.24
        static let fadeOutDuration: TimeInterval = 0.18
        static let auxiliaryWindowKeyFocusRestoreDelayMilliseconds: UInt64 = 120
        static let minimumTrustedAnchorLength: CGFloat = 1
        static let anchorScreenTolerance: CGFloat = 1
        static let progressStatusSymbolSize = NSSize(width: 24, height: 17)
        static let progressStatusExtraWidth: CGFloat = 3
        static let progressStatusContentOffsetX: CGFloat = 1
        static let progressStatusImageSize = NSSize(
            width: progressStatusSymbolSize.width + progressStatusExtraWidth,
            height: progressStatusSymbolSize.height
        )
        static let progressStatusSymbolRect = NSRect(
            x: progressStatusExtraWidth + progressStatusContentOffsetX,
            y: 0,
            width: progressStatusSymbolSize.width,
            height: progressStatusSymbolSize.height
        )
        static let progressTrackRect = NSRect(
            x: 0.5 + progressStatusContentOffsetX,
            y: 1,
            width: 2,
            height: 15
        )
        static let progressTrackCornerRadius: CGFloat = 1
        static let progressTrackAlpha: CGFloat = 0.34
        static let staleIconAlpha: CGFloat = 0.75
        static let staleProgressAlpha: CGFloat = 0.55
        static let statusIconProgressAnimationDuration: TimeInterval = 0.18
        static let statusIconProgressAnimationFrameCount = 10
        static let statusIconProgressAnimationFrameDelayNanoseconds = UInt64(
            statusIconProgressAnimationDuration
                / Double(statusIconProgressAnimationFrameCount)
                * 1000000000
        )
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
