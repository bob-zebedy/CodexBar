import AppKit
import QuartzCore

@MainActor
final class AppearanceTransition {
    static let didChangeNotification = Notification.Name("CodexBar.appearanceTransitionDidChange")

    static func isActive(in window: NSWindow) -> Bool {
        window.childWindows?.contains { $0 is SnapshotPanel } == true
    }

    static func setSnapshotAlpha(in window: NSWindow?, to alpha: CGFloat) {
        for snapshot in snapshotPanels(in: window) {
            snapshot.alphaValue = alpha
            snapshot.snapshotView.alphaValue = alpha
        }
    }

    /// 复用调用方的动画事务, 保持快照与源窗口的时间和曲线一致
    static func fadeSnapshots(in window: NSWindow?, to alpha: CGFloat) {
        for snapshot in snapshotPanels(in: window) {
            snapshot.animator().alphaValue = alpha
            snapshot.snapshotView.animator().alphaValue = alpha
        }
    }

    static func setSnapshotTranslation(in window: NSWindow?, to transform: CATransform3D) {
        snapshotPanels(in: window).forEach { $0.snapshotView.setTranslation(transform) }
    }

    static func animateSnapshotTranslation(in window: NSWindow?, animation: CABasicAnimation, to transform: CATransform3D) {
        snapshotPanels(in: window).forEach { $0.snapshotView.animateTranslation(animation, to: transform) }
    }

    static func dismissSnapshots(in window: NSWindow?) {
        snapshotPanels(in: window).forEach { $0.dismiss() }
    }

    private static func snapshotPanels(in window: NSWindow?) -> [SnapshotPanel] {
        window?.childWindows?.compactMap { $0 as? SnapshotPanel } ?? []
    }

    static func anchoredOrigin(from screenPoint: CGPoint?, isSourceWindow: Bool, screenFrame: CGRect, mouseLocation: CGPoint) -> CGPoint? {
        let point: CGPoint
        if let screenPoint, isSourceWindow {
            point = screenPoint
        } else if screenFrame.contains(mouseLocation) {
            point = mouseLocation
        } else {
            return nil
        }
        return CGPoint(
            x: (point.x - screenFrame.minX) / screenFrame.width,
            y: (screenFrame.maxY - point.y) / screenFrame.height
        )
    }

    private let animationsEnabled: () -> Bool
    private var observation: NSKeyValueObservation?
    private var pendingSnapshots: [(NSWindow, SnapshotPanel)]?
    private var changeOrigin: AppearanceSettings.TransitionOrigin?

    init(animationsEnabled: @escaping () -> Bool) {
        self.animationsEnabled = animationsEnabled
        observation = NSApplication.shared.observe(\.effectiveAppearance, options: [.prior]) { [weak self] _, change in
            let isPrior = change.isPrior
            MainActor.assumeIsolated {
                guard let self else { return }
                if isPrior {
                    self.capture()
                } else {
                    // App 的通知先于窗口外观更新, 等本轮赋值和面板同步完成后再揭示新画面
                    DispatchQueue.main.async { self.reveal() }
                }
            }
        }
    }

    func performChange(from origin: AppearanceSettings.TransitionOrigin?, _ change: () -> Void) {
        let previousOrigin = changeOrigin
        changeOrigin = origin
        defer { changeOrigin = previousOrigin }
        change()
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        pendingSnapshots?.forEach { $0.1.dismiss() }
        pendingSnapshots = nil
        NSApplication.shared.windows.compactMap { $0 as? SnapshotPanel }.forEach { $0.dismiss() }
    }

