import AppKit
import SwiftUI

/// 重置次数详情控制器, 复用共享侧边抽屉定位和动画
@MainActor
final class ResetCreditsPanelController {
    private let contentHost = SidePanelContentHost<ResetCreditsPanelView>(
        initialSize: ResetCreditsPanelView.initialPanelSize,
        ignoresMouseEvents: false,
        sizingOptions: [.preferredContentSize],
        cornerRadius: ResetCreditsPanelView.panelCornerRadius
    )
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        contentViewProvider: { [weak self] in
            self?.contentHost.contentView
        }
    )

    var isVisible: Bool {
        presenter.isVisible
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        contentHost.containsScreenPoint(screenPoint)
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

        let panel = contentHost.ensurePanel()
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
        let position = SidePanelSupport.anchoredPosition(
            panelSize: panelSize,
            menuSurfaceFrame: menuSurfaceFrame,
            visibleFrame: (menuSurfaceWindow.screen ?? NSScreen.main)?.visibleFrame ?? menuSurfaceFrame,
            screenFrame: nil,
            alignmentScreenFrame: resolvedContext.alignmentScreenFrame,
            preferredSide: resolvedContext.preferredSide
        )

        panel.level = menuSurfaceWindow.level
        defer {
            SidePanelSupport.restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
        }

        contentHost.updateContent(ResetCreditsPanelView(context: resolvedContext), size: panelSize)
        presenter.present(panel, at: position, relativeTo: menuSurfaceWindow)
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
