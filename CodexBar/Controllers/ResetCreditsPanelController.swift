import AppKit
import SwiftUI

/// 重置次数详情控制器, 复用热力图详情的侧边抽屉动效
@MainActor
final class ResetCreditsPanelController {
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ResetCreditsPanelView>?
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        contentViewProvider: { [weak self] in
            self?.hostingController?.view
        }
    )

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
        presenter.hide(immediate: immediate)
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
        let alignmentScreenFrame = SidePanelSupport.validatedAlignmentScreenFrame(
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

        updateContent(resolvedContext, size: panelSize)
        presenter.present(panel, at: position, relativeTo: menuSurfaceWindow)
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = SidePanelSupport.makePanel(
            initialSize: ResetCreditsPanelView.initialPanelSize,
            ignoresMouseEvents: false
        )
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

    private func panelPosition(
        for panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        visibleFrame: CGRect,
        alignmentScreenFrame: CGRect?,
        preferredSide: UsageHeatmapDetailSide
    ) -> SidePanelPosition {
        SidePanelSupport.position(
            panelSize: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: visibleFrame,
            preferredSide: preferredSide,
            proposedY: SidePanelSupport.alignedProposedY(
                panelSize: panelSize,
                menuSurfaceFrame: menuSurfaceFrame,
                alignmentScreenFrame: alignmentScreenFrame
            )
        )
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

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.resetCreditsDrawerTransform"
    }
}
