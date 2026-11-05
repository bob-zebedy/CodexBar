import Foundation
import Testing

struct MenuBarIndicatorSettingsTests {
    @Test(arguments: [QuotaWindowKind.primary, .secondary])
    func defaultWeeklyUsesActualWindowAndReachesIcon(_ kind: QuotaWindowKind) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set("primary", forKey: "MenuBarQuota.selection")
        let settings = MenuBarIndicatorSettings(defaults: preferences.defaults)
        settings.setEnabled(true)
        let restored = MenuBarIndicatorSettings(defaults: preferences.defaults)
        let snapshot = try snapshot(weeklyKind: kind)
        let metrics = restored.configuration.visibleMetrics(in: snapshot.codexLimit?.windows ?? [])
        let metric = try #require(metrics.first)
        let window = try #require(snapshot.codexLimit?.window(ofKind: metric.windowKind))
        #expect(window.label == "Weekly")
        #expect(metrics.count == 1)
        let progress = try #require(StatusIconProgress(snapshot: snapshot, metric: metric))
        let presentation = StatusItemIconPresentation()
        presentation.update(
            isUnavailable: false,
            ordinaryUsageAllowed: nil,
            indicators: [.init(percent: progress.percent(at: TestFixtures.now), isStale: progress.isStale)],
            animated: false
        )
        #expect(presentation.state.showsIndicators)
        #expect(presentation.state.indicators.first?.percent == 41)
        #expect(!presentation.state.usesSplitRingStyle)
    }

    @Test(arguments: [nil, "off", "primary", "secondary"] as [String?])
    func defaultsOffAndIgnoresLegacyPreferences(_ legacySelection: String?) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(legacySelection, forKey: "MenuBarQuota.selection")
        preferences.defaults.set("primary", forKey: "MenuBarQuota.lastWindowSelection")
        let configuration = MenuBarIndicatorSettings(defaults: preferences.defaults).configuration
        #expect(!configuration.isEnabled)
        #expect(configuration.count == .one)
        #expect(configuration.visibleMetrics(in: []).isEmpty)
        #expect(configuration.firstMetric == nil)
        #expect(configuration.secondMetric == nil)
        #expect(preferences.defaults.string(forKey: "MenuBarQuota.selection") == legacySelection)
    }

    @Test func toolTipFollowsEnabledMetricsAndTheirLeftToRightOrder() throws {
        let snapshot = try snapshot(weeklyKind: .secondary)
        let resetDate = try #require(snapshot.codexLimit?.window(ofKind: .secondary)?.resetsAt)
        let now = resetDate.addingTimeInterval(-93780)
        let percent = CodexPercentageFormat.string(from: 41)
        let quota = String(localized: "menu-bar-indicator.tooltip.quota", defaultValue: "\(percent)")
        let duration = String(localized: "menu-bar-indicator.tooltip.duration", defaultValue: "\(1) \(2) \(3)")
        let reset = String(localized: "menu-bar-indicator.tooltip.reset", defaultValue: "\(duration)")
        let missing = "--"
        let missingQuota = String(localized: "menu-bar-indicator.tooltip.quota", defaultValue: "\(missing)")
        let missingReset = String(localized: "menu-bar-indicator.tooltip.reset", defaultValue: "\(missing)")
        let cases: [(MenuBarIndicatorConfiguration, String)] = [
            (.init(isEnabled: true, count: .one, firstMetric: .secondaryQuota, secondMetric: .secondaryReset), quota),
            (.init(isEnabled: true, count: .one, firstMetric: .secondaryReset, secondMetric: .secondaryQuota), reset),
            (.init(isEnabled: true, count: .two, firstMetric: .secondaryQuota, secondMetric: .secondaryReset), quota + " | " + reset),
            (.init(isEnabled: true, count: .two, firstMetric: .secondaryReset, secondMetric: .secondaryQuota), reset + " | " + quota),
            (.init(isEnabled: true, count: .two, firstMetric: .primaryQuota, secondMetric: .secondaryQuota), missingQuota + " | " + quota)
        ]
        for (configuration, expected) in cases {
            let state = StatusIconState(loadState: .loaded, snapshot: snapshot, configuration: configuration)
            #expect(state.toolTip(at: now) == expected)
        }
        var configuration = MenuBarIndicatorConfiguration(isEnabled: true, count: .two)
        #expect(StatusIconState(loadState: .loaded, snapshot: snapshot, configuration: configuration).toolTip(at: now) == quota + " | " + reset)
        #expect(StatusIconState(loadState: .loading, snapshot: nil, configuration: configuration).toolTip(at: now) == missingQuota + " | " + missingReset)
        configuration.isEnabled = false
        let disabled = StatusIconState(loadState: .loaded, snapshot: snapshot, configuration: configuration)
        #expect(disabled.toolTip(at: now) == nil)
        #expect(disabled.nextRefreshDate(after: now) == nil)
    }

    @Test(arguments: [
        (93780.0, String(localized: "menu-bar-indicator.tooltip.duration", defaultValue: "\(1) \(2) \(3)"), 60.0 as TimeInterval?),
        (86400, String(localized: "menu-bar-indicator.tooltip.duration", defaultValue: "\(1) \(0) \(0)"), 60),
        (7380, String(localized: "menu-bar-indicator.tooltip.duration-hours", defaultValue: "\(2) \(3)"), 60),
        (3600, String(localized: "menu-bar-indicator.tooltip.duration-hours", defaultValue: "\(1) \(0)"), 60),
        (60.25, String(localized: "menu-bar-indicator.tooltip.duration-minutes", defaultValue: "\(2)"), 0.25),
        (60, String(localized: "menu-bar-indicator.tooltip.duration-minutes", defaultValue: "\(1)"), 60),
        (1, String(localized: "menu-bar-indicator.tooltip.duration-minutes", defaultValue: "\(1)"), 1),
        (0, String(localized: "menu-bar-indicator.tooltip.reset-now"), nil),
        (-60, String(localized: "menu-bar-indicator.tooltip.reset-now"), nil)
    ])
    func resetToolTipRoundsUpAndRefreshesAtMinuteBoundaries(remaining: TimeInterval, expected: String, refreshDelay: TimeInterval?) throws {
        let snapshot = try snapshot(weeklyKind: .secondary)
        let resetDate = try #require(snapshot.codexLimit?.window(ofKind: .secondary)?.resetsAt)
        let progress = try #require(StatusIconProgress(snapshot: snapshot, metric: .secondaryReset))
        let now = resetDate.addingTimeInterval(-remaining)
        #expect(progress.toolTipValue(at: now) == expected)
        #expect(progress.nextRefreshDate(after: now) == refreshDelay.map { now.addingTimeInterval($0) })
    }

    @Test func defaultWeeklyResolvesAfterDataArrivesAndPrefersWeeklyOverFirstWindow() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MenuBarIndicatorSettings(defaults: preferences.defaults)
        settings.setEnabled(true)
        let configuration = MenuBarIndicatorSettings(defaults: preferences.defaults).configuration
        #expect(configuration.visibleMetrics(in: []).count == 1)
        let primaryWeekly = try #require(snapshot(weeklyKind: .primary).codexLimit).windows
        #expect(configuration.visibleMetrics(in: primaryWeekly) == [.primaryQuota])
        let secondaryWeekly = try #require(snapshot(weeklyKind: .secondary).codexLimit).windows
        let primary = QuotaWindow(kind: .primary, windowDurationMins: 300, usedPercent: 20, resetsAt: nil)
        #expect(configuration.visibleMetrics(in: [primary] + secondaryWeekly) == [.secondaryQuota])
        #expect(configuration.visibleMetrics(in: [primary]) == [.primaryQuota])
        #expect(preferences.defaults.object(forKey: "MenuBarIndicator.firstMetric") == nil)
    }

    @Test func togglingAndChangingLayoutKeepUnselectedDefaultsDynamic() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MenuBarIndicatorSettings(defaults: preferences.defaults)
        settings.setEnabled(true)
        settings.setCount(.two)
        let configuration = MenuBarIndicatorSettings(defaults: preferences.defaults).configuration
        let windows = try #require(snapshot(weeklyKind: .primary).codexLimit).windows
        #expect(configuration.visibleMetrics(in: windows) == [.primaryQuota, .primaryReset])
        #expect(configuration.firstMetric == nil)
        #expect(configuration.secondMetric == nil)
        settings.setEnabled(false)
        #expect(!MenuBarIndicatorSettings(defaults: preferences.defaults).configuration.isEnabled)
    }

    @Test func metricEditsUseResolvedWindowAndPreserveExplicitPreferences() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MenuBarIndicatorSettings(defaults: preferences.defaults)
        let windows = try #require(snapshot(weeklyKind: .primary).codexLimit).windows
        settings.setEnabled(true)
        settings.setMetric(isResetTime: true, at: 0, windows: windows)
        settings.setMetric(windowKind: .secondary, at: 1, windows: windows)
        let configuration = MenuBarIndicatorSettings(defaults: preferences.defaults).configuration
        #expect(configuration.isEnabled)
        #expect(configuration.firstMetric == .primaryReset)
        #expect(configuration.secondMetric == .secondaryReset)
        #expect(configuration.metrics(in: []) == [.primaryReset, .secondaryReset])
        let secondaryWeekly = try #require(snapshot(weeklyKind: .secondary).codexLimit).windows
        #expect(configuration.metrics(in: secondaryWeekly) == [.primaryReset, .secondaryReset])
    }

    private func snapshot(weeklyKind: QuotaWindowKind) throws -> CodexQuotaSnapshot {
        let response = try TestFixtures.decode(AccountRateLimitsResponse.self, """
        {"rateLimits":{"\(weeklyKind.rawValue)":{"usedPercent":59,"windowDurationMins":10080,"resetsAt":1793905434}}}
        """)
        return try CodexQuotaSnapshot(
            accountResponse: AccountReadResponse(account: CodexAccount(type: "chatgpt", email: nil, planType: nil)),
            rateLimitsResponse: response
        )
    }
}
