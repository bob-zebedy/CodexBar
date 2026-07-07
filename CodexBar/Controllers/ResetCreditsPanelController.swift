import AppKit
import QuartzCore
import SwiftUI

/// 重置次数详情控制器, 复用热力图详情的侧边抽屉动效
@MainActor
final class ResetCreditsPanelController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ResetCreditsPanelView>?
    private lazy var drawerAnimator = SidePanelDrawerAnimator(
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        },
        animationKey: Metrics.drawerTransformAnimationKey,
        overscan: Metrics.drawerOverscan
    )
    private var visibilityGeneration = 0
    private var isExitAnimationRunning = false
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
        guard let panel, panel.isVisible else {
            return
        }

        if immediate {
            visibilityGeneration += 1
            hideImmediately(panel)
            return
        }

        guard !isExitAnimationRunning else {
            return
        }

        hideWithAnimation(panel)
    }

    private func hideImmediately(_ panel: NSPanel) {
        drawerAnimator.resetVisualState(for: panel)
        isExitAnimationRunning = false
        orderOut(panel)
    }

    private func hideWithAnimation(_ panel: NSPanel) {
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let side = currentSide
        isExitAnimationRunning = true
        let hidden = drawerAnimator.hiddenTranslation(for: side, panelWidth: panel.frame.width)
        drawerAnimator.animateTranslation(
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
                drawerAnimator.setTranslation(0)
                isExitAnimationRunning = false
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
        let menuSurfaceFrame = SidePanelSupport.contentScreenFrame(for: contentView, in: menuSurfaceWindow) ?? menuSurfaceWindow.frame
        let alignmentScreenFrame = validAlignmentScreenFrame(
            context.alignmentScreenFrame,
            menuSurfaceFrame: menuSurfaceFrame
        )
        let resolvedContext = context.withPanelGeometry(
            alignmentScreenFrame: alignmentScreenFrame,
            maximumPanelHeight: panelMaximumHeight(
                menuSurfaceFrame: menuSurfaceFrame,
                alignmentScreenFrame: alignmentScreenFrame
            )
        )
        let panelSize = ResetCreditsPanelView.panelSize(for: resolvedContext)
        let position = panelPosition(
            for: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: (menuSurfaceWindow.screen ?? NSScreen.main)?.visibleFrame ?? menuSurfaceFrame,
            alignmentScreenFrame: resolvedContext.alignmentScreenFrame,
            preferredSide: resolvedContext.preferredSide
        )

        panel.level = menuSurfaceWindow.level
        defer {
            SidePanelSupport.restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
        }

        visibilityGeneration += 1
        isExitAnimationRunning = false
        apply(context: resolvedContext, panelSize: panelSize, position: position, to: panel)
        showPanelWithDrawerAnimation(panel, relativeTo: menuSurfaceWindow)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NonactivatingSidePanel(
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

        SidePanelSupport.configureLayers(
            hostingView: hostingController?.view,
            contentView: panel?.contentView,
            cornerRadius: ResetCreditsPanelView.panelCornerRadius
        )
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
        let hidden = drawerAnimator.hiddenTranslation(for: currentSide, panelWidth: panel.frame.width)
        drawerAnimator.setTranslation(hidden)
        panel.alphaValue = 0
        attach(panel, to: menuSurfaceWindow)
        panel.order(.above, relativeTo: menuSurfaceWindow.windowNumber)
        drawerAnimator.animateEntryAfterInitialLayout(
            from: hidden,
            panel: panel,
            duration: Metrics.drawerEnterDuration,
            isCurrent: { [weak self] in
                self?.visibilityGeneration == generation
            },
            completion: { [weak self] in
                self?.drawerAnimator.setTranslation(0)
            }
        )
    }

    private func attach(_ panel: NSPanel, to parentWindow: NSWindow) {
        menuSurfaceWindow = parentWindow
        SidePanelSupport.attach(panel, to: parentWindow)
    }

    private func orderOut(_ panel: NSPanel) {
        SidePanelSupport.orderOut(panel, menuSurfaceWindow: menuSurfaceWindow)
    }

    private func panelPosition(
        for panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        visibleFrame: CGRect,
        alignmentScreenFrame: CGRect?,
        preferredSide: UsageHeatmapDetailSide
    ) -> PanelPosition {
        let leftX = menuSurfaceFrame.minX - Metrics.panelGap - panelSize.width
        let rightX = menuSurfaceFrame.maxX + Metrics.panelGap
        let horizontal = SidePanelSupport.horizontalPlacement(
            preferredSide: preferredSide,
            left: SidePanelHorizontalPlacement(
                x: leftX,
                side: .left,
                isAvailable: leftX >= visibleFrame.minX + Metrics.screenPadding
            ),
            right: SidePanelHorizontalPlacement(
                x: rightX,
                side: .right,
                isAvailable: rightX + panelSize.width <= visibleFrame.maxX - Metrics.screenPadding
            )
        )

        let x = SidePanelSupport.clamped(
            horizontal.x,
            lower: visibleFrame.minX + Metrics.screenPadding,
            upper: visibleFrame.maxX - panelSize.width - Metrics.screenPadding
        )
        let y = SidePanelSupport.clamped(
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
            side: SidePanelSupport.actualSide(
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

    private func panelMaximumHeight(
        menuSurfaceFrame: CGRect,
        alignmentScreenFrame: CGRect?
    ) -> CGFloat? {
        guard let alignmentScreenFrame else {
            return nil
        }

        let maximumHeight = alignmentScreenFrame.maxY - menuSurfaceFrame.minY
        guard maximumHeight.isFinite, maximumHeight > 0 else {
            return nil
        }
        return maximumHeight
    }

    private func validAlignmentScreenFrame(
        _ alignmentScreenFrame: CGRect?,
        menuSurfaceFrame: CGRect
    ) -> CGRect? {
        guard let alignmentScreenFrame = alignmentScreenFrame?.standardized,
              isValidScreenFrame(alignmentScreenFrame) else {
            return nil
        }

        let validationFrame = menuSurfaceFrame
            .standardized
            .insetBy(
                dx: -Metrics.anchorValidationTolerance,
                dy: -Metrics.anchorValidationTolerance
            )
        guard validationFrame.intersects(alignmentScreenFrame) else {
            return nil
        }

        return alignmentScreenFrame
    }

    private func isValidScreenFrame(_ frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private enum Metrics {
        static let panelGap: CGFloat = 4
        static let screenPadding: CGFloat = 8
        static let anchorValidationTolerance: CGFloat = 6
        static let drawerEnterDuration: TimeInterval = 0.18
        static let drawerExitDuration: TimeInterval = 0.12
        static let drawerOverscan: CGFloat = 1
        static let drawerTransformAnimationKey = "CodexBar.resetCreditsDrawerTransform"
    }

    private struct PanelPosition {
        let frame: NSRect
        let side: UsageHeatmapDetailSide
    }
}