    private func capture() {
        // 同一轮内连续切换时保留最初画面, 最终外观由 AppKit 决定
        guard pendingSnapshots == nil else { return }
        let animated = animationsEnabled()
        let mouseLocation = NSEvent.mouseLocation
        let windows = NSApplication.shared.windows.filter {
            $0.isVisible && !$0.isMiniaturized && !($0 is SnapshotPanel) && !($0 is TaskGlowPanel)
        }
        pendingSnapshots = windows.compactMap { window -> (NSWindow, SnapshotPanel)? in
            let previous = window.childWindows?.compactMap { $0 as? SnapshotPanel } ?? []
            previous.forEach { $0.snapshotView.freeze() }
            let snapshot = animated ? SnapshotPanel(capturing: window, previous: previous, changeOrigin: changeOrigin, mouseLocation: mouseLocation) : nil
            // 先接上新快照, 避免连续切换时短暂报告过渡已结束
            snapshot?.present(over: window)
            previous.forEach { $0.dismiss() }
            guard let snapshot else { return nil }
            return (window, snapshot)
        }
    }

    private func reveal() {
        guard let snapshots = pendingSnapshots else { return }
        pendingSnapshots = nil
        for (window, snapshot) in snapshots {
            guard animationsEnabled(), window.isVisible, !window.isMiniaturized,
                  let view = window.contentView,
                  view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != snapshot.sourceAppearance else {
                snapshot.dismiss()
                continue
            }
            snapshot.reveal()
        }
    }

    /// 过渡使用独立子窗口, 不向 NSThemeFrame 或 NSHostingView 管理的层级插入视图
    private final class SnapshotPanel: NSPanel {
        let sourceAppearance: NSAppearance.Name?
        let snapshotView: SnapshotView
        private var observers: [any NSObjectProtocol] = []
        private var isDismissed = false

        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }

