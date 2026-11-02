import SwiftUI
import Testing

struct LogPaginationTriggerTests {
    @Test func fastScrollLoadsOnceAndLayoutChangesCannotChainAnotherPage() {
        let bottom = geometry(offset: 5400, contentHeight: 6000)
        let phases: [ScrollPhase] = [.idle, .interacting, .decelerating, .idle, .idle, .animating, .idle]
        let requests = zip(phases, phases.dropFirst()).filter {
            LogView.shouldLoadMore(from: $0.0, to: $0.1, geometry: bottom)
        }
        #expect(requests.count == 1)
        #expect(!LogView.shouldLoadMore(from: .idle, to: .idle, geometry: geometry(offset: 5400, contentHeight: 9000)))
        #expect(LogView.shouldLoadMore(from: .interacting, to: .idle, geometry: bottom))
    }

    @Test func onlyReachingTheBottomIncludingItsInsetLoadsMore() {
        #expect(!LogView.shouldLoadMore(from: .interacting, to: .idle, geometry: geometry(offset: 200, contentHeight: 6000)))
        #expect(!LogView.shouldLoadMore(from: .decelerating, to: .idle, geometry: geometry(offset: 5400, contentHeight: 6000, bottomInset: 20)))
        #expect(LogView.shouldLoadMore(from: .decelerating, to: .idle, geometry: geometry(offset: 5420, contentHeight: 6000, bottomInset: 20)))
        #expect(!LogView.shouldLoadMore(from: .tracking, to: .idle, geometry: geometry(offset: 5400, contentHeight: 6000)))
        #expect(LogView.shouldLoadMore(from: .interacting, to: .idle, geometry: geometry(offset: 0, contentHeight: 400)))
    }

    private func geometry(offset: CGFloat, contentHeight: CGFloat, bottomInset: CGFloat = 0) -> ScrollGeometry {
        ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: offset),
            contentSize: CGSize(width: 900, height: contentHeight),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: bottomInset, trailing: 0),
            containerSize: CGSize(width: 900, height: 600)
        )
    }
}
