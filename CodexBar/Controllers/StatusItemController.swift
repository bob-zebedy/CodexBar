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
    let appUpdater = AppUpdater()

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_: Notification) {
        let controller = StatusItemController(
            viewModel: viewModel,
            workflowViewModel: workflowViewModel,
            codexHookSettings: codexHookSettings,
            syncSettings: syncSettings,
            globalHotKeySettings: globalHotKeySettings,
            appUpdater: appUpdater
        )
        controller.install()
        statusItemController = controller
    }

    func applicationWillTerminate(_: Notification) {
        statusItemController?.uninstall()
    }
}

/// 菜单栏入口控制器, 统一管理状态图标, 菜单面板, 右键菜单和全局快捷键
@MainActor
private final class StatusItemController: NSObject {
    private let viewModel: CodexStatusViewModel
    private let workflowViewModel: WorkflowViewModel
    private let codexHookSettings: CodexHookSettings
    private let syncSettings: WorkflowSyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menuSurfaceVisibility = MenuSurfaceVisibilityState()
    private let heatmapDetailPanelController = HeatmapDetailPanelController()
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
        globalHotKeySettings: globalHotKeySettings
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
        }
    )
    private var delayedStatusRefreshTask: Task<Void, Never>?
    private var menuSurfaceState = MenuSurfaceState.hidden
    private var cancellables = Set<AnyCancellable>()
    private var isShowingErrorImage: Bool?
    private var registeredHotKeyShortcut: GlobalHotKeyShortcut?
    private var auxiliaryWindowFocusRestoreTask: Task<Void, Never>?

    private static let normalImage = makeStatusImage("person.fill.checkmark")
    private static let errorImage = makeStatusImage("person.fill.xmark")

    init(
        viewModel: CodexStatusViewModel,
        workflowViewModel: WorkflowViewModel,
        codexHookSettings: CodexHookSettings,
        syncSettings: WorkflowSyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        appUpdater: AppUpdater
    ) {
        self.viewModel = viewModel
        self.workflowViewModel = workflowViewModel
        self.codexHookSettings = codexHookSettings
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.appUpdater = appUpdater
        super.init()
    }

    private static func makeStatusImage(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .regular,
            scale: .medium
        )
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
    }

    func install() {
        configureStatusButton()
        configurePopover()
        observeGlobalHotKeySettings()
        observeViewModel()
        observeWorkflowSyncState()
        codexHookSettings.refresh()
        updateStatusImage()
        viewModel.startAutoRefresh()
    }

    func uninstall() {
        closeMenuSurface(animated: false)
        auxiliaryWindowFocusRestoreTask?.cancel()
        workflowSyncScheduler.cancel()
        setAuxiliaryWindowKeyFocus(true)
        globalHotKeyController.uninstall()
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.imagePosition = .imageOnly
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
        Publishers.CombineLatest(viewModel.$loadState, viewModel.$snapshot)
            .map { loadState, snapshot in
                loadState.isError || snapshot?.hasTrustedData == false
            }
            .removeDuplicates()
            .sink { [weak self] usesErrorImage in
                self?.updateStatusImage(usesErrorImage: usesErrorImage)
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
            return "默认快捷键 \(shortcut.label) 已被占用，请重新设置"
        }

        return "快捷键已被占用，请重新设置"
    }

    private func updateStatusImage() {
        updateStatusImage(usesErrorImage: viewModel.usesErrorImage)
    }

    private func updateStatusImage(usesErrorImage: Bool) {
        guard usesErrorImage != isShowingErrorImage else {
            return
        }

        isShowingErrorImage = usesErrorImage
        statusItem.button?.image = usesErrorImage ? Self.errorImage : Self.normalImage
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

    private func toggleMenuSurfaceFromHotKey() {
        let targetScreen = screenContainingMouse() ?? NSScreen.main
        toggleMenuSurface {
            openMenuSurfaceFromHotKey(on: targetScreen)
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
        guard buttonScreenRect.hasFiniteGeometry,
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

    private func screenContainingMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        }
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
        menuSurfaceDismissMonitor.install { [weak self] in
            self?.closeMenuSurface()
        }

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
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        button.performClick(nil)
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
        settingsWindowController.open()
    }

    @objc private func openLog() {
        logWindowController.open()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func closeMenuSurface(animated: Bool = true) {
        if menuSurfaceState == .closing, animated {
            return
        }

        cancelMenuSurfaceTasks()
        heatmapDetailPanelController.hide(immediate: true, delayed: false)
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
            heatmapDetailPanelController.hide(immediate: true)
        }
        menuSurfaceDismissMonitor.remove()

        closeActiveMenuSurface()

        menuSurfaceVisibility.isVisible = false
        menuSurfaceFadeCoordinator.resetAlpha()
        menuSurfaceState = .hidden
        activeMenuSurface = .none
        scheduleAuxiliaryWindowKeyFocusRestore()
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
        codexHookSettings.isEnabled
            && WorkflowSyncSettings.isEnabled()
            && syncSettings.isSyncAvailable
    }

    private func updateHeatmapDetailPanel(_ context: UsageHeatmapHoverContext?) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            heatmapDetailPanelController.hide(immediate: true)
            return
        }

        heatmapDetailPanelController.update(
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

private extension CGRect {
    var hasFiniteGeometry: Bool {
        origin.x.isFinite &&
            origin.y.isFinite &&
            size.width.isFinite &&
            size.height.isFinite
    }
}
