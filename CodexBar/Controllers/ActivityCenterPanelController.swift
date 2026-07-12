import AppKit
import Combine
import SwiftUI

/// 点击活动卡片后展开的并发任务中心，复用菜单侧边抽屉定位和动画。
@MainActor
final class ActivityCenterPanelController {
    private let activityMonitor: CodexActivityMonitor
    private let presentationState: CodexActivityCenterPresentationState
    private var panel: NSPanel?
    private var hostingController: NSHostingController<CodexActivityCenterView>?
    private var currentContext: CodexActivityCenterPanelContext?
    private weak var menuSurfaceWindow: NSWindow?
    private weak var menuContentView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )

    init(
        activityMonitor: CodexActivityMonitor,
        presentationState: CodexActivityCenterPresentationState
    ) {
        self.activityMonitor = activityMonitor
        self.presentationState = presentationState

        activityMonitor.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in
                guard let self, presentationState.isPresented else {
                    return
                }
                if snapshot.hasTaskCenterContent {
                    updateVisibleLayout(for: snapshot)
                } else {
                    hide()
                }
            }
            .store(in: &cancellables)
    }

    var isVisible: Bool {
        presenter.isVisible
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let panel, panel.isVisible else {
            return false
        }
        return panel.frame.contains(screenPoint)
    }

    func toggle(
        context: CodexActivityCenterPanelContext,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        if isVisible {
            hide()
            return
        }

        show(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: contentView
        )
    }

    func hide(immediate: Bool = false) {
        // 热力图 hover 等高频路径会盲调 hide；已隐藏时跳过 @Published 写入，避免整个菜单重算。
        guard presentationState.isPresented || presenter.isVisible else {
            return
        }
        presentationState.isPresented = false
        presenter.hide(immediate: immediate)
    }

    private func show(
        context: CodexActivityCenterPanelContext,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        guard activityMonitor.snapshot.hasTaskCenterContent,
              let menuSurfaceWindow else {
            hide(immediate: true)
            return
        }

        let panel = ensurePanel()
        currentContext = context
        self.menuSurfaceWindow = menuSurfaceWindow
        menuContentView = contentView
        let layout = panelLayout(
            context: context,
            menuSurfaceWindow: menuSurfaceWindow,
            contentView: contentView,
            snapshot: activityMonitor.snapshot
        )

        updateContent(panelSize: layout.size)
        panel.level = menuSurfaceWindow.level
        presentationState.isPresented = true
        defer {
            SidePanelSupport.restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
        }
        presenter.present(panel, at: layout.position, relativeTo: menuSurfaceWindow)
    }

    private func panelLayout(
        context: CodexActivityCenterPanelContext,
        menuSurfaceWindow: NSWindow,
        contentView: NSView?,
        snapshot: CodexActivitySnapshot
    ) -> (size: CGSize, position: SidePanelPosition) {
        let menuSurfaceFrame = SidePanelSupport.contentScreenFrame(
            for: contentView,
            in: menuSurfaceWindow
        ) ?? menuSurfaceWindow.frame
        let screen = menuSurfaceWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? menuSurfaceFrame
        let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            context.alignmentScreenFrame,
            menuSurfaceFrame: menuSurfaceFrame
        )
        let screenMaximumHeight = visibleFrame.height - SidePanelSupport.Metrics.screenPadding * 2
        let menuMaximumHeight = alignmentScreenFrame.map {
            $0.maxY - menuSurfaceFrame.minY
        } ?? screenMaximumHeight
        let panelSize = CodexActivityCenterView.panelSize(
            maximumHeight: min(screenMaximumHeight, menuMaximumHeight),
            snapshot: snapshot
        )
        let positioningFrame = SidePanelSupport.anchorAwareVisibleFrame(
            visibleFrame: visibleFrame,
            screenFrame: screen?.frame,
            alignmentScreenFrame: alignmentScreenFrame
        )
        let position = SidePanelSupport.position(
            panelSize: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: positioningFrame,
            preferredSide: context.preferredSide,
            proposedY: SidePanelSupport.alignedProposedY(
                panelSize: panelSize,
                menuSurfaceFrame: menuSurfaceFrame,
                alignmentScreenFrame: alignmentScreenFrame
            )
        )

        return (panelSize, position)
    }

    private func updateVisibleLayout(for snapshot: CodexActivitySnapshot) {
        guard let panel,
              panel.isVisible,
              let currentContext,
              let menuSurfaceWindow else {
            return
        }

        let layout = panelLayout(
            context: currentContext,
            menuSurfaceWindow: menuSurfaceWindow,
            contentView: menuContentView,
            snapshot: snapshot
        )
        // 内容更新由 @ObservedObject 原地驱动；只有尺寸或位置变化才需要重建 rootView 和重设 frame。
        guard panel.frame != layout.position.frame else {
            return
        }
        if panel.frame.size != layout.size {
            updateContent(panelSize: layout.size)
        }
        panel.setFrame(layout.position.frame, display: true)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = SidePanelSupport.makePanel(
            initialSize: CodexActivityCenterView.initialPanelSize,
            ignoresMouseEvents: false
        )
        self.panel = panel
        return panel
    }

    private func updateContent(panelSize: CGSize) {
        let rootView = CodexActivityCenterView(
            activityMonitor: activityMonitor,
            presentationState: presentationState,
            panelSize: panelSize
        )

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.sizingOptions = [.preferredContentSize]
            panel?.contentViewController = hostingController
            self.hostingController = hostingController
        }

        SidePanelSupport.configureLayers(
            hostingView: hostingController?.view,
            contentView: panel?.contentView,
            cornerRadius: CodexActivityCenterView.panelCornerRadius
        )
        panel?.setContentSize(panelSize)
    }

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.activityCenterDrawerTransform"
    }
}
