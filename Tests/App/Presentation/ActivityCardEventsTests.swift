import AppKit
import SwiftUI
import Testing

@MainActor
struct ActivityCardEventsTests {
    @Test(arguments: [true, false])
    func shrinkingCardRejectsNewGesturesOutsideItsCurrentBounds(precise: Bool) {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 320))
        panel.clipsToBounds = true
        let region = ActivityCardEvents.EventRegion(frame: NSRect(x: 20, y: 20, width: 300, height: 180))
        panel.addSubview(region)
        region.isEnabled = true
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        let point = NSPoint(x: 150, y: 140)
        #expect(region.scroll(delta: -4, timestamp: 1, phase: precise ? .began : [], precise: precise, inside: region.containsInteractionPoint(point)))
        #expect(events == (precise ? [.began, .changed(-4)] : [.step(1)]))
        region.scroll(delta: 0, timestamp: 1.2, phase: .ended)
        events.removeAll()

        region.setFrameSize(NSSize(width: 300, height: 60))
        // 未启用自身裁剪的事件视图, 可见区域仍覆盖卡片外的面板区域
        #expect(region.visibleRect.contains(point))
        #expect(!region.containsInteractionPoint(point))
        #expect(!region.scroll(delta: 4, timestamp: 2, phase: precise ? .began : [], precise: precise, inside: region.containsInteractionPoint(point)))
        #expect(events.isEmpty)
        let inside = region.containsInteractionPoint(NSPoint(x: 150, y: 30))
        #expect(region.scroll(delta: 4, timestamp: 3, phase: precise ? .began : [], precise: precise, inside: inside))
        #expect(events == (precise ? [.began, .changed(4)] : [.step(-1)]))
        region.scroll(delta: 0, timestamp: 3.2, phase: .ended)
        #expect(region.window == nil)
    }

    @Test(arguments: [-1, 1])
    func shrinkingBelowStationaryPointerDoesNotCancelOwnedGesture(direction: Int) {
        let region = ActivityCardEvents.EventRegion()
        let swipe = ActivityCardSwipe()
        let width: CGFloat = 300
        var now = Date(timeIntervalSince1970: 1800000000)
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.isEnabled = true
        region.onSwipe = { event in
            events.append(event)
            switch event {
            case .began:
                _ = swipe.begin(width: width, now: now)
            case let .changed(delta):
                swipe.move(by: delta, width: width)
            case let .ended(velocity):
                swipe.end(velocity: velocity, width: width, cancelled: false, now: now)
            case .cancelled:
                swipe.end(velocity: 0, width: width, cancelled: true, now: now)
            case .step:
                Issue.record("Precise gesture unexpectedly switched to discrete navigation")
            }
        }
        let host = NSHostingView(rootView: ActivityCardSwipePages(swipe: swipe, width: width) { step in
            Color.clear.frame(height: step == 0 ? 180 : 60)
        }.frame(width: width))
        var movedOutside = false
        for index in 0 ..< 8 {
            host.layoutSubtreeIfNeeded()
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            region.setFrameSize(host.frame.size)
            // 鼠标停在高卡片底部, 高度变化时按顶部距离重新换算到事件视图
            let inside = region.containsInteractionPoint(NSPoint(x: 150, y: host.frame.height - 160))
            movedOutside = movedOutside || !inside
            now = now.addingTimeInterval(0.02)
            #expect(region.scroll(delta: CGFloat(direction) * 30, timestamp: now.timeIntervalSince1970, phase: index == 0 ? .began : .changed, inside: inside))
        }
        now = now.addingTimeInterval(0.2)
        #expect(region.scroll(delta: 0, timestamp: now.timeIntervalSince1970, phase: .ended, inside: false))
        #expect(movedOutside)
        #expect(!events.contains(.cancelled))
        #expect(events.filter { $0 == .began }.count == 1)
        #expect(swipe.settlement?.step == -direction)

        let count = events.count
        #expect(!region.scroll(delta: CGFloat(direction) * 30, timestamp: now.timeIntervalSince1970 + 1, phase: .began, inside: false))
        #expect(events.count == count)
        #expect(host.window == nil)
    }

    @Test func interactionRequiresCardBoundsAndVisibleAncestorArea() {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        panel.clipsToBounds = true
        let region = ActivityCardEvents.EventRegion(frame: NSRect(x: 20, y: 20, width: 300, height: 180))
        panel.addSubview(region)
        #expect(region.containsInteractionPoint(NSPoint(x: 150, y: 30)))
        for point in [NSPoint(x: -1, y: 30), NSPoint(x: 301, y: 30), NSPoint(x: 150, y: -1), NSPoint(x: 150, y: 140)] {
            #expect(!region.containsInteractionPoint(point))
        }
        panel.isHidden = true
        #expect(!region.containsInteractionPoint(NSPoint(x: 150, y: 30)))
        #expect(region.window == nil)
    }

    @Test func inactiveHostCleanupCannotEndAnotherHostsGesture() async throws {
        let active = ActivityCardEvents.EventRegion()
        let inactive = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        active.onSwipe = { events.append($0) }
        inactive.onSwipe = { events.append($0) }
        active.isEnabled = true
        active.scroll(delta: -2, timestamp: 1, phase: .began)
        inactive.removeMonitor()
        #expect(events == [.began, .changed(-2)])
        active.removeMonitor()
        active.removeMonitor()
        try await Task.sleep(for: .milliseconds(10))
        #expect(events == [.began, .changed(-2), .cancelled])
    }

    @Test func disablingRegionReleasesGestureAndAllowsTheNextOne() async throws {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -4, timestamp: 1, phase: .began)
        region.isEnabled = false
        try await Task.sleep(for: .milliseconds(10))
        region.isEnabled = true
        region.scroll(delta: 3, timestamp: 2, phase: .began)
        region.scroll(delta: 0, timestamp: 2.2, phase: .ended)
        #expect(events == [.began, .changed(-4), .cancelled, .began, .changed(3), .ended(velocity: 0)])
    }

    @Test func everyDeltaIncludingReversalIsDeliveredBeforeRelease() {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -2, timestamp: 1, phase: .began)
        region.scroll(delta: -80, timestamp: 1.02, phase: .changed)
        region.scroll(delta: 25, timestamp: 1.04, phase: .changed)
        #expect(events == [.began, .changed(-2), .changed(-80), .changed(25)])
        region.scroll(delta: 0, timestamp: 1.3, phase: .ended)
        #expect(events.last == .ended(velocity: 0))
        let count = events.count
        region.scroll(delta: -90, timestamp: 1.31, phase: [], momentum: .began)
        region.scroll(delta: -20, timestamp: 1.32, phase: [], momentum: .changed)
        #expect(events.count == count)
    }

    @Test func recentMotionSuppliesReleaseVelocityAndCancellationDoesNotCommit() {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -5, timestamp: 1, phase: .began)
        region.scroll(delta: -15, timestamp: 1.02, phase: .changed)
        region.scroll(delta: 0, timestamp: 1.03, phase: .ended)
        guard case let .ended(velocity) = events.last else {
            Issue.record("Missing release velocity")
            return
        }
        #expect(velocity < 0)
        region.scroll(delta: -100, timestamp: 2, phase: .began)
        #expect(region.scroll(delta: 0, timestamp: 2.01, phase: .cancelled, inside: false))
        #expect(events.last == .cancelled)
    }

    @Test func unphasedPreciseInputSettlesOnceAndCleanupCancelsItsTimer() async throws {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -10, timestamp: 1, phase: [])
        region.scroll(delta: 4, timestamp: 1.02, phase: [], inside: false)
        try await Task.sleep(for: .milliseconds(220))
        #expect(events == [.began, .changed(-10), .changed(4), .ended(velocity: 0)])
        region.scroll(delta: -10, timestamp: 2, phase: [])
        region.removeMonitor()
        try await Task.sleep(for: .milliseconds(10))
        let expected = events
        try await Task.sleep(for: .milliseconds(220))
        #expect(events == expected)
        #expect(events.last == .cancelled)
    }

    @Test func ordinaryWheelKeepsDiscreteNavigation() {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -1, timestamp: 1, phase: [], precise: false)
        region.scroll(delta: 1, timestamp: 2, phase: [], precise: false)
        #expect(events == [.step(1), .step(-1)])
    }

    @Test func releaseIncludesFinalDeltaAndClosesBeforeMomentum() {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -5, timestamp: 1, phase: .began)
        region.scroll(delta: -3, timestamp: 1.02, phase: .ended, momentum: .began)
        #expect(events.prefix(3) == [.began, .changed(-5), .changed(-3)])
        guard case .ended = events.last else {
            Issue.record("Finger phase did not end")
            return
        }
        region.scroll(delta: -40, timestamp: 1.04, phase: [], momentum: .changed)
        #expect(events.count == 4)
    }
}
