import AppKit
import Combine
import QuartzCore

/// 只消费实时任务的展示更新, 不参与任务通知或防睡眠判定
@MainActor
final class TaskGlowController {
    private let settings: TaskGlowSettings
    private let activityMonitor: CodexActivityMonitor
    private let hookSettings: CodexHookSettings
    private var cancellables = Set<AnyCancellable>()
    private var panels: [TaskGlowPanel] = []
    private let motionClock = TaskGlowMotionClock()
    private var presentation = TaskGlowPresentationState()
    private var isEnabled = false
    private var expirationTask: Task<Void, Never>?
    private var scheduledExpiration: Date?
    private var hidePanelsTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var isPreviewVisible = false
    private var isSystemSleeping = false
    private var isDisplaySleeping = false
    private var isSessionActive = true

    init(
        settings: TaskGlowSettings,
        activityMonitor: CodexActivityMonitor,
        hookSettings: CodexHookSettings
    ) {
        self.settings = settings
        self.activityMonitor = activityMonitor
        self.hookSettings = hookSettings
    }

    deinit {
        expirationTask?.cancel()
        hidePanelsTask?.cancel()
        previewTask?.cancel()
    }

    func start() {
        guard cancellables.isEmpty else { return }
        Publishers.CombineLatest3(
            settings.$isEnabled,
            hookSettings.$isEnabled,
            hookSettings.$isVerified
        )
        .sink { [weak self] enabled, hookEnabled, hookVerified in
            guard let self else { return }
            if !hookEnabled || !hookVerified {
                cancelPreview()
            }
            if !enabled {
                isPreviewVisible = false
            }
            isEnabled = enabled && hookEnabled && hookVerified
            consume(CodexActivityPresentationUpdate(snapshot: activityMonitor.snapshot, terminalEvents: []))
        }
        .store(in: &cancellables)

        settings.previewRequests
            .sink { [weak self] in self?.previewEnabled() }
            .store(in: &cancellables)

        activityMonitor.presentationPublisher
            .sink { [weak self] update in self?.consume(update) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.removePanels(preservingMotion: true)
                self?.refreshPresentation()
            }
            .store(in: &cancellables)

        let workspaceNotifications = [
            NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification
        ]
        Publishers.MergeMany(workspaceNotifications.map {
            NSWorkspace.shared.notificationCenter.publisher(for: $0)
        })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            self?.handleWorkspaceNotification(notification)
        }
        .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        expirationTask?.cancel()
        expirationTask = nil
        scheduledExpiration = nil
        cancelPreview()
        presentation = TaskGlowPresentationState()
        isEnabled = false
        removePanels()
    }

    private func previewEnabled() {
        guard previewTask == nil, hidePanelsTask == nil, isEnabled, hookSettings.isOperable,
              !isSystemSleeping, !isDisplaySleeping, isSessionActive else { return }
        // 播放和收尾期间不重播, 提前关闭时由实际收尾完成释放预览
        removePanels()
        isPreviewVisible = true
        motionClock.setRunning(true)
        let startTime = motionClock.startTime()
        previewTask = Task { @MainActor [weak self] in
            do {
                let remaining = max(0, startTime + TaskGlowMotionClock.cycleDuration - CACurrentMediaTime())
                try await Task.sleep(for: .seconds(remaining))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            previewTask = nil
            isPreviewVisible = false
            refreshPresentation()
        }
        updatePanels()
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        isPreviewVisible = false
    }

    private func consume(_ update: CodexActivityPresentationUpdate) {
        presentation.update(
            snapshot: update.snapshot,
            terminalEvents: update.terminalEvents,
            isEnabled: isEnabled,
            acceptsBriefEvents: !isSystemSleeping && !isDisplaySleeping && isSessionActive,
            now: Date()
        )
        refreshPresentation()
    }

    private func refreshPresentation() {
        presentation.refresh(now: Date())
        let expiration = presentation.terminal?.expiresAt
        updatePanels()
        guard expiration != scheduledExpiration else { return }
        expirationTask?.cancel()
        expirationTask = nil
        scheduledExpiration = expiration
        guard let expiration else { return }
        let delay = expiration.timeIntervalSinceNow
        expirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, delay)))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            scheduledExpiration = nil
            expirationTask = nil
            refreshPresentation()
        }
    }

    private func handleWorkspaceNotification(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.willSleepNotification: isSystemSleeping = true
        case NSWorkspace.didWakeNotification: isSystemSleeping = false
        case NSWorkspace.screensDidSleepNotification: isDisplaySleeping = true
        case NSWorkspace.screensDidWakeNotification: isDisplaySleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: isSessionActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: isSessionActive = true
        default: break
        }
        // 唤醒时按墙上时间重算, 不恢复已经过期的终态光带
        refreshPresentation()
    }

    private func updatePanels() {
        guard !isSystemSleeping, !isDisplaySleeping, isSessionActive else {
            cancelPreview()
            removePanels()
            return
        }
        let state: TaskGlowState = isPreviewVisible ? .running : presentation.state
        motionClock.setRunning(state == .running)
        if state == .hidden {
            guard !panels.isEmpty else {
                cancelPreview()
                return
            }
            guard hidePanelsTask == nil else { return }
            for panel in panels {
                panel.indicatorView.update(state: .hidden)
            }
            hidePanelsTask = Task { @MainActor [weak self, closingPanels = panels] in
                for panel in closingPanels {
                    guard await panel.indicatorView.waitForDismissal() else { return }
                }
                guard let self, !Task.isCancelled, !isPreviewVisible, presentation.state == .hidden else { return }
                cancelPreview()
                removePanels()
            }
            return
        }
        hidePanelsTask?.cancel()
        hidePanelsTask = nil
        if panels.isEmpty {
            panels = NSScreen.screens.map { TaskGlowPanel(screen: $0, motionClock: motionClock) }
        }
        for panel in panels {
            panel.indicatorView.update(
                state: state,
                terminalPresentation: isPreviewVisible ? nil : presentation.terminal,
                repeatsMotion: !isPreviewVisible
            )
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    private func removePanels(preservingMotion: Bool = false) {
        if !preservingMotion {
            motionClock.setRunning(false)
        }
        hidePanelsTask?.cancel()
        hidePanelsTask = nil
        for panel in panels {
            panel.indicatorView.stopAnimating()
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }
}

private extension CodexActivityTerminalEvent {
    var glowState: TaskGlowState {
        switch self {
        case .completed: .completed
        case .terminated: .terminated
        }
    }
}

/// 短提示只消费开启后新增的结束记录, 到期后按最新快照恢复等待或运行状态
private struct TaskGlowPresentationState {
    private var snapshot = CodexActivitySnapshot.empty
    private var enabledAt: Date?
    private var briefEvent: CodexActivityTerminalEvent?
    private var briefExpiration: Date?
    private(set) var state = TaskGlowState.hidden
    private(set) var terminal: TaskGlowTerminalPresentation?

    mutating func update(
        snapshot: CodexActivitySnapshot,
        terminalEvents: [CodexActivityTerminalEvent],
        isEnabled: Bool,
        acceptsBriefEvents: Bool,
        now: Date
    ) {
        let latestEvent = terminalEvents.max { lhs, rhs in
            if lhs.endedAt != rhs.endedAt {
                return lhs.endedAt < rhs.endedAt
            }
            if lhs.glowState != rhs.glowState {
                return rhs.glowState == .terminated
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if isEnabled, let enabledAt, acceptsBriefEvents,
           snapshot.hasActiveTasks,
           let latestEvent, latestEvent.endedAt >= enabledAt {
            briefEvent = latestEvent
            briefExpiration = now.addingTimeInterval(3)
        }
        if !isEnabled || !acceptsBriefEvents || !snapshot.hasActiveTasks {
            briefEvent = nil
            briefExpiration = nil
        }
        if !isEnabled {
            enabledAt = nil
        } else if enabledAt == nil {
            enabledAt = now
        }
        self.snapshot = snapshot
        refresh(now: now)
    }

    mutating func refresh(now: Date) {
        guard enabledAt != nil else {
            state = .hidden
            terminal = nil
            return
        }
        if let briefExpiration, now >= briefExpiration {
            briefEvent = nil
            self.briefExpiration = nil
        }
        if snapshot.hasActiveTasks, let briefEvent, let briefExpiration {
            show(briefEvent, until: briefExpiration, fadeDuration: 0.5, now: now)
            return
        }
        if snapshot.waitingCount > 0 {
            state = .waiting
        } else if snapshot.runningCount > 0 {
            state = .running
        } else if let event = snapshot.latestTerminalEvent,
                  let expiration = snapshot.statusItemActivityExpiration, now < expiration {
            show(event, until: expiration, fadeDuration: 1, now: now)
            return
        } else {
            state = .hidden
        }
        terminal = nil
    }

    private mutating func show(_ event: CodexActivityTerminalEvent, until expiration: Date, fadeDuration: TimeInterval, now: Date) {
        if state != event.glowState || terminal?.eventID != event.id || terminal?.expiresAt != expiration
            || terminal?.fadeDuration != fadeDuration {
            terminal = TaskGlowTerminalPresentation(
                eventID: event.id, startedAt: now, expiresAt: expiration, fadeDuration: fadeDuration
            )
        }
        state = event.glowState
    }
}

private enum TaskGlowState {
    case hidden
    case running
    case waiting
    case completed
    case terminated

    var color: NSColor {
        switch self {
        case .hidden: .clear
        case .running: .systemCyan
        case .waiting: .systemOrange
        case .completed: .systemGreen
        case .terminated: .systemRed
        }
    }
}

/// 终态共用墙上时间, 屏幕重建和唤醒后接续淡出, 不重新提亮
private struct TaskGlowTerminalPresentation: Equatable {
    static let entranceDuration: TimeInterval = 1.2
    let eventID: UUID
    let startedAt: Date
    let expiresAt: Date
    let fadeDuration: TimeInterval

    var duration: TimeInterval {
        max(0, expiresAt.timeIntervalSince(startedAt))
    }

    var entranceDuration: TimeInterval {
        min(Self.entranceDuration, duration / 4)
    }

    var holdDuration: TimeInterval {
        max(0, duration - fadeDuration)
    }
}

/// 所有屏幕共享同一运动周期, 新窗口直接加入当前进度
private final class TaskGlowMotionClock {
    static let travelDuration = 2.0
    static let offscreenDuration = 0.2
    static let centerRetractionDuration = 0.3
    static let cycleDuration = travelDuration + offscreenDuration * 2 + centerRetractionDuration
    private var isRunning = false
    private var startedAt: CFTimeInterval?

    func setRunning(_ running: Bool) {
        guard isRunning != running else { return }
        isRunning = running
        startedAt = nil
    }

    func startTime() -> CFTimeInterval {
        if let startedAt {
            return startedAt
        }
        let time = CACurrentMediaTime()
        startedAt = time
        return time
    }
}

private final class TaskGlowPanel: NSPanel {
    let indicatorView: TaskGlowView

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(screen: NSScreen, motionClock: TaskGlowMotionClock) {
        let geometry = TaskGlowGeometry(screenFrame: screen.frame)
        indicatorView = TaskGlowView(geometry: geometry, scale: screen.backingScaleFactor, motionClock: motionClock)
        super.init(contentRect: geometry.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isFloatingPanel = true
        // iTerm2 等 App 的顶部窗口使用 statusBar + 1, 光带必须在其上方才能露出菜单栏顶边
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        // 非激活面板跨 Space 和全屏显示, 不加入窗口循环或抢走当前 App 的焦点
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        animationBehavior = .none
        contentView = indicatorView
    }
}

/// 移动路径贯穿屏幕, 中心部分由屏幕刘海自然遮挡
private struct TaskGlowGeometry {
    let frame: NSRect
    let path: CGPath

    init(screenFrame: NSRect) {
        let height: CGFloat = 12
        frame = NSRect(x: screenFrame.minX, y: screenFrame.maxY - height, width: screenFrame.width, height: height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height - 1.5))
        path.addLine(to: CGPoint(x: screenFrame.width, y: height - 1.5))
        self.path = path
    }
}

private final class TaskGlowView: NSView {
    private let trackLayer = CAShapeLayer()
    private let lightLayer = CALayer()
    private var lightSegments: [CAShapeLayer] = []
    static let visibilityDuration = 0.24
    private static let edgeTraversalDuration = 0.7
    private static let segmentsPerSide = 32
    private static let stationaryColorAlpha: CGFloat = 0.9
    private let convergencePoint = 0.5
    private let motionClock: TaskGlowMotionClock
    private var presentationState: TaskGlowState?
    private var terminalPresentation: TaskGlowTerminalPresentation?
    private var contentState: TaskGlowState?
    private var transitionTask: Task<Void, Never>?
    private var repeatsMotion = true

    init(
        geometry: TaskGlowGeometry,
        scale: CGFloat,
        motionClock: TaskGlowMotionClock
    ) {
        self.motionClock = motionClock
        super.init(frame: NSRect(origin: .zero, size: geometry.frame.size))
        wantsLayer = true
        layer?.opacity = 0
        trackLayer.frame = bounds
        trackLayer.path = geometry.path
        trackLayer.fillColor = nil
        trackLayer.lineWidth = 3
        trackLayer.contentsScale = scale
        trackLayer.shadowRadius = 4
        trackLayer.shadowOffset = .zero
        lightLayer.frame = bounds
        lightLayer.shadowOpacity = 0.8
        lightLayer.shadowRadius = 4
        lightLayer.shadowOffset = .zero
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(lightLayer)
        // 嵌套描边让渐变沿弧长移动, 重叠区域避免相邻短线的抗锯齿接缝
        for _ in 0 ..< Self.segmentsPerSide * 2 {
            let segment = CAShapeLayer()
            segment.frame = bounds
            segment.path = geometry.path
            segment.fillColor = nil
            segment.lineWidth = 3
            segment.contentsScale = scale
            lightLayer.addSublayer(segment)
            lightSegments.append(segment)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: TaskGlowState, terminalPresentation: TaskGlowTerminalPresentation? = nil, repeatsMotion: Bool = true) {
        guard presentationState != state || self.terminalPresentation != terminalPresentation || self.repeatsMotion != repeatsMotion else { return }
        let continuesRunning = presentationState == .running && state == .running
        let continuesTerminal = presentationState == state && self.terminalPresentation != nil && terminalPresentation != nil
        // 同色提示延长时保留尚未完成的展开, 收尾会读取最新的淡出期限
        if continuesTerminal, transitionTask != nil {
            self.terminalPresentation = terminalPresentation
            return
        }
        let terminalOpacity = continuesTerminal ? (trackLayer.presentation() ?? trackLayer).opacity : nil
        let hasArtwork = contentState != nil && (layer?.presentation()?.opacity ?? layer?.opacity ?? 0) > 0.001
        presentationState = state
        self.terminalPresentation = terminalPresentation
        self.repeatsMotion = repeatsMotion
        transitionTask?.cancel()
        transitionTask = nil
        freezeArtwork()
        if state != .hidden {
            contentState = state
            animateVisibility(to: 1)
        }

        if continuesRunning {
            showStable(.running)
            return
        }

        if let terminalOpacity {
            showStable(state, initialTerminalOpacity: terminalOpacity)
            return
        }

        if let terminalPresentation,
           Date().timeIntervalSince(terminalPresentation.startedAt) >= terminalPresentation.entranceDuration {
            showStable(state)
            return
        }

        transitionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                if hasArtwork {
                    let duration = animateExtent(expanded: false)
                    try await Task.sleep(for: .seconds(duration))
                    guard !Task.isCancelled else { return }
                }
                if state == .hidden {
                    contentState = nil
                    animateVisibility(to: 0)
                    try await Task.sleep(for: .seconds(Self.visibilityDuration))
                    try Task.checkCancellation()
                } else {
                    if hasArtwork {
                        try await Task.sleep(for: .seconds(0.06))
                        guard !Task.isCancelled else { return }
                    }
                    if state == .running {
                        showStable(.running)
                        fadeInMovingLight()
                    } else {
                        setCollapsedColor(state.color)
                        let duration = animateExtent(expanded: true)
                        try await Task.sleep(for: .seconds(duration))
                        guard !Task.isCancelled else { return }
                        showStable(state)
                    }
                }
                transitionTask = nil
            } catch {
                return
            }
        }
    }

    /// 面板等待实际收回和淡出结束, 不用独立计时器提前移除仍可见的光带
    func waitForDismissal() async -> Bool {
        await transitionTask?.value
        return !Task.isCancelled && presentationState == .hidden && transitionTask == nil
    }

    func stopAnimating() {
        transitionTask?.cancel()
        transitionTask = nil
        stopArtworkAnimations()
        layer?.removeAllAnimations()
    }

    private struct SegmentAppearance {
        let start: CGFloat
        let end: CGFloat
        let color: CGColor?
    }

    /// 先冻结合成器当前帧, 再移除动画, 防止中途改目标时跳到上一段的终点
    private func freezeArtwork() {
        let usesTrack = !trackLayer.isHidden
        let track = trackLayer.presentation() ?? trackLayer
        let light = lightLayer.presentation() ?? lightLayer
        let opacity = usesTrack ? track.opacity : light.opacity
        let appearances = lightSegments.enumerated().map { index, segment -> SegmentAppearance in
            if usesTrack {
                return SegmentAppearance(
                    start: index < Self.segmentsPerSide ? 0 : convergencePoint,
                    end: index < Self.segmentsPerSide ? convergencePoint : 1,
                    color: distributedColor(track.strokeColor)
                )
            }
            let current = segment.presentation() ?? segment
            return SegmentAppearance(start: current.strokeStart, end: current.strokeEnd, color: current.strokeColor)
        }
        let shadowColor = usesTrack ? track.shadowColor : light.shadowColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopArtworkAnimations()
        trackLayer.isHidden = true
        lightLayer.isHidden = false
        lightLayer.opacity = opacity
        lightLayer.shadowColor = shadowColor
        for (segment, appearance) in zip(lightSegments, appearances) {
            segment.strokeStart = appearance.start
            segment.strokeEnd = appearance.end
            segment.strokeColor = appearance.color
        }
        CATransaction.commit()
    }

    private func showStable(_ state: TaskGlowState, initialTerminalOpacity: Float? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopArtworkAnimations()
        trackLayer.strokeStart = 0
        trackLayer.strokeEnd = 1
        trackLayer.strokeColor = state.color.withAlphaComponent(Self.stationaryColorAlpha).cgColor
        trackLayer.shadowColor = state.color.cgColor
        trackLayer.shadowOpacity = 0.8
        trackLayer.opacity = 1
        trackLayer.isHidden = state == .running
        lightLayer.isHidden = state != .running
        lightLayer.opacity = 1
        lightLayer.shadowColor = state.color.cgColor
        if state == .running {
            configureMovingLight()
        } else if state == .waiting {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [1, 0, 0, 1]
            animation.keyTimes = [0, 0.45, 0.55, 1]
            animation.duration = 1.5
            animation.repeatCount = .infinity
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
            trackLayer.add(animation, forKey: "breathe")
        } else if let terminalPresentation {
            animateTerminalFade(terminalPresentation, initialOpacity: initialTerminalOpacity)
        }
        CATransaction.commit()
    }

    private func animateTerminalFade(_ presentation: TaskGlowTerminalPresentation, initialOpacity: Float?) {
        trackLayer.opacity = 0
        let elapsed = max(0, Date().timeIntervalSince(presentation.startedAt))
        guard presentation.duration > elapsed else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        if presentation.holdDuration > 0 {
            var values: [Float] = [initialOpacity ?? 1]
            var times: [NSNumber] = [0]
            var timingFunctions: [CAMediaTimingFunction] = []
            if let initialOpacity, initialOpacity < 1 {
                let recovery = min(Self.visibilityDuration, presentation.holdDuration / 2)
                values.append(1)
                times.append(NSNumber(value: recovery / presentation.duration))
                timingFunctions.append(CAMediaTimingFunction(name: .easeInEaseOut))
            }
            animation.values = values + [1, 0]
            animation.keyTimes = times + [NSNumber(value: presentation.holdDuration / presentation.duration), 1]
            animation.timingFunctions = timingFunctions + [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeInEaseOut)
            ]
        } else {
            animation.values = [initialOpacity ?? 1, 0]
            animation.keyTimes = [0, 1]
            animation.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut)]
        }
        animation.duration = presentation.duration
        animation.beginTime = trackLayer.convertTime(CACurrentMediaTime(), from: nil) - elapsed
        trackLayer.add(animation, forKey: "terminalFade")
    }

    private func configureMovingLight() {
        let span = min(0.336, max(0.096, 300 / bounds.width))
        let startTime = motionClock.startTime()
        var previousIntensity = 0.0
        for (index, segment) in lightSegments.enumerated() {
            let depth = index % Self.segmentsPerSide
            if depth == 0 {
                previousIntensity = 0
            }
            let position = (Double(depth) + 0.5) / Double(Self.segmentsPerSide)
            let intensity = pow(sin(position * .pi / 2), 2)
            let color = TaskGlowState.running.color
            let tint = color.blended(withFraction: pow(intensity, 8) * 0.8, of: .white) ?? color
            segment.strokeColor = tint.withAlphaComponent((intensity - previousIntensity) / (1 - previousIntensity)).cgColor
            previousIntensity = intensity
            let tailLength = span * (1 - Double(depth) / Double(Self.segmentsPerSide))
            let isLeft = index < Self.segmentsPerSide
            segment.strokeStart = convergencePoint
            segment.strokeEnd = convergencePoint
            animateEmission(segment, tailLength: tailLength, span: span, isLeft: isLeft, startTime: startTime)
        }
    }

    private func animateExtent(expanded: Bool) -> TimeInterval {
        let targets = lightSegments.indices.map { index in
            (
                start: expanded && index < Self.segmentsPerSide ? 0.0 : convergencePoint,
                end: expanded && index >= Self.segmentsPerSide ? 1.0 : convergencePoint
            )
        }
        let distance = zip(lightSegments, targets).map { segment, target in
            max(abs(segment.strokeStart - target.start), abs(segment.strokeEnd - target.end))
        }.max() ?? 0
        let duration = max(0.001, Double(distance) * Self.edgeTraversalDuration)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (segment, target) in zip(lightSegments, targets) {
            animateValue(segment, keyPath: "strokeStart", from: segment.strokeStart, to: target.start, duration: duration)
            animateValue(segment, keyPath: "strokeEnd", from: segment.strokeEnd, to: target.end, duration: duration)
            segment.strokeStart = target.start
            segment.strokeEnd = target.end
        }
        CATransaction.commit()
        return duration
    }

    private func setCollapsedColor(_ color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stopArtworkAnimations()
        lightLayer.opacity = 1
        lightLayer.shadowColor = color.cgColor
        for segment in lightSegments {
            segment.strokeStart = convergencePoint
            segment.strokeEnd = convergencePoint
            segment.strokeColor = distributedColor(color.withAlphaComponent(Self.stationaryColorAlpha).cgColor)
        }
        CATransaction.commit()
    }

    private func distributedColor(_ color: CGColor?) -> CGColor? {
        guard let color, let base = NSColor(cgColor: color) else { return color }
        let alpha = 1 - pow(1 - base.alphaComponent, 1 / Double(Self.segmentsPerSide))
        return base.withAlphaComponent(alpha).cgColor
    }

    private func animateVisibility(to opacity: Float) {
        guard let layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "visibility")
        layer.opacity = opacity
        animateValue(layer, keyPath: "opacity", from: current, to: opacity, duration: Self.visibilityDuration, key: "visibility")
        CATransaction.commit()
    }

    private func fadeInMovingLight() {
        animateValue(lightLayer, keyPath: "opacity", from: Float(0), to: Float(1), duration: 0.18)
    }

    private func animateValue(_ layer: CALayer, keyPath: String, from: Any?, to: Any?, duration: TimeInterval, key: String? = nil) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: key ?? keyPath)
    }

    private func stopArtworkAnimations() {
        trackLayer.removeAllAnimations()
        lightLayer.removeAllAnimations()
        for segment in lightSegments {
            segment.removeAllAnimations()
        }
    }

    /// 各屏幕共享出发和掉头时刻, 回程拖尾完全收进中心后才开始下一轮
    private func animateEmission(_ segment: CAShapeLayer, tailLength: Double, span: Double, isLeft: Bool, startTime: CFTimeInterval) {
        let halfCrossing = TaskGlowMotionClock.travelDuration / 2
        let offscreen = TaskGlowMotionClock.offscreenDuration
        let outwardDuration = halfCrossing + offscreen
        let inwardDuration = halfCrossing + offscreen + TaskGlowMotionClock.centerRetractionDuration
        let outward = emissionAnimation(
            waypoints: [(0, convergencePoint), (halfCrossing, 1), (outwardDuration, 1 + span)],
            tailLength: tailLength, isLeft: isLeft
        )
        let inward = emissionAnimation(
            waypoints: [
                (0, 1 + span), (offscreen, 1),
                (offscreen + halfCrossing, convergencePoint), (inwardDuration, convergencePoint - span)
            ],
            tailLength: tailLength, isLeft: isLeft
        )
        inward.beginTime = outwardDuration
        // 每个单程独立缓入缓出, 保证两端掉头都平滑
        let travel = CAAnimationGroup()
        travel.animations = [outward, inward]
        travel.duration = TaskGlowMotionClock.cycleDuration
        travel.beginTime = segment.convertTime(startTime, from: nil)
        travel.repeatCount = repeatsMotion ? .infinity : 0
        segment.add(travel, forKey: "emission")
    }

    /// 在描边进入和离开屏幕的拐点插入关键帧, 屏幕外掉头时同时翻转拖尾方向
    private func emissionAnimation(
        waypoints: [(time: Double, head: Double)],
        tailLength: Double,
        isLeft: Bool
    ) -> CAAnimationGroup {
        let duration = waypoints.last!.time
        var times: [Double] = []
        var starts: [Double] = []
        var ends: [Double] = []
        for (from, to) in zip(waypoints, waypoints.dropFirst()) {
            let distance = to.head - from.head
            let tailOffset = distance > 0 ? -tailLength : tailLength
            let crossings = [convergencePoint, 1].flatMap { boundary in
                [0, tailOffset].map { (boundary - from.head - $0) / distance }
            }
            let progress = Array(Set([0.0, 1.0] + crossings.filter { $0 > 0 && $0 < 1 })).sorted()
            for fraction in progress {
                let time = from.time + (to.time - from.time) * fraction
                if times.last == time {
                    continue
                }
                let head = from.head + distance * fraction
                let tail = head + tailOffset
                let start = min(1, max(convergencePoint, min(head, tail)))
                let end = min(1, max(convergencePoint, max(head, tail)))
                times.append(time)
                starts.append(isLeft ? 1 - end : start)
                ends.append(isLeft ? 1 - start : end)
            }
        }
        let startAnimation = CAKeyframeAnimation(keyPath: "strokeStart")
        startAnimation.keyTimes = times.map { NSNumber(value: $0 / duration) }
        startAnimation.values = starts
        let endAnimation = CAKeyframeAnimation(keyPath: "strokeEnd")
        endAnimation.keyTimes = startAnimation.keyTimes
        endAnimation.values = ends
        let animation = CAAnimationGroup()
        animation.animations = [startAnimation, endAnimation]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }
}
