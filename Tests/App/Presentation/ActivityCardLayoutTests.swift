import AppKit
import SwiftUI
import Testing

@Suite(.serialized)
struct ActivityCardLayoutTests {
    @Test func hidingKeepsOriginalTaskSymbolVisible() async throws {
        let fixture = try CardFixture(hasTokens: true, anchorEdge: .minY)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try fixture.bluePixelCount() > 12)
        fixture.monitor.graph.tasks.removeAll()
        fixture.monitor.refreshSnapshot(now: fixture.now)
        try await Task.sleep(for: .milliseconds(40))
        #expect(try fixture.bluePixelCount() > 12, "The departing task changed to the gray idle placeholder")
    }

    @Test(arguments: [false, true])
    func hidingSectionStartsGently(hasTokens: Bool) async throws {
        let fixture = try CardFixture(hasTokens: hasTokens, anchorEdge: .minY)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let visible = fixture.height
        fixture.monitor.graph.tasks.removeAll()
        fixture.monitor.refreshSnapshot(now: fixture.now)
        try await Task.sleep(for: .milliseconds(60))
        let firstMovement = visible - fixture.height
        let totalMovement: CGFloat = (hasTokens ? 108 : 58) + 10
        #expect(firstMovement < totalMovement * 0.4, "The drawer collapsed too abruptly at the start: \(firstMovement) / \(totalMovement)")
    }

    @Test func resizingPopoverKeepsHeaderAtSameScreenPosition() async throws {
        let fixture = try CardFixture(hasTokens: false, anchorEdge: .minY, panelWidth: 491)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let initial = try #require(fixture.headerFrame.currentScreenFrame()).maxY
        var offsets: [CGFloat] = []
        for hasTokens: Bool? in [true, false, nil, false, true, nil] {
            if let hasTokens {
                fixture.update(hasTokens: hasTokens, newTask: true)
            } else {
                fixture.monitor.graph.tasks.removeAll()
                fixture.monitor.refreshSnapshot(now: fixture.now)
            }
            for _ in 0 ..< 25 {
                try await Task.sleep(for: .milliseconds(16))
                let header = try #require(fixture.headerFrame.currentScreenFrame())
                offsets.append(header.maxY - initial)
            }
        }
        #expect(offsets.allSatisfy { abs($0) < 0.1 }, "Stationary header moved during resizing: \(offsets)")
    }

    @Test func restoringSectionKeepsCardAboveHistory() async throws {
        let fixture = try CardFixture(hasTokens: false, anchorEdge: .minY)
        defer { fixture.close() }
        fixture.monitor.graph.tasks.removeAll()
        fixture.monitor.refreshSnapshot(now: fixture.now)
        _ = try await fixture.sampleHeights()
        fixture.update(hasTokens: false, newTask: true)
        var gaps: [CGFloat] = []
        for _ in 0 ..< 25 {
            try await Task.sleep(for: .milliseconds(16))
            if let card = fixture.cardFrame.currentScreenFrame(), let history = fixture.historyFrame.currentScreenFrame() {
                gaps.append(card.minY - history.maxY)
            }
        }
        #expect(gaps.count > 3)
        #expect(gaps.allSatisfy { $0 >= 9.5 }, "The revealing card overlapped the history section: \(gaps)")
    }

    @Test(arguments: [false, true])
    func taskTokenHeightChangesContinuously(collapsing: Bool) async throws {
        let fixture = try CardFixture(hasTokens: collapsing)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let initial = fixture.height
        fixture.update(hasTokens: !collapsing)
        let heights = try await fixture.sampleHeights()
        let final = try #require(heights.last)
        #expect(abs(final - initial) >= 49)
        expectContinuous(heights, from: initial, to: final)
    }

    @Test func switchingTasksAndReversingDuringExpansionStaysWithinBounds() async throws {
        let fixture = try CardFixture(hasTokens: false)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let initial = fixture.height
        fixture.update(hasTokens: true, newTask: true)
        let expanding = try await fixture.sampleHeights(count: 6)
        let turningPoint = fixture.height
        #expect(turningPoint > initial + 1)
        fixture.update(hasTokens: false, newTask: true)
        let collapsing = try await fixture.sampleHeights()
        #expect(abs(fixture.height - initial) < 1)
        #expect((expanding + collapsing).allSatisfy { $0 >= initial - 1 && $0 <= initial + 51 })
        #expect(collapsing.contains { $0 > initial + 1 && $0 < turningPoint - 1 })
        // 反向时保留短暂的连续速度, 随后必须稳定收回且不能越过目标范围
        #expect((collapsing.max() ?? turningPoint) <= turningPoint + 10)
        let settledDirection = Array(collapsing.dropFirst(4))
        #expect(zip(settledDirection, settledDirection.dropFirst()).allSatisfy { $1 <= $0 + 1 }, "Reversal continued expanding: \(collapsing)")
    }

    @Test func disabledAnimationsApplyFinalHeightImmediately() async throws {
        let fixture = try CardFixture(hasTokens: false, allowsAnimations: false)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let initial = fixture.height
        fixture.update(hasTokens: true)
        let heights = try await fixture.sampleHeights(count: 6)
        #expect(abs(fixture.height - initial - 50) < 1)
        #expect(heights.allSatisfy { abs($0 - initial) < 1 || abs($0 - initial - 50) < 1 })
    }

    @Test(arguments: [0.25, 0.75, 0.999, 1.0])
    func sectionRevealPreservesShadowOutsideVisibleCard(progress: CGFloat) throws {
        let fixture = try CardFixture(hasTokens: true)
        defer { fixture.close() }
        let card = ActivityCard(
            activityMonitor: fixture.monitor,
            presentationState: ActivityCenterPresentationState(),
            keepAliveController: KeepAliveController(activityMonitor: fixture.monitor, defaults: fixture.preferences.defaults),
            onTaskCenterTap: { _ in }
        )
        .modifier(ActivitySectionReveal(height: 108 * progress, progress: progress))
        .frame(width: 300)
        .padding(40)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        let bitmap = try NSBitmapImageRep(cgImage: #require(renderer.cgImage))
        let shadow = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 72))
        #expect(shadow.alphaComponent > 0, "The drawer clipped its shadow at the visible bottom edge")
    }

    @Test func switchingToWrappedHeaderAndBackAnimatesNaturalHeight() async throws {
        let fixture = try CardFixture(hasTokens: true)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let initial = fixture.height
        fixture.update(hasTokens: true, newTask: true)
        fixture.monitor.graph.tasks[fixture.key]?.projectName = String(repeating: "Long project name ", count: 5)
        fixture.monitor.refreshSnapshot(now: fixture.now)
        let expanding = try await fixture.sampleHeights()
        let expanded = fixture.height
        #expect(expanded > initial + 1)
        expectContinuous(expanding, from: initial, to: expanded)
        fixture.update(hasTokens: true, newTask: true)
        let collapsing = try await fixture.sampleHeights()
        #expect(abs(fixture.height - initial) < 1)
        expectContinuous(collapsing, from: expanded, to: initial)
    }

    @Test func hidingAndRestoringSectionAnimatesHostHeight() async throws {
        let fixture = try CardFixture(hasTokens: false)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let visible = fixture.height
        fixture.monitor.graph.tasks.removeAll()
        fixture.monitor.refreshSnapshot(now: fixture.now)
        let collapsing = try await fixture.sampleHeights()
        let hidden = fixture.height
        #expect(abs(visible - hidden - 68) < 1)
        expectContinuous(collapsing, from: visible, to: hidden)
        fixture.update(hasTokens: false, newTask: true)
        let expanding = try await fixture.sampleHeights()
        #expect(abs(fixture.height - visible) < 1)
        expectContinuous(expanding, from: hidden, to: visible)
    }

    @Test(arguments: [false, true], ActivityPlacement.allCases)
    func hidingSectionDoesNotSnapAtEnd(hasTokens: Bool, placement: ActivityPlacement) async throws {
        let fixture = try CardFixture(hasTokens: hasTokens, anchorEdge: .minY, placement: placement)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let visible = fixture.height
        fixture.monitor.graph.tasks.removeAll()
        fixture.monitor.refreshSnapshot(now: fixture.now)
        let heights = try await fixture.sampleHeights(count: 35)
        let steps = zip(heights, heights.dropFirst()).map { abs($1 - $0) }.filter { $0 > 0 }
        let finalStep = try #require(steps.last)
        #expect(finalStep <= 2, "The drawer snapped on its final moving frame: \(heights)")
        let removedHeight: CGFloat = (hasTokens ? 108 : 58) + (placement == .only ? 0 : 10)
        #expect(abs(visible - fixture.height - removedHeight) < 1)
    }

    @Test func reversingSectionRemovalKeepsTheRestoredCard() async throws {
        let fixture = try CardFixture(hasTokens: false)
        defer { fixture.close() }
        try await Task.sleep(for: .milliseconds(100))
        let visible = fixture.height
        for _ in 0 ..< 3 {
            fixture.monitor.graph.tasks.removeAll()
            fixture.monitor.refreshSnapshot(now: fixture.now)
            _ = try await fixture.sampleHeights(count: 5)
            #expect(fixture.height < visible - 1)
            fixture.update(hasTokens: false, newTask: true)
            _ = try await fixture.sampleHeights(count: 5)
        }
        _ = try await fixture.sampleHeights()
        #expect(abs(fixture.height - visible) < 1)
    }

    private func expectContinuous(_ heights: [CGFloat], from initial: CGFloat, to final: CGFloat) {
        let lower = min(initial, final)
        let upper = max(initial, final)
        #expect(
            heights.filter { $0 > lower + 1 && $0 < upper - 1 }.count >= 3,
            "Host height jumped instead of revealing the drawer: \(heights)"
        )
        #expect(heights.allSatisfy { $0 >= lower - 1 && $0 <= upper + 1 })
        let changes = zip([initial] + heights, heights).map { $1 - $0 }
        #expect(changes.allSatisfy { abs($0) < (upper - lower) * 0.7 })
        #expect(changes.allSatisfy { final > initial ? $0 >= -1 : $0 <= 1 })
    }

    @Test func narrowStatusContentExpandsWithoutClipping() {
        let short = statusSize(width: 300, long: false)
        let wide = statusSize(width: 480, long: true)
        let narrow = statusSize(width: 180, long: true)
        #expect(narrow.width == 180)
        #expect(narrow.height > wide.height)
        #expect(narrow.height > short.height)
        #expect(narrow.height.isFinite)
    }

    @Test func wrappedSupplementUsesOneLineEvenWhenItIsVeryLong() {
        let short = supplementarySize("2 个子 Agent 运行中")
        let long = supplementarySize(String(repeating: "附加信息", count: 40))
        #expect(long.width == 140)
        #expect(long.height == short.height)
    }

    private func supplementarySize(_ supplement: String) -> CGSize {
        let content = ActivityStatusText(
            text: "正在读取文件, 浏览目录, 搜索文件内容",
            tint: .blue, effect: .none, lineLimit: nil, supplement: supplement
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 140, alignment: .leading)
        return NSHostingView(rootView: content).fittingSize
    }

    private func statusSize(width: CGFloat, long: Bool) -> CGSize {
        let content = VStack(alignment: .leading, spacing: 3) {
            Text("CodexBar • gpt-6-astra • high • 已运行 1 小时 24 分")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            ActivityStatusText(
                text: long ? "正在读取文件, 浏览目录, 搜索文件内容" : "正在回答",
                tint: .blue, effect: .none, lineLimit: nil, supplement: "3 个子 Agent 运行中"
            )
            .fixedSize(horizontal: false, vertical: true)
            Text("最近事件: 读取文件, 浏览目录, 搜索内容完成")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
        return NSHostingView(rootView: content).fittingSize
    }
}

