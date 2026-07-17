import AppKit
import QuartzCore
import SwiftUI

/// 侧边详情面板不接收焦点, 只作为菜单面板的跟随子窗口
@MainActor
final class NonactivatingSidePanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// 可获得键盘焦点的无边框面板, 用于含交互控件的子面板和 fallback 面板
@MainActor
final class KeyableBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

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
            // 过期请求的隐藏和清理由调用方的 generation 流程负责。
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

/// 重置次数、通知子选项和并发任务中心三类「一次性展开」抽屉面板共用的显隐状态机:
/// 负责 generation 竞态防护、入退场动画和 child window 挂载/卸载
/// (热力图详情面板因带切边与延迟隐藏, 状态机不同, 不走这里)
@MainActor
final class SidePanelDrawerPresenter {
    private let makesKey: Bool
    private let drawerAnimator: SidePanelDrawerAnimator
    private weak var panel: NSPanel?
    private var visibilityGeneration = 0
    private var isExitAnimationRunning = false
    private var currentSide = UsageHeatmapDetailSide.right
    private weak var parentWindow: NSWindow?

    init(
        animationKey: String,
        makesKey: Bool = false,
        contentViewProvider: @escaping @MainActor () -> NSView?
    ) {
        self.makesKey = makesKey
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
    func present(_ panel: NSPanel, at position: SidePanelPosition, relativeTo parentWindow: NSWindow) {
        self.panel = panel
        visibilityGeneration += 1
        isExitAnimationRunning = false
        panel.setFrame(position.frame, display: true)
        currentSide = position.side

        let generation = visibilityGeneration
        let hidden = drawerAnimator.hiddenTranslation(for: currentSide, panelWidth: panel.frame.width)
        drawerAnimator.setTranslation(hidden)
        panel.alphaValue = 0
        self.parentWindow = parentWindow
        SidePanelSupport.attach(panel, to: parentWindow)
        panel.order(.above, relativeTo: parentWindow.windowNumber)
        if makesKey {
            panel.makeKey()
        }
        drawerAnimator.animateEntryAfterInitialLayout(
            from: hidden,
            panel: panel,
            duration: SidePanelSupport.Metrics.drawerEnterDuration,
            isCurrent: { [weak self] in
                self?.visibilityGeneration == generation
            },
            completion: { [weak self] in
                self?.drawerAnimator.setTranslation(0)
            }
        )
    }

    func hide(immediate: Bool = false) {
        guard let panel, panel.isVisible else {
            return
        }

        if immediate {
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

    private func orderOut(_ panel: NSPanel) {
        SidePanelSupport.orderOut(panel, menuSurfaceWindow: parentWindow)
    }
}

/// 侧边面板的内容宿主: 懒建 panel + hostingController, 统一「替换 rootView →
/// configureLayers → setContentSize」的更新序列
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

    // Swift 6.3.3 的 EarlyPerfInliner 会在优化该泛型类型的合成析构函数时崩溃。
    @_optimize(none)
    deinit {}

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

@MainActor
enum SidePanelSupport {
    /// 侧边面板共用的几何与抽屉动画常量
    enum Metrics {
        static let panelGap: CGFloat = 4
        static let screenPadding: CGFloat = 8
        static let drawerEnterDuration: TimeInterval = 0.18
        static let drawerExitDuration: TimeInterval = 0.12
        static let drawerOverscan: CGFloat = 1
        static let anchorValidationTolerance: CGFloat = 6
    }

    /// keyable 决定面板能否成为 key window: 交互面板需要焦点, 详情面板保持 nonactivating
    static func makePanel(
        initialSize: CGSize,
        ignoresMouseEvents: Bool,
        keyable: Bool = false
    ) -> NSPanel {
        let contentRect = NSRect(origin: .zero, size: initialSize)
        let panel: NSPanel = keyable
            ? KeyableBorderlessPanel(
                contentRect: contentRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            : NonactivatingSidePanel(
                contentRect: contentRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }

    /// 水平方向优先贴在请求侧, 空间不足时换边, 最后夹紧到屏幕可见区域
    /// 纵向由调用方给出期望位置, 这里统一夹紧
    static func position(
        panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        visibleFrame: CGRect,
        preferredSide: UsageHeatmapDetailSide,
        proposedY: CGFloat
    ) -> SidePanelPosition {
        let leftX = menuSurfaceFrame.minX - Metrics.panelGap - panelSize.width
        let rightX = menuSurfaceFrame.maxX + Metrics.panelGap
        let horizontal = horizontalPlacement(
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

        let x = clamped(
            horizontal.x,
            lower: visibleFrame.minX + Metrics.screenPadding,
            upper: visibleFrame.maxX - panelSize.width - Metrics.screenPadding
        )
        let y = clamped(
            proposedY,
            lower: max(visibleFrame.minY + Metrics.screenPadding, menuSurfaceFrame.minY),
            upper: visibleFrame.maxY - panelSize.height - Metrics.screenPadding
        )

        return SidePanelPosition(
            frame: NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height),
            side: actualSide(
                forX: x,
                panelWidth: panelSize.width,
                menuSurfaceFrame: menuSurfaceFrame,
                fallback: horizontal.side
            )
        )
    }

    static func attach(_ panel: NSPanel, to parentWindow: NSWindow) {
        guard panel.parent !== parentWindow else {
            return
        }

        panel.parent?.removeChildWindow(panel)
        parentWindow.addChildWindow(panel, ordered: .above)
    }

    static func orderOut(_ panel: NSPanel, menuSurfaceWindow: NSWindow?) {
        let parentWindow = panel.parent ?? menuSurfaceWindow
        panel.orderOut(nil)
        parentWindow?.removeChildWindow(panel)
        restoreMenuSurfaceKeyWindow(parentWindow)
    }

    static func restoreMenuSurfaceKeyWindow(_ menuSurfaceWindow: NSWindow?) {
        guard NSApplication.shared.isActive else {
            return
        }

        menuSurfaceWindow?.makeKey()
    }

    static func configureLayers(
        hostingView: NSView?,
        contentView: NSView?,
        cornerRadius: CGFloat
    ) {
        if let hostingView {
            configureLayer(for: hostingView, cornerRadius: cornerRadius)
        }

        if let contentView {
            configureLayer(for: contentView, cornerRadius: cornerRadius)
            if let frameView = contentView.superview {
                configureLayer(for: frameView, cornerRadius: cornerRadius)
            }
        }
    }

    /// 面板顶边对齐锚点行顶边, 锚点无效时回退宿主内容区垂直居中
    static func alignedProposedY(
        panelSize: CGSize,
        menuSurfaceFrame: CGRect,
        alignmentScreenFrame: CGRect?
    ) -> CGFloat {
        guard let alignmentScreenFrame else {
            return menuSurfaceFrame.midY - panelSize.height / 2
        }

        return alignmentScreenFrame.maxY - panelSize.height
    }

    /// 宿主菜单面板可能进入系统菜单栏保留区域; 面板定位只向上放宽到锚点行顶边,
    /// 让两者顶边对齐, 同时继续沿用 visibleFrame 的左右边界和 Dock 下边界
    static func anchorAwareVisibleFrame(
        visibleFrame: CGRect,
        screenFrame: CGRect?,
        alignmentScreenFrame: CGRect?
    ) -> CGRect {
        guard let screenFrame, let alignmentScreenFrame else {
            return visibleFrame
        }

        let permittedMaxY = min(
            screenFrame.maxY,
            max(
                visibleFrame.maxY,
                alignmentScreenFrame.maxY + Metrics.screenPadding
            )
        )
        return CGRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: permittedMaxY - visibleFrame.minY
        )
    }

    /// 锚点必须落在宿主内容区容差范围内才可信, 否则丢弃并走回退定位
    static func validatedAlignmentScreenFrame(
        _ alignmentScreenFrame: CGRect?,
        menuSurfaceFrame: CGRect
    ) -> CGRect? {
        guard let alignmentScreenFrame = alignmentScreenFrame?.standardized,
              alignmentScreenFrame.isValidScreenRect else {
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

    static func contentScreenFrame(for contentView: NSView?, in window: NSWindow) -> CGRect? {
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

    private static func clamped(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else {
            return lower
        }

        return min(max(value, lower), upper)
    }

    private static func horizontalPlacement(
        preferredSide: UsageHeatmapDetailSide,
        left: SidePanelHorizontalPlacement,
        right: SidePanelHorizontalPlacement
    ) -> SidePanelHorizontalPlacement {
        let primary = preferredSide == .left ? left : right
        let fallback = preferredSide == .left ? right : left

        if primary.isAvailable {
            return primary
        }
        return fallback.isAvailable ? fallback : primary
    }

    private static func actualSide(
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

    private static func configureLayer(for view: NSView, cornerRadius: CGFloat) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
    }
}

private nonisolated struct SidePanelHorizontalPlacement {
    let x: CGFloat
    let side: UsageHeatmapDetailSide
    let isAvailable: Bool
}

nonisolated struct SidePanelPosition {
    let frame: NSRect
    let side: UsageHeatmapDetailSide
}
