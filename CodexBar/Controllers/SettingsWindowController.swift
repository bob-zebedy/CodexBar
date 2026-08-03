import AppKit
import Combine
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
    /// 只在真的要展开时构造: 控制器一建就挂上内容变化订阅并常驻到 App 结束
    /// 而用户可能一次子面板都没开过
    private var notificationOptionsPanelController: SettingsOptionsPanelController?
    private var keepAliveOptionsPanelController: SettingsOptionsPanelController?

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
                onOptionsAction: { [weak self] action in
                    self?.handleOptionsAction(action)
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

    private func optionsPanelController(
        _ panel: SettingsOptionsPanel
    ) -> SettingsOptionsPanelController {
        if let existing = existingOptionsPanelController(panel) {
            return existing
        }

        let controller = makeOptionsPanelController(panel)
        switch panel {
        case .notification:
            notificationOptionsPanelController = controller
        case .keepAlive:
            keepAliveOptionsPanelController = controller
        }
        return controller
    }

    /// 没建过就说明它不可能开着, 收起动作不必为此把它构造出来
    private func existingOptionsPanelController(
        _ panel: SettingsOptionsPanel
    ) -> SettingsOptionsPanelController? {
        switch panel {
        case .notification:
            notificationOptionsPanelController
        case .keepAlive:
            keepAliveOptionsPanelController
        }
    }

    private func makeOptionsPanelController(
        _ panel: SettingsOptionsPanel
    ) -> SettingsOptionsPanelController {
        switch panel {
        case .notification:
            SettingsOptionsPanelController(
                animationKey: "CodexBar.notificationOptionsDrawerTransform",
                initialPanelSize: NotificationOptionsView.initialPanelSize,
                willShow: { [codexCLINotificationSettings] in
                    codexCLINotificationSettings.refresh()
                },
                contentControllerProvider: { [notificationSettings, codexHookSettings, codexCLINotificationSettings, keepAliveController] entryCue in
                    SettingsOptionsPanelController.makeContentController(
                        NotificationOptionsView(
                            notificationSettings: notificationSettings,
                            codexHookSettings: codexHookSettings,
                            codexCLINotificationSettings: codexCLINotificationSettings,
                            keepAliveController: keepAliveController
                        ),
                        rebuiltBy: entryCue
                    )
                },
                // 音效子行随各开关增删, 低电量与上限那两行还跟着各自的依赖置灰
                // 置灰会连带收起音效子行, 所以两个依赖的派生值都要订上
                // 防睡眠只订这两个派生值: 订整个控制器会让任务每起停一次都白重算一次高度
                contentChanges: Publishers.MergeMany([
                    notificationSettings.objectWillChange.eraseToAnyPublisher(),
                    codexHookSettings.objectWillChange.eraseToAnyPublisher(),
                    keepAliveController.$isLowBatteryProtectionEnabled
                        .map { _ in () }
                        .eraseToAnyPublisher(),
                    keepAliveController.$isMaximumDurationEnabled
                        .map { _ in () }
                        .eraseToAnyPublisher()
                ]).eraseToAnyPublisher()
            )
        case .keepAlive:
            SettingsOptionsPanelController(
                animationKey: "CodexBar.keepAliveOptionsDrawerTransform",
                initialPanelSize: KeepAliveOptionsView.initialPanelSize,
                contentControllerProvider: { [keepAliveController] entryCue in
                    SettingsOptionsPanelController.makeContentController(
                        KeepAliveOptionsView(keepAliveController: keepAliveController),
                        rebuiltBy: entryCue
                    )
                },
                // 面板里只有 hasBattery 会增删行, 其余各行的取值不改高度
                contentChanges: keepAliveController.$hasBattery
                    .map { _ in () }
                    .eraseToAnyPublisher()
            )
        }
    }

    /// 子面板占设置窗口右侧同一位置, 展开一个必须先收掉其余的
    /// 收旧面板用 immediate, 否则滑回与滑出在同一处交叠
    /// 互斥规则只写在这里, 再加一个面板也不会漏掉某一对
    private func handleOptionsAction(_ action: SettingsOptionsPanelAction) {
        switch action {
        case let .toggle(panel, anchorProvider):
            for other in SettingsOptionsPanel.allCases where other != panel {
                existingOptionsPanelController(other)?.hide(immediate: true)
            }
            optionsPanelController(panel).toggle(
                relativeTo: window,
                contentView: window?.contentViewController?.view,
                anchorProvider: anchorProvider
            )
        case let .close(panel):
            existingOptionsPanelController(panel)?.hide()
        case .closeAll:
            for panel in SettingsOptionsPanel.allCases {
                existingOptionsPanelController(panel)?.hide()
            }
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