enum ActivityPlacement: CaseIterable {
    case first, middle, last, only
}

private final class CardFixture {
    let directory: TestDirectory
    let preferences: TestPreferences
    let monitor: ActivityMonitor
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    let popover: NSPopover
    let now = Date()
    let key = ActivityTaskKey(thread: "drawer", turn: "turn")
    let headerFrame = ScreenFrameProvider()
    let cardFrame = ScreenFrameProvider()
    let historyFrame = ScreenFrameProvider()

    var height: CGFloat {
        controller.preferredContentSize.height
    }

    init(
        hasTokens: Bool,
        allowsAnimations: Bool = true,
        anchorEdge: NSRectEdge = .maxX,
        panelWidth: CGFloat = 560,
        placement: ActivityPlacement = .middle
    ) throws {
        directory = try TestDirectory()
        preferences = try TestPreferences()
        monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDataDirectoryURL: directory.url
        )
        var task = ActivityTask(
            displayID: UUID(), key: key,
            event: TestFixtures.event(at: now, thread: key.threadID, turn: key.turnID),
            state: .running, startedAt: now, progressGeneration: 1
        )
        task.projectName = "CodexBar"
        task.tokenUsage = hasTokens ? .zero : nil
        monitor.graph.tasks[key] = task
        monitor.isActivitySourceHealthy = true
        monitor.refreshSnapshot(now: now)
        let content = CardFixturePanel(
            monitor: monitor,
            keepAlive: KeepAliveController(activityMonitor: monitor, defaults: preferences.defaults),
            headerFrame: headerFrame,
            cardFrame: cardFrame,
            historyFrame: historyFrame,
            placement: placement
        )
        .padding(12)
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        let root = MenuPanelLayout { content }
            .environment(\.mainPanelAnimationsEnabled, allowsAnimations)
        controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = [.preferredContentSize]
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorY = anchorEdge == .minY ? screen.maxY - 64 : 400
        window = NSWindow(contentRect: NSRect(x: 100, y: anchorY, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.orderFront(nil)
        popover = NSPopover()
        popover.animates = false
        popover.contentViewController = controller
        let anchor = try #require(window.contentView)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchorEdge)
    }

    func update(hasTokens: Bool, newTask: Bool = false) {
        if newTask {
            var task = ActivityTask(
                displayID: UUID(), key: key,
                event: TestFixtures.event(at: now, thread: key.threadID, turn: key.turnID),
                state: .running, startedAt: now, progressGeneration: 1
            )
            task.projectName = hasTokens ? "Peekaboo" : "CodexBar"
            monitor.graph.tasks[key] = task
        }
        monitor.graph.tasks[key]?.tokenUsage = hasTokens ? .zero : nil
        monitor.refreshSnapshot(now: now)
    }

    func sampleHeights(count: Int = 30) async throws -> [CGFloat] {
        var heights: [CGFloat] = []
        for _ in 0 ..< count {
            try await Task.sleep(for: .milliseconds(16))
            heights.append(height)
            #expect(abs(popover.contentSize.height - height) < 1)
        }
        return heights
    }

    func bluePixelCount() throws -> Int {
        let view = controller.view
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.blueComponent > color.redComponent + 0.2,
                   color.blueComponent > color.greenComponent + 0.05 {
                    count += 1
                }
            }
        }
        return count
    }

    func close() {
        popover.close()
        window.close()
        preferences.remove()
        try? directory.remove()
    }
}

