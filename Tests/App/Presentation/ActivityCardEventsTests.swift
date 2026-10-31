import AppKit
import Testing

@MainActor
struct ActivityCardEventsTests {
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
        region.scroll(delta: 0, timestamp: 2.01, phase: .cancelled)
        #expect(events.last == .cancelled)
    }

    @Test func unphasedPreciseInputSettlesOnceAndCleanupCancelsItsTimer() async throws {
        let region = ActivityCardEvents.EventRegion()
        var events: [ActivityCardEvents.SwipeEvent] = []
        region.onSwipe = { events.append($0) }
        region.isEnabled = true
        region.scroll(delta: -10, timestamp: 1, phase: [])
        region.scroll(delta: 4, timestamp: 1.02, phase: [])
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
