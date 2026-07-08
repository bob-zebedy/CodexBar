import AppKit
import QuartzCore

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

@MainActor
enum SidePanelSupport {
    /// 两个侧边详情面板共用的几何与抽屉动画常量
    enum Metrics {
        static let panelGap: CGFloat = 4
        static let screenPadding: CGFloat = 8
        static let drawerEnterDuration: TimeInterval = 0.18
        static let drawerExitDuration: TimeInterval = 0.12
        static let drawerOverscan: CGFloat = 1
    }

    static func makePanel(initialSize: CGSize, ignoresMouseEvents: Bool) -> NSPanel {
        let panel = NonactivatingSidePanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
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

nonisolated struct SidePanelHorizontalPlacement {
    let x: CGFloat
    let side: UsageHeatmapDetailSide
    let isAvailable: Bool
}

nonisolated struct SidePanelPosition {
    let frame: NSRect
    let side: UsageHeatmapDetailSide
}
