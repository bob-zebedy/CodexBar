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
    private let keepAliveController: KeepAliveController
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
        keepAliveController: KeepAliveController,
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
        self.keepAliveController = keepAliveController
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
                keepAliveController: keepAliveController,
                onSyncChanged: onSyncChanged,
                onRebuildWorkflowData: onRebuildWorkflowData,
                onNotificationOptionsAction: { [weak self] action in
                    self?.handleNotificationOptionsAction(action)
                },
                onContentHeightChanged: { [weak self] height in
                    self?.resizeContentHeight(height)
                }
            )
            .environmentObject(viewModel)
            .environmentObject(appUpdater)
        )
        hostingController.sizingOptions = []

        let window = AuxiliaryHostingWindow(contentViewController: hostingController)
        window.title = "CodexBar 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.contentMinSize = Metrics.minimumContentSize
        window.setContentSize(Metrics.initialContentSize)
        return window
    }

    override func prepareForDisplay(_ window: NSWindow) {
        window.setContentSize(clampedContentSize(window.contentLayoutRect.size, for: window))
        positionForTabResizing(window)
    }

    private enum Metrics {
        static let minimumContentSize = NSSize(width: 420, height: 240)
        static let initialContentSize = NSSize(width: 430, height: 270)
        static let maximumFallbackContentSize = NSSize(width: 560, height: 720)
        static let maximumPreferredContentHeight: CGFloat = 500
        static let screenInset: CGFloat = 80
    }

    private func refreshSettingsState() {
        codexHookSettings.refresh()
        codexHookSettings.verifyInstalledHooks()
        codexCLINotificationSettings.refresh()
        syncSettings.refresh()
        menuBarQuotaSettings.refresh()
        mainPanelSettings.refresh()
        keepAliveController.refresh()
    }

    private func handleNotificationOptionsAction(_ action: NotificationOptionsPanelAction) {
        switch action {
        case .toggle:
            notificationOptionsPanelController.toggle(
                relativeTo: window,
                contentView: window?.contentViewController?.view
            )
        case .open:
            notificationOptionsPanelController.show(
                relativeTo: window,
                contentView: window?.contentViewController?.view
            )
        case .close:
            notificationOptionsPanelController.hide()
        }
    }

    private func resizeContentHeight(_ height: CGFloat) {
        guard let window else {
            return
        }

        let currentContentSize = window.contentLayoutRect.size
        let targetContentSize = clampedContentSize(
            NSSize(
                width: currentContentSize.width,
                height: min(height, Metrics.maximumPreferredContentHeight)
            ),
            for: window
        )
        let targetFrameHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).height
        guard abs(window.frame.height - targetFrameHeight) > 0.5 else {
            return
        }

        var targetFrame = window.frame
        let topEdge = targetFrame.maxY
        targetFrame.size.height = targetFrameHeight
        targetFrame.origin.y = topEdge - targetFrame.height
        targetFrame = constrainedFrame(targetFrame, for: window)
        window.setFrame(targetFrame, display: true)
    }

    private func positionForTabResizing(_ window: NSWindow) {
        guard let screen = screenProvider() ?? window.screen ?? NSScreen.main else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame
        let maximumContentHeight = min(
            maximumContentSize(for: window).height,
            Metrics.maximumPreferredContentHeight
        )
        let maximumFrameHeight = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: window.contentLayoutRect.width,
                    height: maximumContentHeight
                )
            )
        ).height
        let reservedTopEdge = visibleFrame.midY - maximumFrameHeight / 2 + maximumFrameHeight
        window.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - window.frame.width / 2,
                y: reservedTopEdge - window.frame.height
            )
        )
    }

    private func constrainedFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let screen = screenProvider() ?? window.screen ?? NSScreen.main else {
            return frame
        }

        var constrainedFrame = frame
        let visibleFrame = screen.visibleFrame
        if constrainedFrame.minY < visibleFrame.minY {
            constrainedFrame.origin.y = visibleFrame.minY
        }
        if constrainedFrame.maxY > visibleFrame.maxY {
            constrainedFrame.origin.y = visibleFrame.maxY - constrainedFrame.height
        }
        return constrainedFrame
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
