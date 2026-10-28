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
}
