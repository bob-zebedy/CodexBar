import AppKit
import Combine
import SwiftUI

/// 设置窗口控制器, 打开前刷新设置状态并按内容自适应高度
@MainActor
final class SettingsWindowController: HostingWindowController {
    private let viewModel: CodexStatusViewModel
    private let appUpdater: AppUpdater
    private let tuiNotificationSettings: TUINotificationSettings
    private let syncSettings: SyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let menuBarIndicatorSettings: MenuBarIndicatorSettings
    private let appearanceSettings: AppearanceSettings
    private let mainPanelSettings: MainPanelSettings
    private let taskGlowSettings: TaskGlowSettings
    private let notificationSettings: NotificationSettings
    private let autoResetSettings: AutoResetSettings
    private let protectionSettings: ProtectionSettings
    private let keepAliveController: KeepAliveController
    private let onSyncChanged: (Bool) -> Void
    private let onRebuildHistoryData: SyncScheduler.RebuildHandler
    private let mainPanelUndoManager = UndoManager()
    private let animationState = SettingsWindowAnimationState()
    private var windowFocusObserver: AnyCancellable?
    private var windowVisibilityObserver: AnyCancellable?
    private lazy var licensesWindowController = LicensesWindowController(screenProvider: screenProvider)
    /// 首次展开时才构造, 避免未使用的子面板持有 hosting controller 和订阅直到 App 退出
    private var optionsPanelControllers: [SettingsOptionsPanel: SettingsOptionsPanelController] = [:]
    private var optionsDismissEventMonitor: Any?
    private var optionsDismissFocusObserver: AnyCancellable?
    private var optionsDismissedByClick: (panel: SettingsOptionsPanel, event: NSEvent)?
    /// 首次构造窗口时, SwiftUI 可能在 window 赋值前上报高度, 因此必须保留最近一次测量结果
    private var preferredContentHeight: CGFloat?

    init(
        viewModel: CodexStatusViewModel,
        appUpdater: AppUpdater,
        tuiNotificationSettings: TUINotificationSettings,
        syncSettings: SyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        menuBarIndicatorSettings: MenuBarIndicatorSettings,
        appearanceSettings: AppearanceSettings,
        mainPanelSettings: MainPanelSettings,
        taskGlowSettings: TaskGlowSettings,
        notificationSettings: NotificationSettings,
        autoResetSettings: AutoResetSettings,
        protectionSettings: ProtectionSettings,
        keepAliveController: KeepAliveController,
        screenProvider: @escaping () -> NSScreen?,
        onSyncChanged: @escaping (Bool) -> Void,
        onRebuildHistoryData: @escaping SyncScheduler.RebuildHandler
    ) {
        self.viewModel = viewModel
        self.appUpdater = appUpdater
        self.tuiNotificationSettings = tuiNotificationSettings
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.menuBarIndicatorSettings = menuBarIndicatorSettings
        self.appearanceSettings = appearanceSettings
        self.mainPanelSettings = mainPanelSettings
        self.taskGlowSettings = taskGlowSettings
        self.notificationSettings = notificationSettings
        self.autoResetSettings = autoResetSettings
        self.protectionSettings = protectionSettings
        self.keepAliveController = keepAliveController
        self.onSyncChanged = onSyncChanged
        self.onRebuildHistoryData = onRebuildHistoryData
        super.init(screenProvider: screenProvider)
    }

    override func open() {
        refreshSettingsState()
        super.open()
        if let window {
            animationState.update(for: window)
        }
        installOptionsDismissMonitor()
        NotificationCenter.default.post(name: .settingsWindowDidOpen, object: nil)
    }

    override func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(
            rootView: AppSettingsView(
                syncSettings: syncSettings,
                globalHotKeySettings: globalHotKeySettings,
                menuBarIndicatorSettings: menuBarIndicatorSettings,
                appearanceSettings: appearanceSettings,
                mainPanelSettings: mainPanelSettings,
                taskGlowSettings: taskGlowSettings,
                notificationSettings: notificationSettings,
                autoResetSettings: autoResetSettings,
                keepAliveController: keepAliveController,
                onSyncChanged: onSyncChanged,
                onRebuildHistoryData: onRebuildHistoryData,
                onOptionsAction: { [weak self] action in
                    self?.handleOptionsAction(action)
                },
                onOpenSourceLicenses: { [weak self] in
                    self?.licensesWindowController.open()
                },
                onContentHeightChanged: { [weak self] height in
                    self?.resizeContentHeight(height)
                }
            )
            .environmentObject(viewModel)
            .environmentObject(appUpdater)
            .environmentObject(animationState)
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
        // 关闭后 hosting controller 仍然保留, 必须按窗口可见性停止持续动画
        windowVisibilityObserver = Publishers.MergeMany([
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ].map { NotificationCenter.default.publisher(for: $0, object: window) })
            .sink { [weak self, weak window] notification in
                guard let self, let window else { return }
                let isClosing = notification.name == NSWindow.willCloseNotification
                animationState.update(for: window, isClosing: isClosing)
                if isClosing {
                    removeOptionsDismissMonitor()
                }
            }
        return window
    }

    override func prepareForDisplay(_ window: NSWindow) {
        var targetContentSize = window.contentLayoutRect.size
        targetContentSize.height = preferredContentHeight ?? targetContentSize.height
        window.setContentSize(clampedContentSize(targetContentSize, for: window))
        positionForTabResizing(window)
    }

