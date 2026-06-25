import AppKit
import QuartzCore
import SwiftUI

/// 详情面板不接收焦点, 只作为菜单面板的跟随子窗口
private final class DetailPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// 热力图 hover 详情控制器, 负责左右贴边定位和抽屉式切换动画
@MainActor
final class HeatmapDetailPanelController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<UsageHeatmapDayDetailView>?
    private var detailModel: UsageHeatmapDayDetailModel?
    private var hideTask: Task<Void, Never>?
    private var currentSide = UsageHeatmapDetailSide.left
    private var visibilityGeneration = 0
    private var drawerTransition = DrawerTransition.idle
    private var pendingSideSwitchRequest: PanelRequest?
    private weak var menuSurfaceWindow: NSWindow?

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

    func hide(immediate: Bool = false, delayed: Bool = true) {
        cancelHideTask()
        visibilityGeneration += 1
        drawerTransition = .idle
        pendingSideSwitchRequest = nil

        guard let panel, panel.isVisible else {
            return
        }

        guard !immediate else {
            resetDrawerVisualState(for: panel)
            drawerTransition = .idle
            orderOut(panel)
            return
        }

        let generation = visibilityGeneration
        let side = currentSide
        hideTask = Task { @MainActor [weak self] in
            if delayed {
                try? await Task.sleep(for: .milliseconds(Metrics.hideDelayMilliseconds))
            }

            guard let self,
                  !Task.isCancelled,
                  generation == visibilityGeneration,
                  let panel = self.panel,
                  panel.isVisible else {
                return
            }

            drawerTransition = .exiting
            let hidden = drawerHiddenTranslation(for: side, panelWidth: panel.frame.width)
            animateContentTranslation(
                to: hidden,
                duration: Metrics.drawerExitDuration,
                timing: .easeIn
            ) {
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == visibilityGeneration else {
                        return
                    }

                    orderOut(panel)
                    setContentTranslation(0)
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

        let panel = ensurePanel()
        let wasVisible = panel.isVisible
        if wasVisible {
            attach(panel, to: menuSurfaceWindow)
        }

        let panelSize = UsageHeatmapDayDetailView.panelSize(showsWorkflowStats: context.showsWorkflowStats)
        let position = panelPosition(
            for: panelSize,
            relativeTo: menuSurfaceWindow,
            contentView: contentView,
            anchorScreenFrame: context.anchorScreenFrame,
            heatmapScreenFrame: context.heatmapScreenFrame,
            showsWorkflowStats: context.showsWorkflowStats,
            preferredSide: context.preferredSide
        )
        let request = PanelRequest(context: context, position: position)

        panel.level = menuSurfaceWindow.level
        defer {
            restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
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
            animateContentTranslation(to: 0, duration: Metrics.drawerEnterDuration, timing: .easeOut)
        case .idle, .switchingSide:
            drawerTransition = .idle
            resetDrawerVisualState(for: panel)
        }
    }

    private func showPanelWithDrawerAnimation(_ panel: NSPanel, relativeTo menuSurfaceWindow: NSWindow) {
        let generation = visibilityGeneration
        let hidden = drawerHiddenTranslation(for: currentSide, panelWidth: panel.frame.width)
        setContentTranslation(hidden)
        panel.alphaValue = 0
        attach(panel, to: menuSurfaceWindow)
        panel.order(.above, relativeTo: menuSurfaceWindow.windowNumber)
        drawerTransition = .entering
        animateContentTranslationAfterInitialLayout(
            from: hidden,
            panel: panel,
            generation: generation
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

        let hidden = drawerHiddenTranslation(for: sourceSide, panelWidth: panel.frame.width)
        animateContentTranslation(
            to: hidden,
            duration: Metrics.drawerExitDuration,
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
        let hidden = drawerHiddenTranslation(for: side, panelWidth: request.position.frame.width)
        setContentTranslation(hidden)
        apply(request, to: panel)
        setContentTranslation(hidden)

        animateContentTranslation(
            from: hidden,
            to: 0,
            duration: Metrics.drawerEnterDuration,
            timing: .easeOut
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      generation == visibilityGeneration,
                      panel.isVisible else {
                    return
                }

                drawerTransition = .idle
                setContentTranslation(0)
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
            resetDrawerVisualState(for: panel)
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = DetailPanel(
            contentRect: NSRect(origin: .zero, size: UsageHeatmapDayDetailView.panelSize(showsWorkflowStats: true)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func attach(_ panel: NSPanel, to parentWindow: NSWindow) {
        menuSurfaceWindow = parentWindow
        guard panel.parent !== parentWindow else {
            return
        }

        panel.parent?.removeChildWindow(panel)
        parentWindow.addChildWindow(panel, ordered: .above)
    }

    private func orderOut(_ panel: NSPanel) {
        let parentWindow = panel.parent ?? menuSurfaceWindow
        panel.orderOut(nil)
        parentWindow?.removeChildWindow(panel)
        restoreMenuSurfaceKeyWindow(parentWindow)
    }

    private func restoreMenuSurfaceKeyWindow(_ menuSurfaceWindow: NSWindow?) {
        guard NSApplication.shared.isActive else {
            return
        }

        menuSurfaceWindow?.makeKey()
    }

    private func updateContent(_ context: UsageHeatmapHoverContext) {
        let size = UsageHeatmapDayDetailView.panelSize(showsWorkflowStats: context.showsWorkflowStats)

        if let detailModel {
            withAnimation(Animation.codexStatus) {
                detailModel.context = context
            }
        } else {
            let detailModel = UsageHeatmapDayDetailModel(context: context)
            let rootView = UsageHeatmapDayDetailView(model: detailModel)
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.sizingOptions = [.preferredContentSize]
            panel?.contentViewController = hostingController
            self.hostingController = hostingController
            self.detailModel = detailModel
        }

        configurePanelLayers()
        panel?.setContentSize(size)
    }

    private func configurePanelLayers() {
        if let hostingView = hostingController?.view {
            configurePanelLayer(for: hostingView)
        }

        if let contentView = panel?.contentView {
            configurePanelLayer(for: contentView)
            if let frameView = contentView.superview {
                configurePanelLayer(for: frameView)
            }
        }
    }

    private func apply(_ request: PanelRequest, to panel: NSPanel) {
        updateContent(request.context)
        panel.setFrame(request.position.frame, display: true)
        panel.alphaValue = 1
        currentSide = request.position.side
    }

    private func configurePanelLayer(for view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = UsageHeatmapDayDetailView.panelCornerRadius
        view.layer?.cornerCurve = .continuous
    }

    private func panelPosition(
        for panelSize: CGSize,
        relativeTo menuSurfaceWindow: NSWindow,
        contentView: NSView?,
        anchorScreenFrame: CGRect?,
        heatmapScreenFrame: CGRect?,
        showsWorkflowStats: Bool,
        preferredSide: UsageHeatmapDetailSide
    ) -> PanelPosition {
        // 优先贴在请求侧, 空间不足时换边, 最后仍夹紧到屏幕可见区域
        let menuSurfaceFrame = contentScreenFrame(for: contentView, in: menuSurfaceWindow) ?? menuSurfaceWindow.frame
        let visibleFrame = (menuSurfaceWindow.screen ?? NSScreen.main)?.visibleFrame ?? menuSurfaceFrame
        let leftX = menuSurfaceFrame.minX - Metrics.panelGap - panelSize.width
        let rightX = menuSurfaceFrame.maxX + Metrics.panelGap
        let horizontal = horizontalPlacement(
            preferredSide: preferredSide,
            left: HorizontalPlacement(
                x: leftX,
                side: .left,
                isAvailable: leftX >= visibleFrame.minX + Metrics.screenPadding
            ),
            right: HorizontalPlacement(
                x: rightX,
                side: .right,
                isAvailable: rightX + panelSize.width <= visibleFrame.maxX - Metrics.screenPadding
            )
        )

        let x = clamped(
            horizontal.x,
            lower: visibleFrame.minX + Metrics.screenPadding,
            upper: visibleFrame.maxX - panelSize.width - Metrics.screenPadding
        )
        let frame = NSRect(
            x: x,
            y: panelY(
                for: panelSize,
                menuSurfaceFrame: menuSurfaceFrame,
                visibleFrame: visibleFrame,
                anchorScreenFrame: anchorScreenFrame,
                heatmapScreenFrame: heatmapScreenFrame,
                showsWorkflowStats: showsWorkflowStats
            ),
            width: panelSize.width,
            height: panelSize.height
        )

        return PanelPosition(
            frame: frame,
            side: actualSide(
                forX: x,
                panelWidth: panelSize.width,
                menuSurfaceFrame: menuSurfaceFrame,
                fallback: horizontal.side
            )
        )
    }

    private func panelY(
        for panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        visibleFrame: CGRect,
        anchorScreenFrame: CGRect?,
        heatmapScreenFrame: CGRect?,
        showsWorkflowStats: Bool
    ) -> CGFloat {
        let proposedY: CGFloat = if showsWorkflowStats {
            menuSurfaceFrame.minY
        } else if let heatmapScreenFrame {
            heatmapScreenFrame.maxY - panelSize.height
        } else if let anchorScreenFrame {
            anchorScreenFrame.maxY - panelSize.height
        } else {
            menuSurfaceFrame.midY - panelSize.height / 2
        }

        return clamped(
            proposedY,
            lower: max(visibleFrame.minY + Metrics.screenPadding, menuSurfaceFrame.minY),
            upper: visibleFrame.maxY - panelSize.height - Metrics.screenPadding
        )
    }

    private func horizontalPlacement(
        preferredSide: UsageHeatmapDetailSide,
        left: HorizontalPlacement,
        right: HorizontalPlacement
    ) -> HorizontalPlacement {
        let primary = preferredSide == .left ? left : right
        let fallback = preferredSide == .left ? right : left

        if primary.isAvailable {
            return primary
        }
        return fallback.isAvailable ? fallback : primary
    }

    private func actualSide(
        forX x: CGFloat,
        panelWidth: CGFloat,
        menuSurfaceFrame: CGRect,
        fallback: UsageHeatmapDetailSide
    ) -> UsageHeatmapDetailSide {
        if x + panelWidth <= menuSurfaceFrame.minX {
            return .left
        }
        if x >= menuSurfaceFrame.maxX {
            return .right
        }
        return fallback
    }

    private func cancelHideTask() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func drawerHiddenTranslation(for side: UsageHeatmapDetailSide, panelWidth: CGFloat) -> CGFloat {
        let distance = panelWidth + Metrics.drawerOverscan
        switch side {
        case .left:
            return distance
        case .right:
            return -distance
        }
    }

    private func setContentTranslation(_ translationX: CGFloat) {
        guard let layer = hostingController?.view.layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Metrics.drawerTransformAnimationKey)
        layer.transform = CATransform3DMakeTranslation(translationX, 0, 0)
        CATransaction.commit()
    }

    private func animateContentTranslation(
        from fromTranslationX: CGFloat? = nil,
        to translationX: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        completion: (() -> Void)? = nil
    ) {
        guard let layer = hostingController?.view.layer else {
            completion?()
            return
        }

        let targetTransform = CATransform3DMakeTranslation(translationX, 0, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = fromTranslationX.map { CATransform3DMakeTranslation($0, 0, 0) }
            ?? layer.presentation()?.transform
            ?? layer.transform
        animation.toValue = targetTransform
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: Metrics.drawerTransformAnimationKey)
        layer.transform = targetTransform

        CATransaction.commit()
    }

    private func animateContentTranslationAfterInitialLayout(
        from hiddenTranslationX: CGFloat,
        panel: NSPanel,
        generation: Int
    ) {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()

        Task { @MainActor [weak self, weak panel] in
            await Task.yield()
            guard let self,
                  let panel,
                  panel.isVisible,
                  generation == visibilityGeneration else {
                return
            }

            setContentTranslation(hiddenTranslationX)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            panel.alphaValue = 1
            animateContentTranslation(
                from: hiddenTranslationX,
                to: 0,
                duration: Metrics.drawerEnterDuration,
                timing: .easeOut
            ) {
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == visibilityGeneration else {
                        return
                    }

                    drawerTransition = .idle
                    setContentTranslation(0)
                }
            }
        }
    }

    private func resetDrawerVisualState(for panel: NSPanel) {
        setContentTranslation(0)
        panel.alphaValue = 1
    }

    private func contentScreenFrame(for contentView: NSView?, in window: NSWindow) -> CGRect? {
        guard let contentView else {
            return nil
        }

        contentView.layoutSubtreeIfNeeded()
        let frameInWindow = contentView.convert(contentView.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return nil
        }

        return screenFrame
    }

    private func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else {
            return lower
        }

        return min(max(value, lower), upper)
    }

    private enum Metrics {
        static let panelGap: CGFloat = 4
        static let screenPadding: CGFloat = 8
        static let hideDelayMilliseconds: UInt64 = 220
        static let drawerEnterDuration: TimeInterval = 0.18
        static let drawerExitDuration: TimeInterval = 0.12
        static let drawerOverscan: CGFloat = 1
        static let drawerTransformAnimationKey = "CodexBar.heatmapDetailDrawerTransform"
    }

    private enum DrawerTransition {
        case idle
        case entering
        case exiting
        case switchingSide
    }

    private struct PanelPosition {
        let frame: NSRect
        let side: UsageHeatmapDetailSide
    }

    private struct HorizontalPlacement {
        let x: CGFloat
        let side: UsageHeatmapDetailSide
        let isAvailable: Bool
    }

    private struct PanelRequest {
        let context: UsageHeatmapHoverContext
        let position: PanelPosition
    }
}