        init?(capturing window: NSWindow, previous: [SnapshotPanel], changeOrigin: AppearanceSettings.TransitionOrigin?, mouseLocation: CGPoint) {
            guard let view = Self.sourceView(in: window), !view.bounds.isEmpty,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            for panel in previous {
                panel.snapshotView.composite(over: bitmap)
            }
            sourceAppearance = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(bitmap)
            let screenFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
            let origin = AppearanceTransition.anchoredOrigin(
                from: changeOrigin?.screenPoint,
                isSourceWindow: changeOrigin?.window === window,
                screenFrame: screenFrame,
                mouseLocation: mouseLocation
            )
            snapshotView = SnapshotView(image: image, origin: origin)
            let hasTitlebar = window.styleMask.contains(.titled)
            super.init(
                contentRect: screenFrame,
                styleMask: hasTitlebar ? [.titled, .fullSizeContentView, .nonactivatingPanel] : [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            if hasTitlebar {
                // 让 AppKit 裁剪原生窗口圆角, 快照覆盖标题栏和内容区域
                titleVisibility = .hidden
                titlebarAppearsTransparent = true
                for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    standardWindowButton(button)?.isHidden = true
                }
            }
            isReleasedWhenClosed = false
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            hidesOnDeactivate = false
            isExcludedFromWindowsMenu = true
            collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            animationBehavior = .none
            // 原生窗口管理内容视图的裁剪, 渐变遮罩留在独立子视图上
            let container = NSView(frame: snapshotView.frame)
            container.addSubview(snapshotView)
            contentView = container
        }

        func present(over window: NSWindow) {
            guard let view = Self.sourceView(in: window) else {
                dismiss()
                return
            }
            setFrame(window.convertToScreen(view.convert(view.bounds, to: nil)), display: true)
            level = window.level
            let wasActive = AppearanceTransition.isActive(in: window)
            window.addChildWindow(self, ordered: .above)
            orderFront(nil)
            if !wasActive {
                NotificationCenter.default.post(name: AppearanceTransition.didChangeNotification, object: window)
            }
            for name in [
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didResizeNotification
            ] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sourceWindowChanged(name) }
                })
            }
        }

        func reveal() {
            guard !isDismissed else { return }
            snapshotView.reveal { [weak self] in self?.dismiss() }
        }

        func dismiss() {
            guard !isDismissed else { return }
            isDismissed = true
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            snapshotView.freeze()
            let sourceWindow = parent
            sourceWindow?.removeChildWindow(self)
            orderOut(nil)
            close()
            if let sourceWindow, !AppearanceTransition.isActive(in: sourceWindow) {
                NotificationCenter.default.post(name: AppearanceTransition.didChangeNotification, object: sourceWindow)
            }
        }

        private func sourceWindowChanged(_ name: Notification.Name) {
            guard let window = parent, window.isVisible, !window.isMiniaturized else {
                dismiss()
                return
            }
            if name == NSWindow.didResizeNotification, let view = Self.sourceView(in: window) {
                setFrame(window.convertToScreen(view.convert(view.bounds, to: nil)), display: true)
            } else if name != NSWindow.didChangeOcclusionStateNotification {
                dismiss()
            }
        }

        private static func sourceView(in window: NSWindow) -> NSView? {
            guard let contentView = window.contentView else { return nil }
            // 有标题栏时读取完整窗口视图, 只生成快照, 不修改 AppKit 管理的视图层级
            return window.styleMask.contains(.titled) ? contentView.superview ?? contentView : contentView
        }
    }

    final class SnapshotView: NSImageView {
        private let revealMask = CAGradientLayer()
        private let revealOrigin: CGPoint
        private let translationAnimationKey = "appearanceExitTranslation"

        override var isFlipped: Bool {
            true
        }

        init(image: NSImage, origin: CGPoint? = nil) {
            revealOrigin = origin ?? CGPoint(x: .random(in: 0.1 ... 0.9), y: .random(in: 0.1 ... 0.9))
            super.init(frame: NSRect(origin: .zero, size: image.size))
            self.image = image
            imageScaling = .scaleAxesIndependently
            autoresizingMask = [.width, .height]
            wantsLayer = true
            revealMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
            revealMask.locations = [0, 0]
            updateMaskGeometry()
            layer?.mask = revealMask
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setTranslation(_ transform: CATransform3D) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.removeAnimation(forKey: translationAnimationKey)
            layer?.transform = transform
            CATransaction.commit()
        }

        func animateTranslation(_ animation: CABasicAnimation, to transform: CATransform3D) {
            layer?.add(animation, forKey: translationAnimationKey)
            layer?.transform = transform
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateMaskGeometry()
            CATransaction.commit()
        }

        private func updateMaskGeometry() {
            guard !bounds.isEmpty else { return }
            revealMask.frame = bounds
            let origin = revealOrigin
            let center = CGPoint(x: origin.x * bounds.width, y: origin.y * bounds.height)
            let radius = hypot(
                max(abs(center.x), abs(bounds.width - center.x)),
                max(abs(center.y), abs(bounds.height - center.y))
            ) + 1
            revealMask.type = .radial
            revealMask.startPoint = origin
            // 径向渐变按横纵半径绘制椭圆, 分别归一化同一半径才能保持圆形并覆盖最远角
            revealMask.endPoint = CGPoint(x: origin.x + radius / bounds.width, y: origin.y + radius / bounds.height)
        }

        func freeze() {
            let locations = revealMask.presentation()?.locations ?? revealMask.locations
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            revealMask.locations = locations
            revealMask.removeAllAnimations()
            CATransaction.commit()
        }

        func composite(over bitmap: NSBitmapImageRep) {
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            layer?.render(in: context.cgContext)
        }

        func reveal(completion: @escaping @MainActor () -> Void) {
            let animation = CAKeyframeAnimation(keyPath: "locations")
            animation.values = [[0, 0], [0, 0.06], [0.94, 1], [1, 1]]
            animation.keyTimes = [0, 0.03, 0.97, 1]
            animation.duration = 0.5
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.76, 0, 0.24, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock {
                Task { @MainActor in completion() }
            }
            revealMask.locations = [1, 1]
            revealMask.add(animation, forKey: "appearanceReveal")
            CATransaction.commit()
        }
    }
}
