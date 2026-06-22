import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = CodexStatusViewModel()
    let workflowStatsViewModel = WorkflowStatsViewModel()
    let codexHookSettings = CodexHookSettings()
    let globalHotKeySettings = GlobalHotKeySettings()
    let appUpdater = AppUpdater()
    
    private var statusItemController: StatusItemController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(
            viewModel: viewModel,
            workflowStatsViewModel: workflowStatsViewModel,
            codexHookSettings: codexHookSettings,
            globalHotKeySettings: globalHotKeySettings,
            appUpdater: appUpdater
        )
        controller.install()
        statusItemController = controller
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.uninstall()
    }
}

@MainActor
private final class StatusItemController: NSObject {
    private let viewModel: CodexStatusViewModel
    private let workflowStatsViewModel: WorkflowStatsViewModel
    private let codexHookSettings: CodexHookSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverVisibility = PopoverVisibilityState()
    private let heatmapDetailPanelController = HeatmapDetailPanelController()
    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.togglePopoverFromHotKey()
    }
    
    private lazy var settingsWindowController = SettingsWindowController(
        viewModel: viewModel,
        appUpdater: appUpdater,
        codexHookSettings: codexHookSettings,
        globalHotKeySettings: globalHotKeySettings
    ) { [weak self] in
        self?.statusItem.button?.window?.screen
    }
    private lazy var logWindowController = LogWindowController { [weak self] in
        self?.statusItem.button?.window?.screen
    }
    private lazy var popoverFadeCoordinator = PopoverFadeCoordinator(popover: popover)
    private lazy var popoverDismissMonitor = PopoverDismissMonitor(popover: popover) { [weak self] in
        self?.statusItem.button
    }
    private var deferredRefreshTask: Task<Void, Never>?
    private var popoverState = PopoverState.hidden
    private var cancellables = Set<AnyCancellable>()
    private var isShowingErrorImage: Bool?
    private var registeredHotKeyShortcut: GlobalHotKeyShortcut?
    private var auxiliaryWindowFocusRestoreTask: Task<Void, Never>?
    
    private static let normalImage = makeStatusImage("person.fill.checkmark")
    private static let errorImage = makeStatusImage("person.fill.xmark")
    
    init(
        viewModel: CodexStatusViewModel,
        workflowStatsViewModel: WorkflowStatsViewModel,
        codexHookSettings: CodexHookSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        appUpdater: AppUpdater
    ) {
        self.viewModel = viewModel
        self.workflowStatsViewModel = workflowStatsViewModel
        self.codexHookSettings = codexHookSettings
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
        updateStatusImage()
        viewModel.startAutoRefresh()
    }
    
    func uninstall() {
        closePopover(animated: false)
        auxiliaryWindowFocusRestoreTask?.cancel()
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
        button.toolTip = "CodexBar"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    
    private func configurePopover() {
        let rootView = CodexStatusMenuView(
            viewModel: viewModel,
            workflowStatsViewModel: workflowStatsViewModel,
            codexHookSettings: codexHookSettings,
            popoverVisibility: popoverVisibility,
            onUsageHeatmapHoverChange: { [weak self] context in
                self?.updateHeatmapDetailPanel(context)
            }
        )
            .environmentObject(appUpdater)
            .frame(width: CodexStatusMenuView.menuWidth)
        
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = hostingController
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
            .compactMap { $0 }
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                self.refreshWorkflowStatsIfHookEnabled(performMaintenance: true)
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
            togglePopover(relativeTo: sender)
            return
        }
        
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(relativeTo: sender)
        } else {
            togglePopover(relativeTo: sender)
        }
    }
    
    private func togglePopover(relativeTo button: NSStatusBarButton) {
        switch popoverState {
        case .hidden:
            openPopover(relativeTo: button)
        case .opening, .shown:
            closePopover()
        case .closing:
            finishPopoverClose()
            openPopover(relativeTo: button)
        }
    }
    
    private func togglePopoverFromHotKey() {
        guard let button = statusItem.button else {
            return
        }
        
        togglePopover(relativeTo: button)
    }
    
    private func cancelPopoverTasks() {
        deferredRefreshTask?.cancel()
        deferredRefreshTask = nil
        popoverFadeCoordinator.cancel()
    }
    
    private func openPopover(relativeTo button: NSStatusBarButton) {
        cancelPopoverTasks()
        
        popoverState = .opening
        
        popoverFadeCoordinator.prepareForFadeIn()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverVisibility.isVisible = true
        refreshWorkflowStatsIfHookEnabled(performMaintenance: false)
        popoverDismissMonitor.install { [weak self] in
            self?.closePopover()
        }
        
        popoverFadeCoordinator.fadeIn(duration: Metrics.fadeInDuration) { [weak self] in
            self?.popoverState = .shown
        }
        
        scheduleDeferredRefresh()
    }
    
    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        closePopover(animated: false)
        
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
        
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
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
    
    private func closePopover(animated: Bool = true) {
        if popoverState == .closing && animated {
            return
        }
        
        cancelPopoverTasks()
        heatmapDetailPanelController.hide(immediate: true, delayed: false)
        popoverDismissMonitor.remove()
        popoverVisibility.isVisible = false
        
        guard popover.isShown else {
            popoverFadeCoordinator.resetAlpha()
            popoverState = .hidden
            return
        }
        
        guard animated else {
            suspendAuxiliaryWindowKeyFocus()
            finishPopoverClose(hidesDetailPanel: false)
            return
        }
        
        suspendAuxiliaryWindowKeyFocus()
        popoverState = .closing
        let didStartFadeOut = popoverFadeCoordinator.fadeOut(duration: Metrics.fadeOutDuration) { [weak self] in
            self?.popoverState = .hidden
            self?.scheduleAuxiliaryWindowKeyFocusRestore()
        }
        
        if !didStartFadeOut {
            finishPopoverClose()
        }
    }
    
    private func finishPopoverClose(hidesDetailPanel: Bool = true) {
        cancelPopoverTasks()
        if hidesDetailPanel {
            heatmapDetailPanelController.hide(immediate: true)
        }
        popoverDismissMonitor.remove()
        
        if popover.isShown {
            popover.performClose(nil)
        }
        
        popoverVisibility.isVisible = false
        popoverFadeCoordinator.resetAlpha()
        popoverState = .hidden
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
            
            self.setAuxiliaryWindowKeyFocus(true)
            self.auxiliaryWindowFocusRestoreTask = nil
        }
    }
    
    private func setAuxiliaryWindowKeyFocus(_ allowsKeyFocus: Bool) {
        settingsWindowController.setAllowsKeyFocus(allowsKeyFocus)
        logWindowController.setAllowsKeyFocus(allowsKeyFocus)
    }
    
    private func scheduleDeferredRefresh() {
        deferredRefreshTask?.cancel()
        deferredRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, self.popover.isShown else {
                return
            }
            
            self.viewModel.refreshIfNeeded()
        }
    }
    
    private func refreshWorkflowStatsIfHookEnabled(performMaintenance: Bool) {
        codexHookSettings.refresh()
        if codexHookSettings.isEnabled {
            workflowStatsViewModel.refreshIfNeeded(performMaintenance: performMaintenance)
        }
    }
    
    private func updateHeatmapDetailPanel(_ context: UsageHeatmapHoverContext?) {
        guard popover.isShown,
              let popoverContentView = popover.contentViewController?.view,
              let popoverWindow = popoverContentView.window else {
            heatmapDetailPanelController.hide(immediate: true)
            return
        }
        
        heatmapDetailPanelController.update(
            context: context,
            relativeTo: popoverWindow,
            contentView: popoverContentView
        )
    }
    
    private enum Metrics {
        static let fadeInDuration: TimeInterval = 0.24
        static let fadeOutDuration: TimeInterval = 0.18
        static let auxiliaryWindowKeyFocusRestoreDelayMilliseconds: UInt64 = 120
    }
    
    private enum PopoverState {
        case hidden
        case opening
        case shown
        case closing
    }
}
