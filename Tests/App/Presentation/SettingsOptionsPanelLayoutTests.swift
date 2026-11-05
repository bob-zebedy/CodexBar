import AppKit
import Combine
import SwiftUI
import Testing

@MainActor
struct SettingsOptionsPanelLayoutTests {
    @Test(arguments: [(67.25, 68), (93.75, 94), (67.25, 94), (93.75, 67)] as [(CGFloat, CGFloat)])
    func resizingKeepsFirstRowAtTopWithRoundedOrPreviousHeight(height: CGFloat, hostHeight: CGFloat) {
        var reportedSize = CGSize.zero
        var contentTop: CGFloat = -1
        let view = Color.blue
            .frame(width: 300, height: 22)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).minY
            } action: { contentTop = $0 }
            .frame(height: height, alignment: .top)
            .settingsOptionsPanel(height: height)
            .environment(\.settingsOptionsPanelSizeObserver, SettingsOptionsPanelSizeObserver {
                reportedSize = $0
            })
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: hostHeight)
        host.layoutSubtreeIfNeeded()

        #expect(reportedSize == CGSize(width: 300, height: height.rounded(.up)))
        #expect(host.fittingSize.height == height.rounded(.up))
        #expect(contentTop == 0)
    }

    @Test func animatedExpansionAndCollapseKeepFirstRowStable() async throws {
        let state = ExpansionState()
        let measurements = Measurements()
        let host = NSHostingView(rootView: AnimatedPanel(state: state, measurements: measurements))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 67)
        host.layoutSubtreeIfNeeded()
        let initialBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: initialBitmap)
        try await Task.sleep(for: .milliseconds(20))

        for expanded in [true, false] {
            state.isExpanded = expanded
            var heights: [CGFloat] = []
            for _ in 0 ..< 40 {
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(measurements.contentTop == 10)
                heights.append(measurements.size.height)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(heights.last == (expanded ? 94 : 67))
            #expect(heights.contains { $0 > 67 && $0 < 94 })
            #expect(heights.allSatisfy { $0 >= 67 && $0 <= 94 })
        }
    }

    private final class ExpansionState: ObservableObject {
        @Published var isExpanded = false
    }

    private final class Measurements {
        var size = CGSize(width: 300, height: 67)
        var contentTop: CGFloat = -1
    }

    private struct AnimatedPanel: View {
        @ObservedObject var state: ExpansionState
        let measurements: Measurements

        var body: some View {
            VStack(spacing: 0) {
                Color.blue
                    .frame(height: 22)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .global).minY
                    } action: { measurements.contentTop = $0 }
                Color.clear
                    .settingsOptionsReveal(isExpanded: true, height: 22, spacing: 5)
                Color.clear
                    .settingsOptionsReveal(isExpanded: state.isExpanded, height: 22, spacing: 5)
            }
            .padding(.vertical, 10)
            .frame(width: 300)
            .fixedSize(horizontal: true, vertical: true)
            .settingsOptionsPanel(height: state.isExpanded ? 94 : 67)
            .animation(SettingsOptionsPanelMetrics.contentAnimation, value: state.isExpanded)
            .environment(\.settingsOptionsPanelSizeObserver, SettingsOptionsPanelSizeObserver {
                measurements.size = $0
            })
        }
    }
}
