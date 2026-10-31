import AppKit
import Combine

/// 点击活动卡片后展开的并发任务中心, 复用菜单侧边抽屉定位和动画
@MainActor
final class ActivityPanelController {
    private let activityMonitor: ActivityMonitor
    private let presentationState: ActivityCenterPresentationState
    private let mainPanelSettings: MainPanelSettings
    private let contentHost = SidePanelContentHost<ActivityCenterView>(
        initialSize: ActivityCenterView.initialPanelSize,
        ignoresMouseEvents: false,
        sizingOptions: [],
        cornerRadius: ActivityCenterView.panelCornerRadius
    )
    private var currentAnchor: ActivityCenterPanelAnchor?
    private weak var menuSurfaceWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var layoutSubscriptions = Set<AnyCancellable>()
    private var presentationTask: Task<Void, Never>?
    private var panelUpdateTask: Task<Void, Never>?
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        contentViewProvider: { [weak self] in
            self?.contentHost.contentView
        }
    )

    init(
        activityMonitor: ActivityMonitor,
        presentationState: ActivityCenterPresentationState,
        mainPanelSettings: MainPanelSettings
    ) {
        self.activityMonitor = activityMonitor
        self.presentationState = presentationState
        self.mainPanelSettings = mainPanelSettings

        activityMonitor.$snapshot
            .map { snapshot -> CGSize? in
                guard snapshot.hasTaskCenterContent else { return nil }
                return ActivityCenterView.panelSize(maximumHeight: .greatestFiniteMagnitude, snapshot: snapshot)
            }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] size in
                guard let self, presentationState.isPresented else {
                    return
                }
                schedulePanelUpdate(hasContent: size != nil)
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
        anchor: ActivityCenterPanelAnchor,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        if isVisible || presentationTask != nil {
            hide()
            return
        }

        schedulePresentation(
            anchor: anchor,
            relativeTo: menuSurfaceWindow,
            contentView: contentView
        )
    }

    func hide(immediate: Bool = false) {
        cancelScheduledPresentation()
        layoutSubscriptions.removeAll()
        currentAnchor = nil
        menuSurfaceWindow = nil
        // 热力图 hover 等高频路径会反复调用 hide, 已隐藏时跳过 @Published 写入以免整个菜单重算
        if presentationState.isPresented || presenter.isVisible {
            cancelScheduledPanelUpdate()
            presentationState.isPresented = false
        } else if !immediate {
            return
        }
        presenter.hide(immediate: immediate)
    }

    private func schedulePresentation(
        anchor: ActivityCenterPanelAnchor,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        presentationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            contentView?.layoutSubtreeIfNeeded()
            if let menuSurfaceWindow,
               anchor.screenFrame(in: menuSurfaceWindow) == nil {
                await Task.yield()
            }

            guard !Task.isCancelled else {
                return
            }
            presentationTask = nil
            show(
                anchor: anchor,
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
        anchor: ActivityCenterPanelAnchor,
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
        currentAnchor = anchor
        self.menuSurfaceWindow = menuSurfaceWindow
        contentView?.layoutSubtreeIfNeeded()
        guard let layout = panelLayout(
            anchor: anchor,
            menuSurfaceWindow: menuSurfaceWindow,
            snapshot: snapshot
        ) else {
            hide(immediate: true)
            return
        }

        updateContent(panelSize: layout.size)
        panel.level = menuSurfaceWindow.level
        presentationState.isPresented = true
        defer {
            SidePanelSupport.restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
        }
        presenter.present(panel, at: layout.position, relativeTo: menuSurfaceWindow)
        observeLayout(anchor: anchor, window: menuSurfaceWindow)
    }

    private func panelLayout(
        anchor: ActivityCenterPanelAnchor,
        menuSurfaceWindow: NSWindow,
        snapshot: ActivitySnapshot
    ) -> (size: CGSize, position: SidePanelPosition)? {
        let menuSurfaceFrame = menuSurfaceWindow.contentRect(forFrameRect: menuSurfaceWindow.frame)
        let screen = menuSurfaceWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? menuSurfaceFrame
        guard let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
            anchor.screenFrame(in: menuSurfaceWindow),
            menuSurfaceFrame: menuSurfaceFrame
        ) else { return nil }
        let screenMaximumHeight = visibleFrame.height - SidePanelSupport.Metrics.screenPadding * 2
        let menuMaximumHeight = alignmentScreenFrame.maxY - menuSurfaceFrame.minY
        guard min(screenMaximumHeight, menuMaximumHeight) > 0 else { return nil }
        let panelSize = ActivityCenterView.panelSize(
            maximumHeight: min(screenMaximumHeight, menuMaximumHeight),
            snapshot: snapshot
        )
        let position = SidePanelSupport.anchoredPosition(
            panelSize: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: visibleFrame,
            screenFrame: screen?.frame,
            alignmentScreenFrame: alignmentScreenFrame,
            preferredSide: .right
        )

        return (panelSize, position)
    }

    private func updateVisibleLayout(for snapshot: ActivitySnapshot) {
        guard let panel = contentHost.panel,
              panel.isVisible,
              let currentAnchor,
              let menuSurfaceWindow else {
            return
        }

        guard let layout = panelLayout(
            anchor: currentAnchor,
            menuSurfaceWindow: menuSurfaceWindow,
            snapshot: snapshot
        ) else {
            hide()
            return
        }
        guard panel.frame != layout.position.frame else {
            return
        }
        // 宿主随 SwiftUI 布局逐帧伸缩, 窗口位置同步更新, 避免叠加动画
        panel.setFrame(layout.position.frame, display: true)
    }

    private func observeLayout(anchor: ActivityCenterPanelAnchor, window: NSWindow) {
        layoutSubscriptions.removeAll()
        anchor.$topOffset
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleGeometryUpdate() }
            .store(in: &layoutSubscriptions)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.scheduleGeometryUpdate() }
                .store(in: &layoutSubscriptions)
        }
    }

    private func scheduleGeometryUpdate() {
        guard presentationState.isPresented, activityMonitor.snapshot.hasTaskCenterContent else { return }
        schedulePanelUpdate(hasContent: true)
    }

    private func schedulePanelUpdate(hasContent: Bool) {
        cancelScheduledPanelUpdate()
        panelUpdateTask = Task { @MainActor [weak self] in
            if hasContent {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .seconds(Metrics.contentUpdateDuration))
            }

            guard let self, !Task.isCancelled else {
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
        panelUpdateTask?.cancel()
        panelUpdateTask = nil
    }

    private func updateContent(panelSize: CGSize) {
        contentHost.updateContent(
            ActivityCenterView(
                activityMonitor: activityMonitor,
                presentationState: presentationState,
                mainPanelSettings: mainPanelSettings
            ),
            size: panelSize
        )
    }

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.activityCenterDrawerTransform"
        static let contentUpdateDuration: TimeInterval = 0.20
    }
}