    override func setAllowsKeyFocus(_ allowsKeyFocus: Bool) {
        super.setAllowsKeyFocus(allowsKeyFocus)
        licensesWindowController.setAllowsKeyFocus(allowsKeyFocus)
    }

    private enum Metrics {
        static let minimumContentSize = NSSize(width: 420, height: 240)
        static let initialContentSize = NSSize(width: AppSettingsView.preferredContentWidth, height: 270)
        static let maximumFallbackContentSize = NSSize(width: 560, height: 720)
        /// 顶边基准只用于首次定位, 不限制页面自适应高度
        static let topEdgeReferenceContentHeight: CGFloat = 500
        static let screenInset: CGFloat = 80
    }

    private func refreshSettingsState() {
        notificationSettings.refreshAuthorizationStatus()
        tuiNotificationSettings.refresh()
        syncSettings.refresh()
        menuBarIndicatorSettings.refresh()
        appearanceSettings.refresh()
        mainPanelSettings.refresh()
        taskGlowSettings.refresh()
        autoResetSettings.refresh()
        protectionSettings.refresh()
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

    /// 收起时只处理已创建的子面板
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
        case .menuBarIndicator:
            makeMenuBarIndicatorOptionsPanelController()
        case .taskGlow:
            SettingsOptionsPanelController(
                mainPanelSettings: mainPanelSettings,
                animationKey: "CodexBar.taskGlowOptionsDrawerTransform",
                willHide: { [taskGlowSettings] in taskGlowSettings.endColorPreview() },
                contentProvider: { [taskGlowSettings] in
                    TaskGlowOptionsView(settings: taskGlowSettings)
                }
            )
        case .notification:
            SettingsOptionsPanelController(
                mainPanelSettings: mainPanelSettings,
                animationKey: "CodexBar.notificationOptionsDrawerTransform",
                resizesWithContent: true,
                willShow: { [tuiNotificationSettings] in
                    tuiNotificationSettings.refresh()
                },
                contentProvider: { [notificationSettings, tuiNotificationSettings, autoResetSettings, keepAliveController] in
                    NotificationOptionsView(
                        notificationSettings: notificationSettings,
                        tuiNotificationSettings: tuiNotificationSettings,
                        autoResetSettings: autoResetSettings,
                        keepAliveController: keepAliveController
                    )
                }
            )
        case .autoReset:
            SettingsOptionsPanelController(
                mainPanelSettings: mainPanelSettings,
                animationKey: "CodexBar.autoResetOptionsDrawerTransform",
                contentProvider: { [autoResetSettings] in
                    AutoResetOptionsView(settings: autoResetSettings)
                }
            )
        case .keepAlive:
            SettingsOptionsPanelController(
                mainPanelSettings: mainPanelSettings,
                animationKey: "CodexBar.keepAliveOptionsDrawerTransform",
                resizesWithContent: true,
                contentProvider: { [keepAliveController, protectionSettings] in
                    KeepAliveOptionsView(
                        keepAliveController: keepAliveController,
                        protectionSettings: protectionSettings
                    )
                }
            )
        }
    }

    private func makeMenuBarIndicatorOptionsPanelController() -> SettingsOptionsPanelController {
        SettingsOptionsPanelController(
            mainPanelSettings: mainPanelSettings,
            animationKey: "CodexBar.menuBarIndicatorOptionsDrawerTransform",
            resizesWithContent: true,
            contentProvider: { [menuBarIndicatorSettings, viewModel] in
                MenuBarIndicatorOptionsView(settings: menuBarIndicatorSettings, statusViewModel: viewModel)
            }
        )
    }

    private func makeMainPanelOptionsPanelController() -> SettingsOptionsPanelController {
        SettingsOptionsPanelController(
            mainPanelSettings: mainPanelSettings,
            animationKey: "CodexBar.mainPanelOptionsDrawerTransform",
            willShow: { [mainPanelSettings] in
                mainPanelSettings.refresh()
            },
            contentProvider: { [mainPanelSettings, mainPanelUndoManager] in
                MainPanelOptionsView(
                    settings: mainPanelSettings,
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
            // 保留到本次 mouseUp 分发完成, 避免影响之后的按钮动作
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
    }

    private func removeOptionsDismissMonitor() {
        for controller in optionsPanelControllers.values {
            controller.hide(immediate: true)
        }
        if let optionsDismissEventMonitor {
            NSEvent.removeMonitor(optionsDismissEventMonitor)
        }
        optionsDismissEventMonitor = nil
        optionsDismissFocusObserver = nil
        optionsDismissedByClick = nil
    }

    /// 子面板共用设置窗口右侧的位置, 展开前用 immediate 收起其他面板, 避免出入场动画交叠
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

@MainActor
final class SettingsWindowAnimationState: ObservableObject {
    @Published private(set) var allowsAnimations = false

    func update(for window: NSWindow, isClosing: Bool = false) {
        let isVisible = !isClosing && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        guard allowsAnimations != isVisible else { return }
        allowsAnimations = isVisible
    }
}

nonisolated extension Notification.Name {
    static let settingsWindowDidOpen = Notification.Name("CodexBar.settingsWindowDidOpen")
}
