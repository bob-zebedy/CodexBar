import AppKit
import Combine
import SwiftUI

/// 通知子选项面板动作, 由 AppSettingsView 发出并在 SettingsWindowController 中路由
nonisolated enum NotificationOptionsPanelAction {
    case toggle
    case open
    case close
}

/// 通知子选项面板控制器, 挂在设置窗口右侧并保持底边对齐, 复用侧边抽屉动效
/// 与重置次数面板不同: 内容是交互控件, 用常驻 hosting controller + ObservableObject 驱动更新, 不替换 rootView
@MainActor
final class NotificationOptionsPanelController {
    private let notificationSettings: NotificationSettings
    private let codexHookSettings: CodexHookSettings
    private let codexCLINotificationSettings: CodexCLINotificationSettings
    private var panel: NSPanel?
    private var hostingController: NSHostingController<NotificationOptionsView>?
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        makesKey: true,
        usesUntranslatedInitialLayout: true,
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )
    private weak var settingsWindow: NSWindow?
    private var panelDismissObserver: NSObjectProtocol?
    private var settingsWindowDismissObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var panelResizeTask: Task<Void, Never>?
    private var isEntryAnimationRunning = false

    init(
        notificationSettings: NotificationSettings,
        codexHookSettings: CodexHookSettings,
        codexCLINotificationSettings: CodexCLINotificationSettings
    ) {
        self.notificationSettings = notificationSettings
        self.codexHookSettings = codexHookSettings
        self.codexCLINotificationSettings = codexCLINotificationSettings
        observeContentHeightChanges()
    }

    private var isVisible: Bool {
        presenter.isVisible
    }

    private func owns(_ window: NSWindow?) -> Bool {
        window === panel
    }

    func toggle(
        relativeTo window: NSWindow?,
        contentView: NSView?
    ) {
        if isVisible {
            hide()
            return
        }

        show(relativeTo: window, contentView: contentView)
    }

    func show(
        relativeTo window: NSWindow?,
        contentView: NSView?
    ) {
        guard let window else {
            hide(immediate: true)
            return
        }

        codexCLINotificationSettings.refresh()
        let panel = ensurePanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        let windowSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: window) ?? window.frame
        let panelSize = measuredPanelSize()
        let position = SidePanelSupport.position(
            panelSize: panelSize,
            menuSurfaceFrame: windowSurfaceFrame,
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame ?? windowSurfaceFrame,
            preferredSide: .right,
            proposedY: windowSurfaceFrame.minY
        )

        panel.level = window.level
        installSettingsWindowDismissObservers(for: window)
        panelResizeTask?.cancel()
        isEntryAnimationRunning = true
        presenter.present(panel, at: position, relativeTo: window) { [weak self] in
            guard let self else {
                return
            }

            isEntryAnimationRunning = false
            schedulePanelResize()
        }
    }

    func hide(immediate: Bool = false) {
        panelResizeTask?.cancel()
        panelResizeTask = nil
        isEntryAnimationRunning = false
        presenter.hide(immediate: immediate)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = SidePanelSupport.makePanel(
            initialSize: NotificationOptionsView.initialPanelSize,
            ignoresMouseEvents: false,
            keyable: true
        )
        let hostingController = NSHostingController(
            rootView: NotificationOptionsView(
                notificationSettings: notificationSettings,
                codexHookSettings: codexHookSettings,
                codexCLINotificationSettings: codexCLINotificationSettings
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hostingController
        SidePanelSupport.configureLayers(
            hostingView: hostingController.view,
            contentView: panel.contentView,
            cornerRadius: NotificationOptionsView.panelCornerRadius
        )
        panelDismissObserver = makeResignKeyDismissObserver(observing: panel) { [weak self] keyWindow in
            self?.owns(keyWindow) != true
        }
        self.hostingController = hostingController
        self.panel = panel
        return panel
    }

    /// 设置窗口和面板之间切换 key 不收起; 焦点离开这个窗口组或设置窗口关闭时收起
    private func installSettingsWindowDismissObservers(for window: NSWindow) {
        guard settingsWindow !== window || settingsWindowDismissObservers.isEmpty else {
            return
        }

        settingsWindow = window
        for observer in settingsWindowDismissObservers {
            NotificationCenter.default.removeObserver(observer)
        }

        settingsWindowDismissObservers = [
            makeResignKeyDismissObserver(observing: window) { [weak self, weak window] keyWindow in
                keyWindow !== window && self?.owns(keyWindow) != true
            },
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide(immediate: true)
                }
            }
        ]
    }

    /// resignKey 后让出一轮 runloop, 等新 keyWindow 生效再判定
    private func makeResignKeyDismissObserver(
        observing window: NSWindow,
        shouldDismiss: @escaping @MainActor (NSWindow?) -> Bool
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                await Task.yield()
                guard isVisible, shouldDismiss(NSApplication.shared.keyWindow) else {
                    return
                }

                hide()
            }
        }
    }

    private func measuredPanelSize() -> CGSize {
        hostingController?.view.validFittingSize ?? NotificationOptionsView.initialPanelSize
    }

    private func observeContentHeightChanges() {
        Publishers.MergeMany([
            notificationSettings.$isLowQuotaEnabled.map { _ in () },
            notificationSettings.$isQuotaResetEnabled.map { _ in () },
            notificationSettings.$isLongTaskEnabled.map { _ in () },
            notificationSettings.$isTaskWaitingEnabled.map { _ in () },
            notificationSettings.$isCreditExpiryEnabled.map { _ in () },
            codexHookSettings.$isEnabled.map { _ in () }
        ])
        .sink { [weak self] in
            self?.schedulePanelResize()
        }
        .store(in: &cancellables)
    }

    private func schedulePanelResize() {
        guard panel != nil, !isEntryAnimationRunning else {
            return
        }

        panelResizeTask?.cancel()
        panelResizeTask = Task { @MainActor [weak self] in
            // @Published 先于 SwiftUI 布局发出变更, 等待视图提交新的 fitting size
            await Task.yield()
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  let panel,
                  panel.isVisible,
                  let size = hostingController?.view.validFittingSize else {
                return
            }

            resizePanel(panel, to: size)
        }
    }

    private func resizePanel(_ panel: NSPanel, to size: CGSize) {
        guard size != panel.frame.size else {
            return
        }

        var targetFrame = panel.frame
        targetFrame.size = size
        if let visibleFrame = panel.screen?.visibleFrame {
            let maximumY = visibleFrame.maxY - SidePanelSupport.Metrics.screenPadding
            if targetFrame.maxY > maximumY {
                targetFrame.origin.y = maximumY - targetFrame.height
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.notificationOptionsDrawerTransform"
        static let resizeDuration: TimeInterval = 0.16
    }
}
