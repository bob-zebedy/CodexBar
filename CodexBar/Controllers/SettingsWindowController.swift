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
    private let autoResetSettings: AutoResetSettings
    private let activityProtectionSettings: ActivityProtectionSettings
    private let keepAliveController: KeepAliveController
    private let onSyncChanged: (Bool) -> Void
    private let onRebuildWorkflowData: WorkflowSyncScheduler.RebuildHandler
    private let mainPanelUndoManager = UndoManager()
    private var windowFocusObserver: AnyCancellable?
    /// 只在真的要展开时构造: hosting controller 与动态面板订阅会常驻到 App 结束, 而用户可能一次子面板都没开过
    private var optionsPanelControllers: [SettingsOptionsPanel: SettingsOptionsPanelController] = [:]
    private var optionsDismissEventMonitor: Any?
    private var optionsDismissFocusObserver: AnyCancellable?
    private var optionsDismissWindowObserver: NSObjectProtocol?
    private var optionsDismissedByClick: (panel: SettingsOptionsPanel, event: NSEvent)?
    /// 首次构造窗口时 SwiftUI 可能先于 window 赋值上报高度 因此必须保留最近一次测量
    private var preferredContentHeight: CGFloat?

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
        autoResetSettings: AutoResetSettings,
        activityProtectionSettings: ActivityProtectionSettings,
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
        self.autoResetSettings = autoResetSettings
        self.activityProtectionSettings = activityProtectionSettings
        self.keepAliveController = keepAliveController
        self.onSyncChanged = onSyncChanged
        self.onRebuildWorkflowData = onRebuildWorkflowData
        super.init(screenProvider: screenProvider)
    }

    override func open() {
        refreshSettingsState()
        super.open()
        installOptionsDismissMonitor()
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
                autoResetSettings: autoResetSettings,
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
        window.sharedUndoManager = mainPanelUndoManager
        window.title = String(localized: "settings.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.contentMinSize = Metrics.minimumContentSize
        window.setContentSize(Metrics.initialContentSize)
        // LSUIElement 窗口重新获得焦点时不一定伴随 App 激活事件
        windowFocusObserver = NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification, object: window)
            .sink { [weak notificationSettings] _ in
                notificationSettings?.refreshAuthorizationStatus()
            }
        return window
    }

    override func prepareForDisplay(_ window: NSWindow) {
        var targetContentSize = window.contentLayoutRect.size
        targetContentSize.height = preferredContentHeight ?? targetContentSize.height
        window.setContentSize(clampedContentSize(targetContentSize, for: window))
        positionForTabResizing(window)
    }

    private enum Metrics {
        static let minimumContentSize = NSSize(width: 420, height: 240)
        static let initialContentSize = NSSize(width: 430, height: 270)
        static let maximumFallbackContentSize = NSSize(width: 560, height: 720)
        /// 只用于首次定位的稳定顶边基准 不限制页面自适应高度
        static let topEdgeReferenceContentHeight: CGFloat = 500
        static let screenInset: CGFloat = 80
    }

    private func refreshSettingsState() {
        notificationSettings.refreshAuthorizationStatus()
        codexHookSettings.reconcileInstalledHooks()
        codexCLINotificationSettings.refresh()
        syncSettings.refresh()
        menuBarQuotaSettings.refresh()
        mainPanelSettings.refresh()
        autoResetSettings.refresh()
        activityProtectionSettings.refresh()
        keepAliveController.refresh()
    }

    private func optionsPanelController(
        _ panel: SettingsOptionsPanel
    ) -> SettingsOptionsPanelController {
        if let existing = existingOptionsPanelController(panel) {
            return existing
        }

        let controller = makeOptionsPanelController(panel)
        optionsPanelControllers[panel] = controller
        return controller
    }

    /// 没建过就说明它不可能开着, 收起动作不必为此把它构造出来
    private func existingOptionsPanelController(
        _ panel: SettingsOptionsPanel
    ) -> SettingsOptionsPanelController? {
        optionsPanelControllers[panel]
    }

    private func makeOptionsPanelController(
        _ panel: SettingsOptionsPanel
    ) -> SettingsOptionsPanelController {
        switch panel {
        case .mainPanel:
            makeMainPanelOptionsPanelController()
        case .notification:
            SettingsOptionsPanelController(
                animationKey: "CodexBar.notificationOptionsDrawerTransform",
                initialPanelSize: NotificationOptionsView.initialPanelSize,
                willShow: { [codexCLINotificationSettings] in
                    codexCLINotificationSettings.refresh()
                },
                contentProvider: { [notificationSettings, codexHookSettings, codexCLINotificationSettings, autoResetSettings, keepAliveController] in
                    NotificationOptionsView(
                        notificationSettings: notificationSettings,
                        codexHookSettings: codexHookSettings,
                        codexCLINotificationSettings: codexCLINotificationSettings,
                        autoResetSettings: autoResetSettings,
                        keepAliveController: keepAliveController
                    )
                },
                // 音效子行随各开关增删, 自动重置 低电量与上限三行还跟着各自的依赖置灰
                // 置灰会连带收起音效子行, 所以三个依赖的派生值都要订上
                // 防睡眠只订这两个派生值: 订整个控制器会让任务每起停一次都白重算一次高度
                contentChanges: Publishers.MergeMany([
                    notificationSettings.objectWillChange.eraseToAnyPublisher(),
                    codexHookSettings.objectWillChange.eraseToAnyPublisher(),
                    autoResetSettings.$isEnabled
                        .map { _ in () }
                        .eraseToAnyPublisher(),
                    keepAliveController.$isLowBatteryProtectionEnabled
                        .map { _ in () }
                        .eraseToAnyPublisher(),
                    keepAliveController.$isMaximumDurationEnabled
                        .map { _ in () }
                        .eraseToAnyPublisher()
                ]).eraseToAnyPublisher()
            )
        case .autoReset:
            SettingsOptionsPanelController(
                animationKey: "CodexBar.autoResetOptionsDrawerTransform",
                initialPanelSize: AutoResetOptionsView.initialPanelSize,
                contentProvider: { [autoResetSettings] in
                    AutoResetOptionsView(settings: autoResetSettings)
                }
            )
        case .keepAlive:
            SettingsOptionsPanelController(
                animationKey: "CodexBar.keepAliveOptionsDrawerTransform",
                initialPanelSize: KeepAliveOptionsView.initialPanelSize,
                contentProvider: { [keepAliveController, activityProtectionSettings] in
                    KeepAliveOptionsView(
                        keepAliveController: keepAliveController,
                        activityProtectionSettings: activityProtectionSettings
                    )
                },
                // 面板里只有 hasBattery 会增删行, 其余各行的取值不改高度
                contentChanges: keepAliveController.$hasBattery
                    .map { _ in () }
                    .eraseToAnyPublisher()
            )
        }
    }

    private func makeMainPanelOptionsPanelController() -> SettingsOptionsPanelController {
        SettingsOptionsPanelController(
            animationKey: "CodexBar.mainPanelOptionsDrawerTransform",
            initialPanelSize: MainPanelOptionsView.initialPanelSize,
            willShow: { [mainPanelSettings] in
                mainPanelSettings.refresh()
            },
            contentProvider: { [mainPanelSettings, codexHookSettings, mainPanelUndoManager] in
                MainPanelOptionsView(
                    settings: mainPanelSettings,
                    codexHookSettings: codexHookSettings,
                    undoManager: mainPanelUndoManager
                )
            }
        )
    }

    private func isInSettingsWindowGroup(_ window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }
        return window === self.window || optionsPanelControllers.values.contains { $0.owns(window) }
    }

    private func installOptionsDismissMonitor() {
        guard optionsDismissEventMonitor == nil, let window else {
            return
        }

        optionsDismissEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self, weak window] event in
            guard let self else {
                return event
            }

            optionsDismissedByClick = nil
            guard event.window === window else {
                return event
            }

            if let panel = SettingsOptionsPanel.allCases.first(where: {
                existingOptionsPanelController($0)?.isVisible == true
            }) {
                optionsDismissedByClick = (panel, event)
            }
            handleOptionsAction(.closeAll)
            // 保留到本次 mouseUp 分发完成, 避免影响之后的辅助功能按钮动作
            DispatchQueue.main.async { [weak self] in
                if self?.optionsDismissedByClick?.event === event {
                    self?.optionsDismissedByClick = nil
                }
            }
            return event
        }
        optionsDismissFocusObserver = NotificationCenter.default
            .publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] notification in
                guard let self,
                      let sourceWindow = notification.object as? NSWindow,
                      isInSettingsWindowGroup(sourceWindow) else {
                    return
                }
                Task { @MainActor [weak self] in
                    // 等新 keyWindow 生效再判断, 旧面板的失焦回调不能关闭刚切换到的新面板
                    await Task.yield()
                    guard let self, !isInSettingsWindowGroup(NSApplication.shared.keyWindow) else {
                        return
                    }
                    handleOptionsAction(.closeAll)
                }
            }
        optionsDismissWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeOptionsDismissMonitor()
            }
        }
    }

    private func removeOptionsDismissMonitor() {
        for controller in optionsPanelControllers.values {
            controller.hide(immediate: true)
        }
        if let optionsDismissEventMonitor {
            NSEvent.removeMonitor(optionsDismissEventMonitor)
        }
        if let optionsDismissWindowObserver {
            NotificationCenter.default.removeObserver(optionsDismissWindowObserver)
        }
        optionsDismissEventMonitor = nil
        optionsDismissFocusObserver = nil
        optionsDismissWindowObserver = nil
        optionsDismissedByClick = nil
    }

    /// 子面板占设置窗口右侧同一位置, 展开一个必须先收掉其余的
    /// 收旧面板用 immediate, 否则滑回与滑出在同一处交叠
    /// 互斥规则只写在这里, 再加一个面板也不会漏掉某一对
    private func handleOptionsAction(_ action: SettingsOptionsPanelAction) {
        switch action {
        case let .toggle(panel, anchorProvider):
            // mouseUp 监听器先于按钮动作收起面板, 同一事件不能再次展开它
            if let optionsDismissedByClick,
               optionsDismissedByClick.panel == panel,
               optionsDismissedByClick.event === NSApplication.shared.currentEvent {
                return
            }
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
        guard height.isFinite, height > 0 else {
            return
        }

        preferredContentHeight = height
        guard let window else {
            return
        }

        var targetContentSize = window.contentLayoutRect.size
        targetContentSize.height = height
        targetContentSize = clampedContentSize(targetContentSize, for: window)
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
        let referenceContentHeight = min(
            maximumContentSize(for: window).height,
            Metrics.topEdgeReferenceContentHeight
        )
        let maximumFrameHeight = window.frameRect(
            forContentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: window.contentLayoutRect.width,
                    height: referenceContentHeight
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
            height: max(
                Metrics.minimumContentSize.height,
                screen.visibleFrame.height - Metrics.screenInset
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
