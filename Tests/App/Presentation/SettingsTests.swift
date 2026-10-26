import Foundation
import Testing

struct SettingsTests {
    @Test(arguments: [false, true])
    func syncPreferenceDefaultsOffAndReadsStoredValue(_ enabled: Bool) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        #expect(!SyncSettings.isEnabled(defaults: defaults))
        defaults.set(enabled, forKey: "Sync.isEnabled")
        #expect(SyncSettings.isEnabled(defaults: defaults) == enabled)
    }

    @Test func protectionPreferenceFallsBackPersistsAndRefreshes() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        #expect(ProtectionSettings(defaults: defaults).inactivityDuration == .oneHour)
        defaults.set("invalid", forKey: "Protection.inactivityDurationSeconds")
        let settings = ProtectionSettings(defaults: defaults)
        #expect(settings.inactivityDuration == .oneHour)
        settings.setInactivityDuration(.thirtyMinutes)
        #expect(defaults.integer(forKey: "Protection.inactivityDurationSeconds") == 1800)
        #expect(ProtectionSettings(defaults: defaults).inactivityDuration == .thirtyMinutes)
        for duration in [ProtectionSettings.InactivityDuration.twoHours, .fourHours] {
            defaults.set(duration.rawValue, forKey: "Protection.inactivityDurationSeconds")
            settings.refresh()
            #expect(settings.inactivityDuration == duration)
            #expect(ProtectionSettings(defaults: defaults).inactivityDuration == duration)
        }
    }

    @Test(arguments: DataUpdateInterval.allCases)
    func dataUpdateIntervalPersistsAndUpdatesCountdown(_ interval: DataUpdateInterval) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let service = makeStatusService(suiteName: preferences.suite)
        let model = CodexStatusViewModel(service: service, defaults: preferences.defaults)
        #expect(model.dataUpdateInterval == .oneMinute)
        model.setDataUpdateInterval(interval)
        #expect(model.autoRefreshInterval == interval.duration)
        let restored = CodexStatusViewModel(service: service, defaults: preferences.defaults)
        #expect(restored.dataUpdateInterval == interval)
        #expect(restored.autoRefreshInterval == interval.duration)
        #expect(!model.isRefreshing)
        #expect(model.autoRefreshCountdownStartedAt == nil)
    }

    @Test(arguments: [0, -60, 90, 1200])
    func invalidDataUpdateIntervalUsesDefault(_ seconds: Int) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(seconds, forKey: "DataUpdate.intervalSeconds")
        let model = CodexStatusViewModel(
            service: makeStatusService(suiteName: preferences.suite),
            defaults: preferences.defaults
        )
        #expect(model.dataUpdateInterval == .oneMinute)
    }

    @Test func dataUpdateIntervalRespectsElapsedTimeAndNewRefreshOrigin() {
        let start = TestFixtures.now
        let now = start.addingTimeInterval(150)
        #expect(DataUpdateInterval.tenMinutes.remainingTime(since: start, now: now) == 450)
        #expect(DataUpdateInterval.threeMinutes.remainingTime(since: start, now: now) == 30)
        #expect(DataUpdateInterval.twoMinutes.remainingTime(since: start, now: now) == 0)
        #expect(DataUpdateInterval.oneMinute.remainingTime(since: nil, now: now) == 0)
        #expect(DataUpdateInterval.oneMinute.remainingTime(since: start, now: start.addingTimeInterval(60)) == 0)
        #expect(DataUpdateInterval.fiveMinutes.remainingTime(since: now, now: now) == 300)
    }

    private nonisolated func makeStatusService(suiteName: String) -> CodexStatusService {
        CodexStatusService(socketURL: URL(fileURLWithPath: "/tmp/\(suiteName).sock"), logStorage: nil)
    }

    @Test func mainPanelAnimationsPreserveStoredPreferenceAndDefault() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        #expect(MainPanelSettings(defaults: defaults).areAnimationsEnabled)
        defaults.set(false, forKey: "MainPanel.areAnimationsEnabled")
        let settings = MainPanelSettings(defaults: defaults)
        #expect(!settings.areAnimationsEnabled)
        settings.setAnimationsEnabled(true)
        #expect(defaults.bool(forKey: "MainPanel.areAnimationsEnabled"))
        defaults.set(false, forKey: "MainPanel.areAnimationsEnabled")
        settings.refresh()
        #expect(!settings.areAnimationsEnabled)
    }

    @Test(arguments: [UsageHeatmapMode.daily, .weekly])
    func usageHeatmapModePersistsRestoresAndRefreshes(_ mode: UsageHeatmapMode) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        let previousMode: UsageHeatmapMode = mode == .daily ? .weekly : .daily
        defaults.set(previousMode.rawValue, forKey: "MainPanel.usageHeatmapMode")
        let settings = MainPanelSettings(defaults: defaults)
        #expect(settings.usageHeatmapMode == previousMode)

        settings.setUsageHeatmapMode(mode)
        #expect(settings.usageHeatmapMode == mode)
        #expect(defaults.string(forKey: "MainPanel.usageHeatmapMode") == mode.rawValue)
        let restoredDefaults = try #require(UserDefaults(suiteName: preferences.suite))
        #expect(MainPanelSettings(defaults: restoredDefaults).usageHeatmapMode == mode)

        defaults.set(previousMode.rawValue, forKey: "MainPanel.usageHeatmapMode")
        settings.refresh()
        #expect(settings.usageHeatmapMode == previousMode)
    }

    @Test func usageHeatmapModeDefaultsToDailyForMissingOrUnknownPreference() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        #expect(MainPanelSettings(defaults: defaults).usageHeatmapMode == .daily)

        defaults.set("unknown", forKey: "MainPanel.usageHeatmapMode")
        let settings = MainPanelSettings(defaults: defaults)
        #expect(settings.usageHeatmapMode == .daily)
        #expect(defaults.string(forKey: "MainPanel.usageHeatmapMode") == "unknown")
        settings.setUsageHeatmapMode(.weekly)
        defaults.removeObject(forKey: "MainPanel.usageHeatmapMode")
        settings.refresh()
        #expect(settings.usageHeatmapMode == .daily)
    }

    @Test func rebuildRangeIncludesDatesWithoutActivityEvents() {
        let range = RebuildDateRange.starting(at: "2026-09-15").completing(with: "2026-09-17")
        #expect(range.dateKeys == ["2026-09-15", "2026-09-16", "2026-09-17"])
        #expect(RebuildDateRange.starting(at: "2026-09-15").dateKeys.isEmpty)
        #expect(RebuildDateRange.starting(at: "2026-09-15").completing(with: "2026-09-15").dateKeys == ["2026-09-15"])
    }

    @Test func autoResetDefaultsOffAndRepairsInvalidLeadTime() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        let initial = AutoResetSettings(defaults: defaults)
        #expect(!initial.isEnabled)
        #expect(initial.leadTime == .thirtyMinutes)
        defaults.set(123, forKey: "AutoReset.leadTimeSeconds")
        let repaired = AutoResetSettings(defaults: defaults)
        #expect(repaired.leadTime == .thirtyMinutes)
        #expect(defaults.integer(forKey: "AutoReset.leadTimeSeconds") == 1800)
        repaired.setEnabled(true)
        repaired.setLeadTime(.sixHours)
        initial.refresh()
        #expect(initial.isEnabled)
        #expect(initial.leadTime == .sixHours)
    }

    @Test func layoutRepairsDuplicateOrderAndAlwaysKeepsAVisibleSection() {
        let layout = MainPanelLayout(orderedSections: [.usage, .usage, .activity], hiddenSections: Set(MainPanelSection.allCases))
        #expect(layout.orderedSections == [.usage, .activity, .account, .quota, .serviceStatus, .status])
        #expect(layout.visibleSections == [.usage])
        let activityOnly = MainPanelLayout(orderedSections: [.activity], hiddenSections: Set(MainPanelSection.allCases).subtracting([.activity]))
        #expect(activityOnly.visibleSections == [.activity])
    }

    @Test func taskVisibilityFollowsLayoutPreferenceAndSupportsUndo() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MainPanelSettings(defaults: preferences.defaults)
        #expect(settings.layout.isVisible(.activity))
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        settings.setSection(.activity, isVisible: false, undoManager: undo)
        undo.endUndoGrouping()
        let restored = MainPanelSettings(defaults: preferences.defaults)
        #expect(!restored.layout.isVisible(.activity))
        settings.refresh()
        #expect(!settings.layout.isVisible(.activity))
        undo.beginUndoGrouping()
        settings.setSection(.activity, isVisible: true, undoManager: undo)
        undo.endUndoGrouping()
        #expect(settings.layout.isVisible(.activity))
        undo.undo()
        #expect(!settings.layout.isVisible(.activity))
    }

    @Test func serviceStatusAppendsToExistingLayoutAndPreservesPreferences() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let previousOrder = ["usage", "account", "status", "quota", "activity"]
        preferences.defaults.set(previousOrder, forKey: "MainPanel.sectionOrder")
        preferences.defaults.set(["quota", "activity"], forKey: "MainPanel.hiddenSections")
        let settings = MainPanelSettings(defaults: preferences.defaults)
        #expect(settings.layout.orderedSections.map(\.rawValue) == previousOrder + ["serviceStatus"])
        #expect(settings.layout.hiddenSections == [.quota, .activity])
        #expect(settings.layout.isVisible(.serviceStatus))

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        settings.setSectionOrder([.serviceStatus] + settings.layout.orderedSections, undoManager: undo)
        settings.setSection(.serviceStatus, isVisible: false, undoManager: undo)
        undo.endUndoGrouping()
        let restored = MainPanelSettings(defaults: preferences.defaults)
        #expect(restored.layout.orderedSections.first == .serviceStatus)
        #expect(restored.layout.hiddenSections == [.quota, .activity, .serviceStatus])
        undo.undo()
        #expect(settings.layout.orderedSections.last == .serviceStatus)
        #expect(settings.layout.isVisible(.serviceStatus))
    }
}
