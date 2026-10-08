import AppKit
import SwiftUI

// MARK: - 抽屉动效

@MainActor
final class SidePanelDrawerAnimator {
    private let contentViewProvider: @MainActor () -> NSView?
    private let animationKey: String
    private let overscan: CGFloat

    init(
        contentViewProvider: @escaping @MainActor () -> NSView?,
        animationKey: String,
        overscan: CGFloat
    ) {
        self.contentViewProvider = contentViewProvider
        self.animationKey = animationKey
        self.overscan = overscan
    }

    func hiddenTranslation(for side: UsageHeatmapDetailSide, panelWidth: CGFloat) -> CGFloat {
        let distance = panelWidth + overscan
        switch side {
        case .left:
            return distance
        case .right:
            return -distance
        }
    }

    func setTranslation(_ translationX: CGFloat) {
        guard let layer = contentViewProvider()?.layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: animationKey)
        layer.transform = CATransform3DMakeTranslation(translationX, 0, 0)
        CATransaction.commit()
    }

    func animateTranslation(
        from fromTranslationX: CGFloat? = nil,
        to translationX: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        completion: (() -> Void)? = nil
    ) {
        guard let layer = contentViewProvider()?.layer else {
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
        layer.add(animation, forKey: animationKey)
        layer.transform = targetTransform

        CATransaction.commit()
    }

    func animateEntryAfterInitialLayout(
        from hiddenTranslationX: CGFloat,
        panel: NSPanel,
        duration: TimeInterval,
        isCurrent: @escaping @MainActor () -> Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        CATransaction.flush()

        Task { @MainActor [weak self, weak panel] in
            await Task.yield()
            // 过期请求的隐藏和清理由调用方的 generation 流程负责
            guard let self,
                  let panel,
                  panel.isVisible,
                  isCurrent() else {
                return
            }

            setTranslation(hiddenTranslationX)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            CATransaction.flush()
            panel.alphaValue = 1
            animateTranslation(
                from: hiddenTranslationX,
                to: 0,
                duration: duration,
                timing: .easeOut
            ) {
                Task { @MainActor in
                    guard isCurrent() else {
                        return
                    }

                    completion()
                }
            }
        }
    }

    func resetVisualState(for panel: NSPanel) {
        setTranslation(0)
        panel.alphaValue = 1
    }
}

// MARK: - 展开与收起

/// 抽屉面板共用的显隐状态机, 用于重置次数 设置子选项和任务中心
/// 负责 generation 竞态防护 入退场动画和 child window 挂载与卸载
/// 热力图详情面板带切边与延迟隐藏 状态机不同 因此不走这里
@MainActor
final class SidePanelDrawerPresenter {
    private let usesUntranslatedInitialLayout: Bool
    private let drawerAnimator: SidePanelDrawerAnimator
    private weak var panel: NSPanel?
    private var visibilityGeneration = 0
    private var isExitAnimationRunning = false
    private var currentSide = UsageHeatmapDetailSide.right
    private weak var parentWindow: NSWindow?

    init(
        animationKey: String,
        usesUntranslatedInitialLayout: Bool = false,
        contentViewProvider: @escaping @MainActor () -> NSView?
    ) {
        self.usesUntranslatedInitialLayout = usesUntranslatedInitialLayout
        drawerAnimator = SidePanelDrawerAnimator(
            contentViewProvider: contentViewProvider,
            animationKey: animationKey,
            overscan: SidePanelSupport.Metrics.drawerOverscan
        )
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }

    /// 内容更新由调用方在 present 之前完成
    func present(
        _ panel: NSPanel,
        at position: SidePanelPosition,
        relativeTo parentWindow: NSWindow,
        completion: @escaping @MainActor () -> Void = {}
    ) {
        self.panel = panel
        visibilityGeneration += 1
        isExitAnimationRunning = false
        panel.setFrame(position.frame, display: true)
        currentSide = position.side

        let generation = visibilityGeneration
        let hidden = drawerAnimator.hiddenTranslation(for: currentSide, panelWidth: panel.frame.width)
        drawerAnimator.setTranslation(usesUntranslatedInitialLayout ? 0 : hidden)
        panel.alphaValue = 0
        self.parentWindow = parentWindow
        SidePanelSupport.attach(panel, to: parentWindow)
        panel.order(.above, relativeTo: parentWindow.windowNumber)
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

                drawerAnimator.setTranslation(0)
                completion()
            }
        )
    }

    func hide(immediate: Bool = false) {
        guard let panel else {
            return
        }

        // 不可见的子窗口仍可能挂在父窗口上, 收尾不能只依据 isVisible
        if immediate || !panel.isVisible {
            visibilityGeneration += 1
            drawerAnimator.resetVisualState(for: panel)
            isExitAnimationRunning = false
            orderOut(panel)
            return
        }

        guard !isExitAnimationRunning else {
            return
        }

        visibilityGeneration += 1
        let generation = visibilityGeneration
        let side = currentSide
        isExitAnimationRunning = true
        let hidden = drawerAnimator.hiddenTranslation(for: side, panelWidth: panel.frame.width)
        drawerAnimator.animateTranslation(
            to: hidden,
            duration: SidePanelSupport.Metrics.drawerExitDuration,
            timing: .easeIn
        ) { [weak self] in
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

    private func orderOut(_ panel: NSPanel) {
        SidePanelSupport.orderOut(panel, menuSurfaceWindow: parentWindow)
    }
}

// MARK: - 内容宿主

/// 侧边面板的内容宿主: 懒建 panel + hostingController, 统一"替换 rootView → configureLayers → setContentSize"的更新序列
/// ⚠️ 每次更新都整树替换 rootView 是刻意行为 (见 CLAUDE.md 热力图详情面板的说明), 不要改成常驻状态推送
@MainActor
final class SidePanelContentHost<Root: View> {
    private(set) var panel: NSPanel?
    private var hostingController: NSHostingController<Root>?
    private let initialSize: CGSize
    private let ignoresMouseEvents: Bool
    private let sizingOptions: NSHostingSizingOptions
    private let cornerRadius: CGFloat

    init(
        initialSize: CGSize,
        ignoresMouseEvents: Bool,
        sizingOptions: NSHostingSizingOptions,
        cornerRadius: CGFloat
    ) {
        self.initialSize = initialSize
        self.ignoresMouseEvents = ignoresMouseEvents
        self.sizingOptions = sizingOptions
        self.cornerRadius = cornerRadius
    }

    var contentView: NSView? {
        hostingController?.view
    }

    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool {
        guard let panel, panel.isVisible else {
            return false
        }

        return panel.frame.contains(screenPoint)
    }

    func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = SidePanelSupport.makePanel(
            initialSize: initialSize,
            ignoresMouseEvents: ignoresMouseEvents
        )
        self.panel = panel
        return panel
    }

    func updateContent(_ rootView: Root, size: CGSize) {
        if let hostingController {
            hostingController.rootView = rootView
        } else {
            let hostingController = NSHostingController(rootView: rootView)
            hostingController.sizingOptions = sizingOptions
            panel?.contentViewController = hostingController
            self.hostingController = hostingController
        }

        SidePanelSupport.configureLayers(
            hostingView: hostingController?.view,
            contentView: panel?.contentView,
            cornerRadius: cornerRadius
        )
        panel?.setContentSize(size)
    }
}
