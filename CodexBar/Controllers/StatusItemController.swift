import AppKit
import Combine
import SwiftUI

@MainActor
final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = CodexStatusViewModel()
    let workflowStatsViewModel = WorkflowStatsViewModel()
    let codexHookSettings = CodexHookSettings()
    let appUpdater = AppUpdater()
    
    private var statusItemController: StatusItemController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController(
            viewModel: viewModel,
            workflowStatsViewModel: workflowStatsViewModel,
            codexHookSettings: codexHookSettings,
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
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let popoverVisibility = PopoverVisibilityState()
    
    private lazy var settingsWindowController = SettingsWindowController(
        viewModel: viewModel,
        appUpdater: appUpdater,
        codexHookSettings: codexHookSettings
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
    
    private static let normalImage = makeStatusImage("person.fill.checkmark")
    private static let errorImage = makeStatusImage("person.fill.xmark")
    
    init(
        viewModel: CodexStatusViewModel,
        workflowStatsViewModel: WorkflowStatsViewModel,
        codexHookSettings: CodexHookSettings,
        appUpdater: AppUpdater
    ) {
        self.viewModel = viewModel
        self.workflowStatsViewModel = workflowStatsViewModel
        self.codexHookSettings = codexHookSettings
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
        observeViewModel()
        updateStatusImage()
        viewModel.startAutoRefresh()
    }
    
    func uninstall() {
        closePopover(animated: false)
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
            popoverVisibility: popoverVisibility
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
                guard let self, self.popover.isShown else {
                    return
                }
                self.refreshWorkflowStatsIfHookEnabled()
            }
            .store(in: &cancellables)
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
        refreshWorkflowStatsIfHookEnabled()
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
        
        let settingsItem = NSMenuItem(
            title: "设置",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        let logItem = NSMenuItem(
            title: "日志",
            action: #selector(openLog),
            keyEquivalent: "l"
        )
        logItem.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        logItem.target = self
        menu.addItem(logItem)
        
        menu.addItem(.separator())
        
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        quitItem.target = self
        menu.addItem(quitItem)
        
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
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
        popoverDismissMonitor.remove()
        popoverVisibility.isVisible = false
        
        guard popover.isShown else {
            popoverFadeCoordinator.resetAlpha()
            popoverState = .hidden
            return
        }
        
        guard animated else {
            finishPopoverClose()
            return
        }
        
        popoverState = .closing
        let didStartFadeOut = popoverFadeCoordinator.fadeOut(duration: Metrics.fadeOutDuration) { [weak self] in
            self?.popoverState = .hidden
        }
        
        if !didStartFadeOut {
            finishPopoverClose()
        }
    }
    
    private func finishPopoverClose() {
        cancelPopoverTasks()
        popoverDismissMonitor.remove()
        
        if popover.isShown {
            popover.performClose(nil)
        }
        
        popoverVisibility.isVisible = false
        popoverFadeCoordinator.resetAlpha()
        popoverState = .hidden
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
    
    private func refreshWorkflowStatsIfHookEnabled() {
        codexHookSettings.refresh()
        if codexHookSettings.isEnabled {
            workflowStatsViewModel.refreshIfNeeded()
        }
    }
    
    private enum Metrics {
        static let fadeInDuration: TimeInterval = 0.24
        static let fadeOutDuration: TimeInterval = 0.18
    }
    
    private enum PopoverState {
        case hidden
        case opening
        case shown
        case closing
    }
}
