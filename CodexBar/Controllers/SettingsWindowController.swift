import AppKit
import SwiftUI

/// 设置窗口控制器, 打开前刷新设置状态并按内容自适应高度
@MainActor
final class SettingsWindowController: HostingWindowController {
    private let viewModel: CodexStatusViewModel
    private let appUpdater: AppUpdater
    private let codexHookSettings: CodexHookSettings
    private let codexCLINotificationSettings: CodexCLINotificationSettings
    private let syncSettings: WorkflowSyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let menuBarQuotaSettings: MenuBarQuotaSettings
    private let mainPanelSettings: MainPanelSettings
    private let notificationSettings: NotificationSettings
    private let onSyncChanged: (Bool) -> Void
    private let onRebuildWorkflowData: WorkflowSyncScheduler.RebuildHandler
    private lazy var notificationOptionsPanelController = NotificationOptionsPanelController(
        notificationSettings: notificationSettings,
        codexHookSettings: codexHookSettings,
        codexCLINotificationSettings: codexCLINotificationSettings
    )

    init(
        viewModel: CodexStatusViewModel,
        appUpdater: AppUpdater,
        codexHookSettings: CodexHookSettings,
        codexCLINotificationSettings: CodexCLINotificationSettings,
        syncSettings: WorkflowSyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        menuBarQuotaSettings: MenuBarQuotaSettings,
        mainPanelSettings: MainPanelSettings,
        notificationSettings: NotificationSettings,
        screenProvider: @escaping () -> NSScreen?,
        onSyncChanged: @escaping (Bool) -> Void,
        onRebuildWorkflowData: @escaping WorkflowSyncScheduler.RebuildHandler
    ) {
        self.viewModel = viewModel
        self.appUpdater = appUpdater
        self.codexHookSettings = codexHookSettings
        self.codexCLINotificationSettings = codexCLINotificationSettings
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.menuBarQuotaSettings = menuBarQuotaSettings
        self.mainPanelSettings = mainPanelSettings
        self.notificationSettings = notificationSettings
        self.onSyncChanged = onSyncChanged
        self.onRebuildWorkflowData = onRebuildWorkflowData
        super.init(screenProvider: screenProvider)
    }

    override func open() {
        refreshSettingsState()
        super.open()
        NotificationCenter.default.post(name: .settingsWindowDidOpen, object: nil)
    }

    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppSettingsView(
                codexHookSettings: codexHookSettings,
                syncSettings: syncSettings,
                globalHotKeySettings: globalHotKeySettings,
                menuBarQuotaSettings: menuBarQuotaSettings,
                mainPanelSettings: mainPanelSettings,
                notificationSettings: notificationSettings,
                onSyncChanged: onSyncChanged,
                onRebuildWorkflowData: onRebuildWorkflowData,
                onNotificationOptionsAction: { [weak self] action in
                    self?.handleNotificationOptionsAction(action)
                }
            )
            .environmentObject(viewModel)
            .environmentObject(appUpdater)
        )
        hostingController.sizingOptions = [.preferredContentSize]

        let window = AuxiliaryHostingWindow(contentViewController: hostingController)
        window.title = "CodexBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.contentMinSize = Metrics.minimumContentSize
        return window
    }

    override func prepareForDisplay(_ window: NSWindow) {
        if let fittingSize = window.contentViewController?.view.validFittingSize {
            window.setContentSize(clampedContentSize(fittingSize, for: window))
        }

        super.prepareForDisplay(window)
    }

    private enum Metrics {
        static let minimumContentSize = NSSize(width: 420, height: 240)
        static let maximumFallbackContentSize = NSSize(width: 560, height: 720)
        static let screenInset: CGFloat = 80
    }

    private func refreshSettingsState() {
        codexHookSettings.refresh()
        codexHookSettings.verifyInstalledHooks()
        codexCLINotificationSettings.refresh()
        syncSettings.refresh()
        menuBarQuotaSettings.refresh()
        mainPanelSettings.refresh()
    }

    private func handleNotificationOptionsAction(_ action: NotificationOptionsPanelAction) {
        switch action {
        case let .toggle(alignmentFrame):
            notificationOptionsPanelController.toggle(
                alignmentScreenFrame: alignmentFrame,
                relativeTo: window,
                contentView: window?.contentViewController?.view
            )
        case let .open(alignmentFrame):
            notificationOptionsPanelController.show(
                alignmentScreenFrame: alignmentFrame,
                relativeTo: window,
                contentView: window?.contentViewController?.view
            )
        case .close:
            notificationOptionsPanelController.hide()
        }
    }

    private func maximumContentSize(for window: NSWindow) -> NSSize {
        guard let screen = screenProvider() ?? window.screen ?? NSScreen.main else {
            return Metrics.maximumFallbackContentSize
        }

        return NSSize(
            width: clampedContentDimension(
                screen.visibleFrame.width - Metrics.screenInset,
                minimum: Metrics.minimumContentSize.width,
                maximum: Metrics.maximumFallbackContentSize.width
            ),
            height: clampedContentDimension(
                screen.visibleFrame.height - Metrics.screenInset,
                minimum: Metrics.minimumContentSize.height,
                maximum: Metrics.maximumFallbackContentSize.height
            )
        )
    }

    private func clampedContentSize(_ fittingSize: NSSize, for window: NSWindow) -> NSSize {
        let maximumContentSize = maximumContentSize(for: window)
        return NSSize(
            width: clampedContentDimension(
                fittingSize.width,
                minimum: Metrics.minimumContentSize.width,
                maximum: maximumContentSize.width
            ),
            height: clampedContentDimension(
                fittingSize.height,
                minimum: Metrics.minimumContentSize.height,
                maximum: maximumContentSize.height
            )
        )
    }

    private func clampedContentDimension(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(maximum, max(minimum, value))
    }
}

nonisolated extension Notification.Name {
    static let settingsWindowDidOpen = Notification.Name("CodexBar.settingsWindowDidOpen")
}
