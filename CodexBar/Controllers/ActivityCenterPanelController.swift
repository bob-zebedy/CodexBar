import AppKit
import Combine
import SwiftUI

/// 点击活动卡片后展开的并发任务中心, 复用菜单侧边抽屉定位和动画
@MainActor
final class ActivityCenterPanelController {
    private let activityMonitor: CodexActivityMonitor
    private let presentationState: CodexActivityCenterPresentationState
    private let contentHost = SidePanelContentHost<CodexActivityCenterView>(
        initialSize: CodexActivityCenterView.initialPanelSize,
        ignoresMouseEvents: false,
        sizingOptions: [],
        cornerRadius: CodexActivityCenterView.panelCornerRadius
    )
    private var currentContext: CodexActivityCenterPanelContext?
    private weak var menuSurfaceWindow: NSWindow?
    private weak var menuContentView: NSView?
    private var cancellables = Set<AnyCancellable>()
    private var presentationTask: Task<Void, Never>?
    private var panelUpdateTask: Task<Void, Never>?
    private var panelUpdateGeneration = 0
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        contentViewProvider: { [weak self] in
            self?.contentHost.contentView
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
                schedulePanelUpdate(hasContent: snapshot.hasTaskCenterContent)
            }
            .store(in: &cancellables)
    }

    var isVisible: Bool {
        presenter.isVisible
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        contentHost.containsScreenPoint(screenPoint)
    }

    func toggle(
        context: CodexActivityCenterPanelContext,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        if isVisible || presentationTask != nil {
            hide()
            return
        }

        schedulePresentation(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: contentView
        )
    }

    func hide(immediate: Bool = false) {
        cancelScheduledPresentation()
        // 热力图 hover 等高频路径会盲调 hide; 已隐藏时跳过 @Published 写入, 避免整个菜单重算
        guard presentationState.isPresented || presenter.isVisible else {
            return
        }
        cancelScheduledPanelUpdate()
        presentationState.isPresented = false
        presenter.hide(immediate: immediate)
    }

    private func schedulePresentation(
        context: CodexActivityCenterPanelContext,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        presentationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            contentView?.layoutSubtreeIfNeeded()
            if let menuSurfaceWindow,
               context.anchorProvider.currentScreenFrame(
                   in: menuSurfaceWindow,
                   allowingCachedFrame: false
               ) == nil {
                await Task.yield()
            }

            guard !Task.isCancelled else {
                return
            }
            presentationTask = nil
            show(
                context: context,
                relativeTo: menuSurfaceWindow,
                contentView: contentView
            )
        }
    }

    private func cancelScheduledPresentation() {
        presentationTask?.cancel()
        presentationTask = nil
    }

    private func show(
        context: CodexActivityCenterPanelContext,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        let snapshot = activityMonitor.snapshot
        guard snapshot.hasTaskCenterContent,
              let menuSurfaceWindow else {
            hide(immediate: true)
            return
        }

        let panel = contentHost.ensurePanel()
        cancelScheduledPanelUpdate()
        currentContext = context
        self.menuSurfaceWindow = menuSurfaceWindow
        menuContentView = contentView
        let layout = panelLayout(
            context: context,
            menuSurfaceWindow: menuSurfaceWindow,
            contentView: contentView,
            snapshot: snapshot,
            allowsCachedAnchor: false
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
        snapshot: CodexActivitySnapshot,
        allowsCachedAnchor: Bool = true
    ) -> (size: CGSize, position: SidePanelPosition) {
        let menuSurfaceFrame = SidePanelSupport.contentScreenFrame(
            for: contentView,
            in: menuSurfaceWindow
        ) ?? menuSurfaceWindow.frame
        let screen = menuSurfaceWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? menuSurfaceFrame
        let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            context.anchorProvider.currentScreenFrame(
                in: menuSurfaceWindow,
                allowingCachedFrame: allowsCachedAnchor
            ),
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
        let position = SidePanelSupport.anchoredPosition(
            panelSize: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: visibleFrame,
            screenFrame: screen?.frame,
            alignmentScreenFrame: alignmentScreenFrame,
            preferredSide: context.preferredSide
        )

        return (panelSize, position)
    }

    private func updateVisibleLayout(for snapshot: CodexActivitySnapshot) {
        guard let panel = contentHost.panel,
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
        guard panel.frame != layout.position.frame else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.contentUpdateDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(layout.position.frame, display: true)
        }
    }

    private func schedulePanelUpdate(hasContent: Bool) {
        cancelScheduledPanelUpdate()
        let generation = panelUpdateGeneration
        panelUpdateTask = Task { @MainActor [weak self] in
            if hasContent {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .seconds(Metrics.contentUpdateDuration))
            }

            guard let self, !Task.isCancelled,
                  generation == panelUpdateGeneration else {
                return
            }
            let snapshot = activityMonitor.snapshot
            guard snapshot.hasTaskCenterContent == hasContent else {
                return
            }

            panelUpdateTask = nil
            if hasContent {
                updateVisibleLayout(for: snapshot)
            } else {
                hide()
            }
        }
    }

    private func cancelScheduledPanelUpdate() {
        panelUpdateGeneration += 1
        panelUpdateTask?.cancel()
        panelUpdateTask = nil
    }

    private func updateContent(panelSize: CGSize) {
        contentHost.updateContent(
            CodexActivityCenterView(
                activityMonitor: activityMonitor,
                presentationState: presentationState
            ),
            size: panelSize
        )
    }

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.activityCenterDrawerTransform"
        static let contentUpdateDuration: TimeInterval = 0.20
    }
}
