import Foundation
import Testing

struct MainPanelSettingsTests {
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
