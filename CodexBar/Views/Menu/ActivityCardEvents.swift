import AppKit
import SwiftUI

struct ActivityCardEvents: NSViewRepresentable {
    let isEnabled: Bool
    let onSwipe: (SwipeEvent) -> Void
    let onTogglePin: () -> Void

    enum SwipeEvent: Equatable {
        case began
        case changed(CGFloat)
        case ended(velocity: CGFloat)
        case cancelled
        case step(Int)
    }

    func makeNSView(context _: Context) -> EventRegion {
        EventRegion()
    }

    func updateNSView(_ view: EventRegion, context _: Context) {
        view.onSwipe = onSwipe
        view.onTogglePin = onTogglePin
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: EventRegion, coordinator _: ()) {
        view.removeMonitor()
    }

    final class EventRegion: NSView {
        var isEnabled = false {
            didSet {
                if !isEnabled {
                    resetInteraction()
                }
            }
        }

        var onSwipe: ((SwipeEvent) -> Void)?
        var onTogglePin: (() -> Void)?
        private var ownsGesture = false
        private var rightMouseBeganInside = false
        private var monitor: Any?
        private var lastTimestamp: TimeInterval?
        private var velocity: CGFloat = 0
        private var unphasedEndTask: Task<Void, Never>?
        private var cancellationTask: Task<Void, Never>?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown, .rightMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            resetInteraction()
        }

        private func resetInteraction() {
            rightMouseBeganInside = false
            finish(.cancelled, deferringNotification: true)
        }

        private func finish(_ event: SwipeEvent, deferringNotification: Bool = false) {
            unphasedEndTask?.cancel()
            unphasedEndTask = nil
            lastTimestamp = nil
            velocity = 0
            // 隐藏宿主的清理不能取消另一个宿主正在进行的手势
            guard ownsGesture else { return }
            ownsGesture = false
            if deferringNotification {
                let callback = onSwipe
                // updateNSView 和 dismantleNSView 仍在 SwiftUI 更新内, 退出后再通知视图清理状态
                cancellationTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    self?.cancellationTask = nil
                    callback?(event)
                }
            } else {
                onSwipe?(event)
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, let window, window.isVisible, event.window === window else {
                resetInteraction()
                return event
            }
            let point = convert(event.locationInWindow, from: nil)
            let inside = !isHiddenOrHasHiddenAncestor && visibleRect.contains(point)
            if event.type == .rightMouseDown {
                rightMouseBeganInside = inside
                return inside ? nil : event
            }
            if event.type == .rightMouseUp {
                let beganInside = rightMouseBeganInside
                rightMouseBeganInside = false
                guard beganInside, inside else { return event }
                onTogglePin?()
                return nil
            }

            let shiftsVertical = event.modifierFlags.contains(.shift) && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            let delta = shiftsVertical ? event.scrollingDeltaY : event.scrollingDeltaX
            // 一旦取得横向手势, 后续斜向位移仍沿横轴处理, 直到结束或取消
            guard ownsGesture || shiftsVertical || abs(delta) > abs(event.scrollingDeltaY) else { return event }
            let consumed = scroll(
                delta: delta, timestamp: event.timestamp, phase: event.phase,
                momentum: event.momentumPhase, precise: event.hasPreciseScrollingDeltas, inside: inside
            )
            return consumed ? nil : event
        }

        @discardableResult
        func scroll(delta: CGFloat, timestamp: TimeInterval, phase: NSEvent.Phase, momentum: NSEvent.Phase = [], precise: Bool = true, inside: Bool = true) -> Bool {
            guard isEnabled else { return false }
            if phase.contains(.cancelled) || !inside {
                finish(.cancelled)
                return inside
            }
            if phase.contains(.ended) {
                if ownsGesture, delta.isFinite, delta != 0, timestamp.isFinite {
                    move(by: delta, timestamp: timestamp)
                }
                let recentVelocity = lastTimestamp.map { timestamp - $0 < 0.1 ? velocity : 0 } ?? 0
                finish(.ended(velocity: recentVelocity))
                return inside
            }
            // 先结束手指拖动阶段, 惯性不能开启新手势, 也不能触发第二次翻页
            guard momentum.isEmpty, delta.isFinite, timestamp.isFinite, delta != 0 else { return inside }
            if !precise, phase.isEmpty {
                finish(.cancelled)
                if abs(delta) >= 0.5 {
                    onSwipe?(.step(delta < 0 ? 1 : -1))
                }
                return true
            }
            if !ownsGesture {
                cancellationTask?.cancel()
                cancellationTask = nil
                ownsGesture = true
                onSwipe?(.began)
            }
            move(by: delta, timestamp: timestamp)
            unphasedEndTask?.cancel()
            unphasedEndTask = nil
            if phase.isEmpty {
                scheduleUnphasedEnd()
            }
            return true
        }

        private func move(by delta: CGFloat, timestamp: TimeInterval) {
            if let previous = lastTimestamp, timestamp > previous {
                let interval = timestamp - previous
                velocity = interval <= 0.1 ? 0.65 * delta / max(1.0 / 240, interval) + 0.35 * velocity : 0
            }
            lastTimestamp = timestamp
            onSwipe?(.changed(delta))
        }

        private func scheduleUnphasedEnd() {
            // 精确滚轮若没有阶段事件, 用输入序列结束代替抬手, 不保留惯性速度
            unphasedEndTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(160))
                } catch { return }
                self?.finish(.ended(velocity: 0))
            }
        }
    }
}
