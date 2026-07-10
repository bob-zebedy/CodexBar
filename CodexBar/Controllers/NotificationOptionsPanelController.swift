import AppKit
import SwiftUI

/// 通知子选项面板动作, 由 AppSettingsView 发出并在 SettingsWindowController 中路由
nonisolated enum NotificationOptionsPanelAction: Equatable {
    case toggle(alignmentScreenFrame: CGRect?)
    case open(alignmentScreenFrame: CGRect?)
    case close
}

/// 通知子选项面板控制器, 挂在设置窗口右侧, 复用侧边抽屉动效
/// 与重置次数面板不同: 内容是交互控件, 用常驻 hosting controller + ObservableObject 驱动更新, 不替换 rootView
@MainActor
final class NotificationOptionsPanelController {
    private let notificationSettings: NotificationSettings
    private let codexHookSettings: CodexHookSettings
    private var panel: NSPanel?
    private var hostingController: NSHostingController<NotificationOptionsView>?
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        makesKey: true,
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )
    private weak var settingsWindow: NSWindow?
    private var panelDismissObserver: NSObjectProtocol?
    private var settingsWindowDismissObservers: [NSObjectProtocol] = []

    init(
        notificationSettings: NotificationSettings,
        codexHookSettings: CodexHookSettings
    ) {
        self.notificationSettings = notificationSettings
        self.codexHookSettings = codexHookSettings
    }

    var isVisible: Bool {
        presenter.isVisible
    }

    func owns(_ window: NSWindow?) -> Bool {
        window === panel
    }

    func toggle(
        alignmentScreenFrame: CGRect?,
        relativeTo window: NSWindow?,
        contentView: NSView?
    ) {
        if isVisible {
            hide()
            return
        }

        show(
            alignmentScreenFrame: alignmentScreenFrame,
            relativeTo: window,
            contentView: contentView
        )
    }

    func show(
        alignmentScreenFrame: CGRect?,
        relativeTo window: NSWindow?,
        contentView: NSView?
    ) {
        guard let window else {
            hide(immediate: true)
            return
        }

        let panel = ensurePanel()
        let windowSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: window) ?? window.frame
        let panelSize = measuredPanelSize()
        let validatedAlignmentFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            alignmentScreenFrame,
            menuSurfaceFrame: windowSurfaceFrame
        )
        let position = SidePanelSupport.position(
            panelSize: panelSize,
            menuSurfaceFrame: windowSurfaceFrame,
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame ?? windowSurfaceFrame,
            preferredSide: .right,
            proposedY: SidePanelSupport.alignedProposedY(
                panelSize: panelSize,
                menuSurfaceFrame: windowSurfaceFrame,
                alignmentScreenFrame: validatedAlignmentFrame
            )
        )

        panel.level = window.level
        installSettingsWindowDismissObservers(for: window)
        presenter.present(panel, at: position, relativeTo: window)
    }

    func hide(immediate: Bool = false) {
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
                codexHookSettings: codexHookSettings
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
                Task { @MainActor [weak self] in
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
        guard let hostingView = hostingController?.view else {
            return NotificationOptionsView.initialPanelSize
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        guard fittingSize.width.isFinite,
              fittingSize.height.isFinite,
              fittingSize.width > 0,
              fittingSize.height > 0 else {
            return NotificationOptionsView.initialPanelSize
        }

        return fittingSize
    }

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.notificationOptionsDrawerTransform"
    }
}
