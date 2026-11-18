import AppKit
import SwiftUI
import Testing

@MainActor
struct ResetCreditsPanelLayoutTests {
    @Test(arguments: [0, 1, 2])
    func reversingAnInsertionContinuesFromTheVisibleRowHeights(at index: Int) {
        let now = TestFixtures.now
        let dates = [now, now.addingTimeInterval(86400), now.addingTimeInterval(172800)]
        var remaining = dates
        remaining.remove(at: index)
        let content = ResetCreditsPanelContent()
        content.update(remaining, animated: false, now: now)
        content.update(dates, animated: true, now: now)
        let reversal = now.addingTimeInterval(0.12)
        let progress = content.progress(at: reversal)
        let before = content.rows.map { $0.visibility(at: progress) }
        #expect(before[index] > 0 && before[index] < 1)
        #expect(before.filter { $0 == 1 }.count == remaining.count)

        content.update(remaining, animated: true, now: reversal)
        #expect(content.rows.map { $0.visibility(at: content.progress(at: reversal)) } == before)
        content.finish()
        #expect(content.rows.map(\.group?.date) == remaining)
        #expect(content.startedAt == nil)
    }

    @Test func visibleHeightTracksRowsInBothDirections() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MainPanelSettings(defaults: preferences.defaults)
        let dates = [TestFixtures.now, TestFixtures.now.addingTimeInterval(86400)]
        let content = ResetCreditsPanelContent()
        content.update(dates, animated: false)
        var heights: [CGFloat] = []
        let view = ResetCreditsPanelView(content: content, mainPanelSettings: settings) { heights.append($0.height) }
        let fullSize = view.panelSize(at: 1)
        let host = NSHostingView(rootView: view.drawer(at: 1))
        host.frame = CGRect(origin: .zero, size: fullSize)
        host.layoutSubtreeIfNeeded()
        let collapsedHeight = ResetCreditsPanelView.initialPanelSize.height

        for update in [[dates[1]], dates] {
            content.update(update, animated: true, now: TestFixtures.now)
            heights.removeAll()
            for tick in 1 ... 6 {
                let now = TestFixtures.now.addingTimeInterval(Double(tick) * 0.06)
                host.rootView = view.drawer(at: content.progress(at: now))
                host.layoutSubtreeIfNeeded()
                if let height = heights.last {
                    host.setFrameSize(CGSize(width: fullSize.width, height: height))
                }
            }
            #expect(heights.contains { $0 > collapsedHeight && $0 < fullSize.height })
            #expect(heights == (update.count == 1 ? heights.sorted(by: >) : heights.sorted()))
            #expect(heights.last == (update.count == 1 ? collapsedHeight : fullSize.height))
            content.finish()
        }
    }
}
