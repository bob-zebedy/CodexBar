import AppKit
import Combine
import SwiftUI

/// 重置次数详情控制器, 复用共享侧边抽屉定位和动画
@MainActor
final class ResetCreditsPanelController {
    private let viewModel: CodexStatusViewModel
    private let mainPanelSettings: MainPanelSettings
    private var snapshotObservation: AnyCancellable?
    private var presentedContent: ResetCreditsPanelContent?
    private let contentHost = SidePanelContentHost<ResetCreditsPanelView>(
        initialSize: ResetCreditsPanelView.initialPanelSize,
        ignoresMouseEvents: false,
        sizingOptions: [],
        cornerRadius: ResetCreditsPanelView.panelCornerRadius
    )
    private lazy var presenter = SidePanelDrawerPresenter(
        animationKey: Metrics.drawerTransformAnimationKey,
        areAnimationsEnabled: { [weak self] in self?.mainPanelSettings.areAnimationsEnabled ?? false },
        contentViewProvider: { [weak self] in
            self?.contentHost.contentView
        }
    )

    init(viewModel: CodexStatusViewModel, mainPanelSettings: MainPanelSettings) {
        self.viewModel = viewModel
        self.mainPanelSettings = mainPanelSettings
    }

    var isVisible: Bool {
        presenter.isVisible
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        contentHost.containsScreenPoint(screenPoint)
    }

    func toggle(
        anchor: ScreenFrameProvider,
        relativeTo menuSurfaceWindow: NSWindow,
        contentView: NSView?
    ) {
        if snapshotObservation != nil || isVisible {
            hide()
            return
        }

        guard let account = viewModel.snapshot?.account else { return }
        snapshotObservation = Self.expirationDateUpdates(from: viewModel.$snapshot, for: account)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hide(immediate: true)
            } receiveValue: { [weak self, weak menuSurfaceWindow, weak contentView] dates in
                guard let self else { return }
                guard let menuSurfaceWindow, menuSurfaceWindow.isVisible else {
                    hide(immediate: true)
                    return
                }
                updateContent(dates, anchor: anchor, window: menuSurfaceWindow, contentView: contentView)
            }
    }

    func hide(immediate: Bool = false) {
        snapshotObservation = nil
        presentedContent = nil
        presenter.hide(immediate: immediate)
    }

    /// 入口消失或账号切换即结束本次展示, 仅缺少到期时间时保留详情
    static func expirationDateUpdates(
        from snapshots: some Publisher<CodexQuotaSnapshot?, Never>,
        for account: CodexAccount
    ) -> some Publisher<[Date], Never> {
        let identity = AutoResetIdentity.accountIdentity(for: account)
        return snapshots.prefix { snapshot in
            guard let snapshot, !snapshot.limits.isEmpty, (snapshot.resetCreditsAvailableCount ?? 0) > 0 else { return false }
            return AutoResetIdentity.accountIdentity(for: snapshot.account) == identity
        }
        .map { $0?.resetCreditExpirationDates ?? [] }
        .removeDuplicates()
    }

    private func updateContent(
        _ dates: [Date],
        anchor: ScreenFrameProvider,
        window menuSurfaceWindow: NSWindow,
        contentView: NSView?
    ) {
        let layout = Placement(anchor: anchor, window: menuSurfaceWindow, contentView: contentView)
        if let presentedContent {
            presentedContent.maximumHeight = layout.maximumHeight
            presentedContent.update(dates, animated: mainPanelSettings.areAnimationsEnabled)
            if let panel = contentHost.panel {
                align(panel, at: layout.position(for: panel.frame.size))
            }
            return
        }

        let content = ResetCreditsPanelContent()
        content.maximumHeight = layout.maximumHeight
        content.update(dates, animated: false)
        presentedContent = content

        let panel = contentHost.ensurePanel()
        let resize = { [weak self, weak menuSurfaceWindow, weak contentView, weak content] (size: CGSize) in
            guard let self, let content, presentedContent === content,
                  let panel = contentHost.panel, panel.isVisible, let menuSurfaceWindow else { return }
            let layout = Placement(anchor: anchor, window: menuSurfaceWindow, contentView: contentView)
            align(panel, at: layout.position(for: size))
        }
        let root = ResetCreditsPanelView(content: content, mainPanelSettings: mainPanelSettings, onSizeChange: resize)
        let size = root.panelSize(at: 1)
        contentHost.updateContent(root, size: size)
        panel.level = menuSurfaceWindow.level
        presenter.present(panel, at: layout.position(for: size), relativeTo: menuSurfaceWindow)
        SidePanelSupport.restoreMenuSurfaceKeyWindow(menuSurfaceWindow)
    }

    private func align(_ panel: NSPanel, at position: SidePanelPosition) {
        presenter.updateSide(position.side)
        if panel.frame != position.frame {
            panel.setFrame(position.frame, display: false)
        }
    }

    private struct Placement {
        let surface: CGRect
        let alignment: CGRect?
        let visibleFrame: CGRect

        init(anchor: ScreenFrameProvider, window: NSWindow, contentView: NSView?) {
            surface = SidePanelSupport.contentScreenFrame(for: contentView, in: window) ?? window.frame
            alignment = SidePanelSupport.validatedAlignmentScreenFrame(anchor.currentScreenFrame(in: window), menuSurfaceFrame: surface)
            visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? surface
        }

        var maximumHeight: CGFloat? {
            guard let alignment else { return nil }
            let height = alignment.maxY - surface.minY
            return height.isFinite && height > 0 ? height : nil
        }

        func position(for size: CGSize) -> SidePanelPosition {
            SidePanelSupport.anchoredPosition(
                panelSize: size, menuSurfaceFrame: surface, visibleFrame: visibleFrame,
                screenFrame: nil, alignmentScreenFrame: alignment, preferredSide: .right
            )
        }
    }

    private enum Metrics {
        static let drawerTransformAnimationKey = "CodexBar.resetCreditsDrawerTransform"
    }
}
