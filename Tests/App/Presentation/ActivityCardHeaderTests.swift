import AppKit
import SwiftUI
import Testing

@MainActor
struct ActivityCardHeaderTests {
    @Test func everyBadgeParticipatesInTheWrappingWidth() {
        let plain = singleLineThreshold(pin: false, positionText: "1/3", sun: false)
        let pinned = singleLineThreshold(pin: true, positionText: "1/3", sun: false)
        let numbered = singleLineThreshold(pin: true, positionText: "10/12", sun: false)
        let all = singleLineThreshold(pin: true, positionText: "10/12", sun: true)
        #expect(pinned > plain + 10)
        #expect(numbered > pinned + 8)
        #expect(all > numbered + 10)
        #expect(height(width: plain + 1, pin: true, positionText: "10/12", sun: true) > height(width: all + 1, pin: true, positionText: "10/12", sun: true))
    }

    private func singleLineThreshold(pin: Bool, positionText: String, sun: Bool) -> CGFloat {
        let singleLineHeight = height(width: 700, pin: pin, positionText: positionText, sun: sun)
        var lower: CGFloat = 120
        var upper: CGFloat = 700
        while upper - lower > 0.5 {
            let candidate = (lower + upper) / 2
            if height(width: candidate, pin: pin, positionText: positionText, sun: sun) > singleLineHeight + 2 {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return upper
    }

    private func height(width: CGFloat, pin: Bool, positionText: String, sun: Bool) -> CGFloat {
        let view = ActivityCardHeader(
            components: ["CodexBar", "GPT-5 • High • 10s"], projectName: "CodexBar",
            positionText: positionText, hasPin: pin, isPinned: pin, showsKeepAliveBadge: sun
        )
        .environment(\.contentAnimationsEnabled, false)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        return NSHostingView(rootView: view).fittingSize.height
    }
}
