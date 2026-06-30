import AppKit
import QuartzCore
import SwiftUI

/// 重置次数详情面板不接收焦点, 只作为菜单面板的跟随子窗口
private final class ResetCreditsPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// 重置次数详情控制器, 复用热力图详情的侧边抽屉动效
@MainActor
final class ResetCreditsPanelController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ResetCreditsPanelView>?
    private var visibilityGeneration = 0
    private var currentSide = UsageHeatmapDetailSide.right
    private weak var menuSurfaceWindow: NSWindow?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let panel, panel.isVisible else {
            return false
        }

        return panel.frame.contains(screenPoint)
    }

    func toggle(
        context: ResetCreditsPanelContext,
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
        visibilityGeneration += 1

        guard let panel, panel.isVisible else {
            return
        }

        guard !immediate else {
            resetDrawerVisualState(for: panel)
            orderOut(panel)
            return
        }

        let generation = visibilityGeneration
        let side = currentSide
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
            }
        }
    }

    private func show(
        context: ResetCreditsPanelContext,
        relativeTo menuSurfaceWindow: NSWindow?,
        contentView: NSView?
    ) {
        guard let menuSurfaceWindow else {
            hide(immediate: true)
            return
        }

        let panel = ensurePanel()
        let panelSize = ResetCreditsPanelView.panelSize(for: context)
        let position = panelPosition(
            for: panelSize,
            relativeTo: menuSurfaceWindow,
            contentView: contentView,
            alignmentScreenFrame: context.alignmentScreenFrame,
            preferredSide: context.preferredSide
        )

        panel.level = menuSurfaceWindow.level
        defer {
            restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
        }

        visibilityGeneration += 1
        apply(context: context, panelSize: panelSize, position: position, to: panel)
        showPanelWithDrawerAnimation(panel, relativeTo: menuSurfaceWindow)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = ResetCreditsPanel(
            contentRect: NSRect(
                origin: .zero,
                size: ResetCreditsPanelView.initialPanelSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        self.panel = panel
        return panel
    }

    private func updateContent(_ context: ResetCreditsPanelContext, size: CGSize) {
        let rootView = ResetCreditsPanelView(context: context)

        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.sizingOptions = [.preferredContentSize]
            panel?.contentViewController = hostingController
            self.hostingController = hostingController
        }

        configurePanelLayers()
        panel?.setContentSize(size)
    }

    private func apply(
        context: ResetCreditsPanelContext,
        panelSize: CGSize,
        position: PanelPosition,
        to panel: NSPanel
    ) {
        updateContent(context, size: panelSize)
        panel.setFrame(position.frame, display: true)
        panel.alphaValue = 1
        currentSide = position.side
    }

    private func showPanelWithDrawerAnimation(_ panel: NSPanel, relativeTo menuSurfaceWindow: NSWindow) {
        let generation = visibilityGeneration
        let hidden = drawerHiddenTranslation(for: currentSide, panelWidth: panel.frame.width)
        setContentTranslation(hidden)
        panel.alphaValue = 0
        attach(panel, to: menuSurfaceWindow)
        panel.order(.above, relativeTo: menuSurfaceWindow.windowNumber)
        animateContentTranslationAfterInitialLayout(
            from: hidden,
            panel: panel,
            generation: generation
        )
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

    private func configurePanelLayer(for view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = ResetCreditsPanelView.panelCornerRadius
        view.layer?.cornerCurve = .continuous
    }

    private func panelPosition(
        for panelSize: CGSize,
        relativeTo menuSurfaceWindow: NSWindow,
        contentView: NSView?,
        alignmentScreenFrame: CGRect?,
        preferredSide: UsageHeatmapDetailSide
    ) -> PanelPosition {
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
        let y = clamped(
            proposedY(
                for: panelSize,
                menuSurfaceFrame: menuSurfaceFrame,
                alignmentScreenFrame: alignmentScreenFrame
            ),
            lower: max(visibleFrame.minY + Metrics.screenPadding, menuSurfaceFrame.minY),
            upper: visibleFrame.maxY - panelSize.height - Metrics.screenPadding
        )
        let frame = NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)

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

    private func proposedY(
        for panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        alignmentScreenFrame: CGRect?
    ) -> CGFloat {
        if let alignmentScreenFrame {
            return alignmentScreenFrame.maxY - panelSize.height
        }

        return menuSurfaceFrame.midY - panelSize.height / 2
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
        static let drawerEnterDuration: TimeInterval = 0.18
        static let drawerExitDuration: TimeInterval = 0.12
        static let drawerOverscan: CGFloat = 1
        static let drawerTransformAnimationKey = "CodexBar.resetCreditsDrawerTransform"
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
}
