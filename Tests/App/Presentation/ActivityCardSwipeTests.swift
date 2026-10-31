import AppKit
import SwiftUI
import Testing

@MainActor
struct ActivityCardSwipeTests {
    private let now = Date(timeIntervalSince1970: 1800000000)

    @Test func draggingFollowsSmallDeltasAndCanReverseBeforeCommitting() {
        var swipe = ActivityCardSwipe()
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
    }

    @Test func reversingVelocityCanCancelButCannotChooseAnUnseenOppositePage() {
        var swipe = ActivityCardSwipe()
        _ = swipe.begin(width: 400, now: now)
        swipe.move(by: -140, width: 400)
        swipe.end(velocity: 1800, width: 400, cancelled: false, now: now)
        #expect(swipe.settlement?.step == 0)
    }

    @Test func newGestureRebasesUnfinishedPageWithoutChangingItsVisiblePosition() {
        var swipe = ActivityCardSwipe()
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

    @Test func offscreenHeightTracksBothDirectionsAndReturnsWithThePages() {
        var swipe = ActivityCardSwipe()
        #expect(renderedHeight(swipe) == 100)
        _ = swipe.begin(width: 400, now: now)
        // 使用整点高度, 避免离屏宿主的 backing scale 影响断言
        swipe.move(by: -40, width: 400)
        #expect(renderedHeight(swipe) == 108)
        swipe.move(by: 20, width: 400)
        #expect(renderedHeight(swipe) == 104)
        swipe.move(by: 220, width: 400)
        #expect(abs(renderedHeight(swipe) - 80) < 0.5)
        swipe.end(velocity: 0, width: 400, cancelled: true, now: now)
        var returned = ActivityCardSwipe()
        _ = returned.begin(width: 400, now: now)
        returned.move(by: swipe.offset(at: now.addingTimeInterval(1)), width: 400)
        #expect(abs(renderedHeight(returned) - 100) < 0.5)
        returned.move(by: -160, width: 320)
        #expect(abs(renderedHeight(returned, width: 320) - 140) < 0.5)
    }

    @Test(arguments: [-1, 1])
    func offscreenRebasingPreservesInterpolatedHeight(direction: Int) {
        var swipe = ActivityCardSwipe()
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

    private func renderedHeight(_ swipe: ActivityCardSwipe, pageHeights: [CGFloat] = [60, 100, 180], width: CGFloat = 400) -> CGFloat {
        let root = ActivityCardSwipePages(swipe: swipe, width: 400) { step in
            Color.clear.frame(height: pageHeights[step + 1])
        }
        .frame(width: width)
        return NSHostingView(rootView: root).fittingSize.height
    }
}
