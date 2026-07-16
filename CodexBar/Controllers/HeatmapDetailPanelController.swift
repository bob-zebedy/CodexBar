import AppKit
import QuartzCore
import SwiftUI

/// 热力图 hover 详情控制器, 负责左右贴边定位和抽屉式切换动画
@MainActor
final class HeatmapDetailPanelController {
    private let contentHost = SidePanelContentHost<UsageHeatmapDayDetailView>(
        initialSize: UsageHeatmapDayDetailView.panelSize(showsWorkflow: true),
        ignoresMouseEvents: true,
        sizingOptions: [.preferredContentSize],
        cornerRadius: UsageHeatmapDayDetailView.panelCornerRadius
    )
    private lazy var drawerAnimator = SidePanelDrawerAnimator(
        contentViewProvider: { [weak self] in
            self?.contentHost.contentView
        },
        animationKey: Metrics.drawerTransformAnimationKey,
        overscan: SidePanelSupport.Metrics.drawerOverscan
    )
    private var hideTask: Task<Void, Never>?
    private var currentSide = UsageHeatmapDetailSide.left
    private var visibilityGeneration = 0
    private var drawerTransition = DrawerTransition.idle
    private var pendingSideSwitchRequest: PanelRequest?
    private weak var menuSurfaceWindow: NSWindow?

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        contentHost.containsScreenPoint(screenPoint)
    }

    func update(
        context: UsageHeatmapHoverContext?,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        guard let context else {
            hide()
            return
        }

        guard let menuSurfaceWindow else {
            hide(immediate: true)
            return
        }

        show(context: context, relativeTo: menuSurfaceWindow, contentView: contentView)
    }

    func hide(immediate: Bool = false) {
        cancelHideTask()
        visibilityGeneration += 1
        drawerTransition = .idle
        pendingSideSwitchRequest = nil

        guard let panel = contentHost.panel, panel.isVisible else {
            return
        }

        guard !immediate else {
            drawerAnimator.resetVisualState(for: panel)
            orderOut(panel)
            return
        }

        let generation = visibilityGeneration
        let side = currentSide
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Metrics.hideDelayMilliseconds))

            guard let self,
                  !Task.isCancelled,
                  generation == visibilityGeneration,
                  let panel = contentHost.panel,
                  panel.isVisible else {
                return
            }

            drawerTransition = .exiting
            let hidden = drawerAnimator.hiddenTranslation(for: side, panelWidth: panel.frame.width)
            drawerAnimator.animateTranslation(
                to: hidden,
                duration: SidePanelSupport.Metrics.drawerExitDuration,
                timing: .easeIn
            ) {
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == visibilityGeneration else {
                        return
                    }

                    orderOut(panel)
                    drawerAnimator.setTranslation(0)
                    drawerTransition = .idle
                    hideTask = nil
                }
            }
        }
    }

    private func show(
        context: UsageHeatmapHoverContext,
        relativeTo menuSurfaceWindow: NSWindow,
        contentView: NSView?
    ) {
        cancelHideTask()

        let panel = contentHost.ensurePanel()
        let wasVisible = panel.isVisible
        if wasVisible {
            attach(panel, to: menuSurfaceWindow)
        }

        let panelSize = UsageHeatmapDayDetailView.panelSize(showsWorkflow: context.showsWorkflow)
        let position = panelPosition(
            for: panelSize,
            relativeTo: menuSurfaceWindow,
            contentView: contentView,
            anchorScreenFrame: context.anchorScreenFrame,
            heatmapScreenFrame: context.heatmapScreenFrame,
            showsWorkflow: context.showsWorkflow,
            preferredSide: context.preferredSide
        )
        let request = PanelRequest(context: context, position: position)

        panel.level = menuSurfaceWindow.level
        defer {
            SidePanelSupport.restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
        }

        if wasVisible {
            updateVisiblePanel(request, on: panel)
            return
        }

        visibilityGeneration += 1
        apply(request, to: panel)
        showPanelWithDrawerAnimation(panel, relativeTo: menuSurfaceWindow)
    }

    private func updateVisiblePanel(_ request: PanelRequest, on panel: NSPanel) {
        if drawerTransition == .switchingSide {
            // 切边动画过程中只保留最新请求
            // 防止连续 hover 造成动画队列堆积
            pendingSideSwitchRequest = request
            return
        }

        if currentSide != request.position.side {
            beginSideSwitch(on: panel, from: currentSide, to: request)
            return
        }

        let activeTransition = drawerTransition
        if activeTransition != .entering {
            visibilityGeneration += 1
        }
        apply(request, to: panel)

        switch activeTransition {
        case .entering:
            return
        case .exiting:
            drawerTransition = .idle
            drawerAnimator.animateTranslation(to: 0, duration: SidePanelSupport.Metrics.drawerEnterDuration, timing: .easeOut)
        case .idle, .switchingSide:
            drawerTransition = .idle
            drawerAnimator.resetVisualState(for: panel)
        }
    }

    private func showPanelWithDrawerAnimation(_ panel: NSPanel, relativeTo menuSurfaceWindow: NSWindow) {
        let generation = visibilityGeneration
        let hidden = drawerAnimator.hiddenTranslation(for: currentSide, panelWidth: panel.frame.width)
        drawerAnimator.setTranslation(hidden)
        panel.alphaValue = 0
        attach(panel, to: menuSurfaceWindow)
        panel.order(.above, relativeTo: menuSurfaceWindow.windowNumber)
        drawerTransition = .entering
        drawerAnimator.animateEntryAfterInitialLayout(
            from: hidden,
            panel: panel,
            duration: SidePanelSupport.Metrics.drawerEnterDuration,
            isCurrent: { [weak self] in
                self?.visibilityGeneration == generation
            },
            completion: { [weak self] in
                guard let self else {
                    return
                }

                drawerTransition = .idle
                drawerAnimator.setTranslation(0)
            }
        )
    }

    private func beginSideSwitch(
        on panel: NSPanel,
        from sourceSide: UsageHeatmapDetailSide,
        to request: PanelRequest
    ) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        drawerTransition = .switchingSide
        pendingSideSwitchRequest = nil

        let hidden = drawerAnimator.hiddenTranslation(for: sourceSide, panelWidth: panel.frame.width)
        drawerAnimator.animateTranslation(
            to: hidden,
            duration: SidePanelSupport.Metrics.drawerExitDuration,
            timing: .easeIn
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      generation == visibilityGeneration,
                      drawerTransition == .switchingSide,
                      panel.isVisible else {
                    return
                }

                showHiddenSideSwitchRequest(
                    nextSideSwitchRequest(fallback: request),
                    on: panel,
                    generation: generation
                )
            }
        }
    }

    private func showHiddenSideSwitchRequest(_ request: PanelRequest, on panel: NSPanel, generation: Int) {
        let side = request.position.side
        let hidden = drawerAnimator.hiddenTranslation(for: side, panelWidth: request.position.frame.width)
        drawerAnimator.setTranslation(hidden)
        apply(request, to: panel)
        drawerAnimator.setTranslation(hidden)

        drawerAnimator.animateTranslation(
            from: hidden,
            to: 0,
            duration: SidePanelSupport.Metrics.drawerEnterDuration,
            timing: .easeOut
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      generation == visibilityGeneration,
                      panel.isVisible else {
                    return
                }

                drawerTransition = .idle
                drawerAnimator.setTranslation(0)
                handlePendingSideSwitchRequest(on: panel)
            }
        }
    }

    private func nextSideSwitchRequest(fallback request: PanelRequest) -> PanelRequest {
        guard let pendingSideSwitchRequest,
              pendingSideSwitchRequest.position.side == request.position.side else {
            return request
        }

        self.pendingSideSwitchRequest = nil
        return pendingSideSwitchRequest
    }

    private func handlePendingSideSwitchRequest(on panel: NSPanel) {
        guard let pendingSideSwitchRequest else {
            return
        }

        self.pendingSideSwitchRequest = nil

        if pendingSideSwitchRequest.position.side != currentSide {
            beginSideSwitch(on: panel, from: currentSide, to: pendingSideSwitchRequest)
        } else {
            apply(pendingSideSwitchRequest, to: panel)
            drawerAnimator.resetVisualState(for: panel)
        }
    }

    private func attach(_ panel: NSPanel, to parentWindow: NSWindow) {
        menuSurfaceWindow = parentWindow
        SidePanelSupport.attach(panel, to: parentWindow)
    }

    private func orderOut(_ panel: NSPanel) {
        SidePanelSupport.orderOut(panel, menuSurfaceWindow: menuSurfaceWindow)
    }

    private func updateContent(_ context: UsageHeatmapHoverContext) {
        contentHost.updateContent(
            UsageHeatmapDayDetailView(context: context),
            size: UsageHeatmapDayDetailView.panelSize(showsWorkflow: context.showsWorkflow)
        )
    }

    private func apply(_ request: PanelRequest, to panel: NSPanel) {
        updateContent(request.context)
        panel.setFrame(request.position.frame, display: true)
        panel.alphaValue = 1
        currentSide = request.position.side
    }

    private func panelPosition(
        for panelSize: CGSize,
        relativeTo menuSurfaceWindow: NSWindow,
        contentView: NSView?,
        anchorScreenFrame: CGRect?,
        heatmapScreenFrame: CGRect?,
        showsWorkflow: Bool,
        preferredSide: UsageHeatmapDetailSide
    ) -> SidePanelPosition {
        let menuSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: menuSurfaceWindow) ?? menuSurfaceWindow.frame
        let visibleFrame = (menuSurfaceWindow.screen ?? NSScreen.main)?.visibleFrame ?? menuSurfaceFrame

        return SidePanelSupport.position(
            panelSize: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: visibleFrame,
            preferredSide: preferredSide,
            proposedY: proposedY(
                for: panelSize,
                menuSurfaceFrame: menuSurfaceFrame,
                anchorScreenFrame: anchorScreenFrame,
                heatmapScreenFrame: heatmapScreenFrame,
                showsWorkflow: showsWorkflow
            )
        )
    }

    private func proposedY(
        for panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        anchorScreenFrame: CGRect?,
        heatmapScreenFrame: CGRect?,
        showsWorkflow: Bool
    ) -> CGFloat {
        if showsWorkflow {
            menuSurfaceFrame.minY
        } else if let heatmapScreenFrame {
            heatmapScreenFrame.maxY - panelSize.height
        } else if let anchorScreenFrame {
            anchorScreenFrame.maxY - panelSize.height
        } else {
            menuSurfaceFrame.midY - panelSize.height / 2
        }
    }

    private func cancelHideTask() {
        hideTask?.cancel()
        hideTask = nil
    }

    private enum Metrics {
        static let hideDelayMilliseconds: UInt64 = 220
        static let drawerTransformAnimationKey = "CodexBar.heatmapDetailDrawerTransform"
    }

    private enum DrawerTransition {
        case idle
        case entering
        case exiting
        case switchingSide
    }

    private struct PanelRequest {
        let context: UsageHeatmapHoverContext
        let position: SidePanelPosition
    }
}