private struct CardFixturePanel: View {
    @ObservedObject var monitor: ActivityMonitor
    let keepAlive: KeepAliveController
    let headerFrame: ScreenFrameProvider
    let cardFrame: ScreenFrameProvider
    let historyFrame: ScreenFrameProvider
    let placement: ActivityPlacement

    var body: some View {
        MenuSectionLayout(spacing: 10) {
            if placement == .first || placement == .only {
                activity
            }
            if placement != .only {
                Text("Quota").frame(maxWidth: .infinity).frame(height: 50).background(.gray.opacity(0.2))
                    .background { ScreenFrameReader(provider: headerFrame) }
                if placement == .middle {
                    activity
                }
                Text("History").frame(maxWidth: .infinity).frame(height: 100).background(.green.opacity(0.2))
                    .background { ScreenFrameReader(provider: historyFrame) }
            }
            if placement == .last {
                activity
            }
        }
    }

    private var activity: some View {
        ActivitySection(isVisible: monitor.snapshot.hasTaskCenterContent) {
            ActivityCard(
                activityMonitor: monitor,
                presentationState: ActivityCenterPresentationState(),
                keepAliveController: keepAlive,
                onTaskCenterTap: { _ in }
            )
            .background { ScreenFrameReader(provider: cardFrame) }
        }
    }
}
