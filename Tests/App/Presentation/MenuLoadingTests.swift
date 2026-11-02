import AppKit
import SwiftUI
import Testing

@MainActor
struct MenuLoadingTests {
    @Test func sharedHostKeepsContentAtTopWhenWindowHeightLags() {
        var measuredHeight: CGFloat = 0
        var contentTop: CGFloat = -1
        let view = MenuPanelLayout(
            onHeightChange: { measuredHeight = $0 },
            content: {
                Color.blue
                    .frame(width: 200, height: 80.5)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .global).minY
                    } action: { contentTop = $0 }
            }
        )
        let host = NSHostingView(rootView: view)
        // 模拟内容已经收起, 宿主仍保留上一帧高度
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 240)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.height == 81)
        #expect(measuredHeight == 81)
        #expect(contentTop == 0)
    }

    @Test func initialLoadingKeepsOneAccountAndPlaceholderAcrossLayouts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let initialSize = fixture.size()
        #expect(initialSize.width == CodexStatusMenuView.menuWidth)
        #expect(initialSize.height > 100 && initialSize.height < 180)

        for visible in [[MainPanelSection.account], [.usage], [.activity, .serviceStatus], MainPanelSection.allCases] {
            fixture.preferences.defaults.set(
                MainPanelSection.allCases.filter { !visible.contains($0) }.map(\.rawValue),
                forKey: "MainPanel.hiddenSections"
            )
            fixture.preferences.defaults.set(MainPanelSection.allCases.reversed().map(\.rawValue), forKey: "MainPanel.sectionOrder")
            fixture.settings.refresh()
            #expect(fixture.size() == initialSize)
            #expect(fixture.settings.layout.visibleSections == MainPanelSection.allCases.reversed().filter { visible.contains($0) })
        }
    }

    @Test(.tags(.integration)) func cachedHistoryDoesNotExpandTheInitialPlaceholder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let initialSize = fixture.size()
        try fixture.directory.seedTokenUsageAggregates([
            TestFixtures.tokenUsageAggregate(at: Date(), tokenUsage: TestFixtures.tokenUsage(100))
        ])
        fixture.history.refresh()
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) {
            !fixture.history.snapshot.tokenUsageByDate.isEmpty
        })
        #expect(fixture.model.loadState == .loading)
        #expect(fixture.size() == initialSize)
    }

    @Test(.tags(.integration), arguments: [true, false])
    func firstResponseRestoresConfiguredLayoutAndStopsLoading(signedIn: Bool) async throws {
        let server = try makeServer(signedIn: signedIn)
        defer { server.close() }
        let fixture = try Fixture(socketURL: server.url)
        defer { fixture.cleanUp() }
        fixture.preferences.defaults.set(
            MainPanelSection.allCases.filter { $0 != .account }.map(\.rawValue),
            forKey: "MainPanel.hiddenSections"
        )
        fixture.settings.refresh()
        let initialHeight = fixture.size().height
        fixture.model.refresh(trigger: .manual)
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) {
            !fixture.model.isRefreshing && fixture.model.loadState != .loading
        })
        #expect(fixture.model.loadState == (signedIn ? .loaded : .notLoggedIn))
        #expect(fixture.settings.layout.visibleSections == [.account])
        #expect(fixture.size().height < initialHeight - 60)
        try server.finish()
    }

    @Test(.tags(.integration), arguments: [true, false])
    func firstResponseKeepsSurfaceAnchoredWhileResizing(signedIn: Bool) async throws {
        let server = try makeServer(signedIn: signedIn)
        defer { server.close() }
        let fixture = try Fixture(socketURL: server.url)
        defer { fixture.cleanUp() }
        if !signedIn {
            fixture.preferences.defaults.set(
                MainPanelSection.allCases.filter { $0 != .account }.map(\.rawValue),
                forKey: "MainPanel.hiddenSections"
            )
            fixture.settings.refresh()
        }
        fixture.animationState.allowsAnimations = true
        let host = fixture.host()
        var heights: [CGFloat] = []

        for frame in 0 ..< 50 {
            if frame == 3 {
                fixture.model.refresh(trigger: .manual)
            }
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let top = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 4))
            // 取顶部中央避开圆角, 外层玻璃居中插值时这里会出现透明缺口
            #expect(top.alphaComponent > 0.5)
            #expect(host.frame.width == CodexStatusMenuView.menuWidth)
            heights.append(host.frame.height)
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(fixture.model.loadState == (signedIn ? .loaded : .notLoggedIn))
        let first = try #require(heights.first)
        let last = try #require(heights.last)
        #expect(abs(first - last) > 10)
        #expect(heights.contains { $0 > min(first, last) + 1 && $0 < max(first, last) - 1 })
        #expect(heights.allSatisfy { $0 >= min(first, last) - 1 && $0 <= max(first, last) + 1 })
        try server.finish()
    }

    private func makeServer(signedIn: Bool) throws -> SharedServerFixture {
        try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let account = try peer.readMessage()
            if signedIn {
                try peer.reply(to: account, result: ["account": ["type": "chatgpt", "email": "a@example.test", "planType": "pro"]])
                let limits = try peer.readMessage()
                try peer.reply(to: limits, result: ["rateLimits": [:]])
                let usage = try peer.readMessage()
                try peer.reply(to: usage, result: ["summary": ["lifetimeTokens": 100]])
            } else {
                try peer.reply(to: account, result: ["account": NSNull()])
            }
        }
    }

    private final class Fixture {
        let directory: TestDirectory
        let preferences: TestPreferences
        let model: CodexStatusViewModel
        let history: HistoryViewModel
        let settings: MainPanelSettings
        let menu: CodexStatusMenuView
        let updater = AppUpdater(bundle: Bundle(for: NSView.self))
        let animationState = MenuSurfaceAnimationState()

        init(socketURL: URL? = nil) throws {
            directory = try TestDirectory()
            preferences = try TestPreferences()
            settings = MainPanelSettings(defaults: preferences.defaults)
            model = CodexStatusViewModel(
                service: CodexStatusService(socketURL: socketURL ?? directory.url.appendingPathComponent("unused.sock"), logStorage: nil),
                defaults: preferences.defaults
            )
            history = HistoryViewModel(service: HistoryService(directoryURL: directory.url))
            let activity = ActivityMonitor(
                protectionSettings: ProtectionSettings(defaults: preferences.defaults),
                protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
            )
            menu = CodexStatusMenuView(
                viewModel: model, historyViewModel: history, mainPanelSettings: settings,
                serviceStatusMonitor: CodexServiceStatusMonitor(fetch: { .operational }), activityMonitor: activity,
                syncSettings: SyncSettings(defaults: preferences.defaults, queryAvailability: { .available }, loadLastUpload: { nil }),
                keepAliveController: KeepAliveController(activityMonitor: activity, defaults: preferences.defaults),
                menuSurfaceVisibility: MenuSurfaceVisibilityState(), animationState: animationState,
                activityCenterPresentationState: ActivityCenterPresentationState(),
                activityCardPresentationState: ActivityCardPresentationState(activityMonitor: activity),
                onUsageHeatmapHoverChange: { _ in }, onResetCreditsTap: { _ in }, onActivityCenterTap: { _ in }
            )
        }

        func size() -> CGSize {
            host().fittingSize
        }

        func host() -> NSHostingView<AnyView> {
            let view = menu.environmentObject(updater)
                .frame(width: CodexStatusMenuView.menuWidth)
                .fixedSize(horizontal: false, vertical: true)
                .preferredColorScheme(.light)
            return NSHostingView(rootView: AnyView(MenuPanelLayout { view }))
        }

        func cleanUp() {
            preferences.remove()
            try? directory.remove()
        }
    }
}
