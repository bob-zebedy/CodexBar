import AppKit
import Combine
import QuartzCore

/// 只消费实时任务的展示更新, 不参与任务通知或防睡眠判定
@MainActor
final class TaskGlowController {
    private let settings: TaskGlowSettings
    private let activityMonitor: ActivityMonitor
    private var appearance: TaskGlowAppearance
    private var cancellables = Set<AnyCancellable>()
    private var panels: [TaskGlowPanel] = []
    private let motionClock = TaskGlowMotionClock()
    private var presentation = TaskGlowPresentationState()
    private var isEnabled = false
    private var expirationTask: Task<Void, Never>?
    private var scheduledExpiration: Date?
    private var hidePanelsTask: Task<Void, Never>?
    private var preview: TaskGlowPreviewPresentation?
    private var playback: TaskGlowPlayback?
    private var isSystemSleeping = false
    private var isDisplaySleeping = false
    private var isSessionActive = true

    init(
        settings: TaskGlowSettings,
        activityMonitor: ActivityMonitor
    ) {
        self.settings = settings
        self.activityMonitor = activityMonitor
        appearance = settings.appearance
        motionClock.setAnimationSpeed(appearance.animationSpeed)
    }

    deinit {
        expirationTask?.cancel()
        hidePanelsTask?.cancel()
    }

    func start() {
        guard cancellables.isEmpty else { return }
        settings.$isEnabled
            .sink { [weak self] enabled in
                guard let self else { return }
                if !enabled {
                    cancelPreview()
                }
                isEnabled = enabled
                consume(ActivityPresentationUpdate(snapshot: activityMonitor.snapshot, terminalEvents: []))
            }
            .store(in: &cancellables)

        settings.previewRequests
            .sink { [weak self] in self?.handlePreviewRequest($0) }
            .store(in: &cancellables)

        settings.$appearance
            .removeDuplicates()
            .sink { [weak self] appearance in
                guard let self else { return }
                self.appearance = appearance
                motionClock.setAnimationSpeed(appearance.animationSpeed)
                if preview != nil {
                    preview?.setAnimationSpeed(appearance.animationSpeed, now: Date())
                    playback = preview?.playback
                    if preview?.state == .running, let playback {
                        motionClock.restart(at: playback.mediaStart)
                    }
                }
                refreshPresentation()
            }
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

    private func handlePreviewRequest(_ request: TaskGlowPreviewRequest) {
        if request == .endColorPreview {
            if preview?.isColorPreview == true {
                finishPreview()
            }
            return
        }
        guard isEnabled,
              !isSystemSleeping, !isDisplaySleeping, isSessionActive else { return }
        let role: TaskGlowColorRole
        switch request {
        case .enabled:
            guard preview == nil, hidePanelsTask == nil else { return }
            role = .running
        case let .color(selectedRole): role = selectedRole
        case .endColorPreview: return
        }
        let now = Date()
        presentation.refresh(now: now, terminalDuration: appearance.terminalDuration)
        presentation.suspend(now: now)
        let playback = makePlayback(now: now)
        self.playback = playback
        preview = TaskGlowPreviewPresentation(
            role: role, isColorPreview: request != .enabled,
            playback: playback, speed: appearance.animationSpeed
        )
        motionClock.restart(at: playback.mediaStart)
        refreshPresentation()
    }

    private func makePlayback(now: Date) -> TaskGlowPlayback {
        let delay = panels.map(\.indicatorView.interruptionDelay).max() ?? 0
        return TaskGlowPlayback(startsAt: now.addingTimeInterval(delay), mediaStart: CACurrentMediaTime() + delay)
    }

    private func finishPreview() {
        guard preview != nil else { return }
        preview = nil
        let playback = makePlayback(now: Date())
        self.playback = playback
        presentation.resume(now: playback.startsAt)
        motionClock.restart(at: playback.mediaStart)
        refreshPresentation()
    }

    private func cancelPreview() {
        preview = nil
        playback = nil
        presentation.resume(now: Date())
    }

    private func consume(_ update: ActivityPresentationUpdate) {
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
        presentation.refresh(now: Date(), terminalDuration: appearance.terminalDuration)
        updatePanels()
        let expiration = preview?.expiresAt ?? (presentation.isSuspended ? nil : presentation.terminal?.expiresAt)
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
            // 相同期限可能跨越预览和真实状态, 到期时按当前展示选择动作
            if preview != nil {
                finishPreview()
            } else {
                refreshPresentation()
            }
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
        if isSystemSleeping || isDisplaySleeping || !isSessionActive {
            cancelPreview()
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
        let state = preview?.state ?? presentation.state
        motionClock.setRunning(state == .running)
        if state == .hidden {
            guard !panels.isEmpty else {
                cancelPreview()
                return
            }
            guard hidePanelsTask == nil else { return }
            for panel in panels {
                panel.indicatorView.update(state: .hidden, appearance: appearance)
            }
            hidePanelsTask = Task { @MainActor [weak self, closingPanels = panels] in
                for panel in closingPanels {
                    guard await panel.indicatorView.waitForDismissal() else { return }
                }
                guard let self, !Task.isCancelled, preview == nil, presentation.state == .hidden else { return }
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
                appearance: appearance,
                terminalPresentation: preview == nil ? presentation.terminal : preview?.terminal,
                repeatsMotion: preview == nil,
                playback: playback
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
