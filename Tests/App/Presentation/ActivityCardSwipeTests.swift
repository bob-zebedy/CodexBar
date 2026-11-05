import AppKit
import SwiftUI
import Testing

@MainActor
struct ActivityCardSwipeTests {
    private let now = Date(timeIntervalSince1970: 1800000000)

    @Test func draggingFollowsSmallDeltasAndCanReverseBeforeCommitting() {
        let swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: -3, width: 400)
        #expect(swipe.offset(at: now) == -3)
        swipe.move(by: -150, width: 400)
        swipe.move(by: 130, width: 400)
        #expect(swipe.offset(at: now) == -23)
        #expect(swipe.settlement == nil)
        swipe.end(velocity: 0, width: 400, cancelled: false, now: now)
        #expect(swipe.settlement?.step == 0)
        #expect(swipe.offset(at: now.addingTimeInterval(1)) == 0)
    }

    @Test(arguments: [-1, 1])
    func releaseUsesDistanceAndVelocityButCancellationAlwaysReturns(direction: Int) {
        let delta = CGFloat(direction)
        var swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: delta * 120, width: 400)
        swipe.end(velocity: 0, width: 400, cancelled: false, now: now)
        #expect(swipe.settlement?.step == -direction)
        #expect(swipe.offset(at: now.addingTimeInterval(1)) == delta * 400)
        swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: delta * 20, width: 400)
        swipe.end(velocity: delta * 900, width: 400, cancelled: false, now: now)
        #expect(swipe.settlement?.step == -direction)
        _ = swipe.begin(width: 400, now: now.addingTimeInterval(1))
        swipe.move(by: delta * 300, width: 400)
        swipe.end(velocity: delta * 1200, width: 400, cancelled: true, now: now)
        #expect(swipe.settlement?.step == 0)
        #expect(swipe.offset(at: now.addingTimeInterval(1)) == 0)
    }

    @Test func reversingVelocityCanCancelButCannotChooseAnUnseenOppositePage() {
        let swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: -140, width: 400)
        swipe.end(velocity: 1800, width: 400, cancelled: false, now: now)
        #expect(swipe.settlement?.step == 0)
    }

    @Test func newGestureRebasesUnfinishedPageWithoutChangingItsVisiblePosition() {
        let swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: -120, width: 400)
        swipe.end(velocity: 0, width: 400, cancelled: false, now: now)
        let interruptedAt = now.addingTimeInterval(0.06)
        let nextPageBefore = swipe.offset(at: interruptedAt) + 400
        #expect(swipe.begin(width: 400, now: interruptedAt) == 1)
        #expect(abs(swipe.offset(at: interruptedAt) - nextPageBefore) < 0.001)
        swipe.move(by: -10, width: 400)
        #expect(abs(swipe.offset(at: interruptedAt) - (nextPageBefore - 10)) < 0.001)
        #expect(swipe.settlement == nil)
    }

    @Test(arguments: [-1, 1])
    func offscreenRebasingPreservesInterpolatedHeight(direction: Int) {
        let swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: CGFloat(direction) * 200, width: 400)
        let height = renderedHeight(swipe)
        swipe.end(velocity: 0, width: 400, cancelled: false, now: now)
        let step = swipe.begin(width: 400, now: now)
        let heights: [CGFloat] = step == 1 ? [100, 180, 60] : [180, 60, 100]
        #expect(abs(renderedHeight(swipe, pageHeights: heights) - height) < 0.5)
        swipe.move(by: CGFloat(direction) * 200, width: 400)
        #expect(abs(renderedHeight(swipe, pageHeights: heights) - heights[1]) < 0.5)
    }

    @Test(arguments: [CGFloat(320), 400])
    func mountedPagesFollowEveryDragWithoutReplacingTheRootView(width: CGFloat) {
        let swipe = ActivityCardSwipe()
        var currentPageX: CGFloat = 0
        let root = ActivityCardSwipePages(swipe: swipe, width: 400) { step in
            Color.clear.frame(height: [60.0, 100, 180][step + 1])
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                    if step == 0 {
                        currentPageX = $0
                    }
                }
        }
        .frame(width: width)
        let host = NSHostingView(rootView: root)
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.height == 100)
        _ = swipe.begin(width: width, now: now)
        for (delta, offset, height) in [(-0.1, -0.1, 108.0), (0.05, -0.05, 104), (0.55, 0.5, 80), (-1, -0.5, 140)] {
            swipe.move(by: delta * width, width: width)
            host.layoutSubtreeIfNeeded()
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            #expect(abs(host.frame.height - height) < 0.5)
            #expect(abs(currentPageX - offset * width) < 0.5)
        }
    }

    private func renderedHeight(_ swipe: ActivityCardSwipe, pageHeights: [CGFloat] = [60, 100, 180]) -> CGFloat {
        let root = ActivityCardSwipePages(swipe: swipe, width: 400) { step in
            Color.clear.frame(height: pageHeights[step + 1])
        }
        .frame(width: 400)
        return NSHostingView(rootView: root).fittingSize.height
    }
}
