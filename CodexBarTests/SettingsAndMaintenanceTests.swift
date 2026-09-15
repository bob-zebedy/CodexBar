import Foundation
import Testing

struct SettingsAndMaintenanceTests {
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

    @Test func activityProtectionFallsBackToOneHourAndReloadsChanges() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set("invalid", forKey: "KeepAlive.abnormalTaskInactivitySeconds")
        let settings = ActivityProtectionSettings(defaults: preferences.defaults)
        #expect(settings.inactivityDuration == .oneHour)
        settings.setInactivityDuration(.thirtyMinutes)
        #expect(ActivityProtectionSettings(defaults: preferences.defaults).inactivityDuration == .thirtyMinutes)
        preferences.defaults.set(7200, forKey: "KeepAlive.abnormalTaskInactivitySeconds")
        settings.refresh()
        #expect(settings.inactivityDuration == .twoHours)
    }

    @Test func disabledProxyCanStoreInvalidDraftAndUnauthenticatedPasswordIsDiscarded() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let configuration = CodexProxyConfiguration(host: "invalid/address", port: "")
        try CodexProxyStore.save(configuration, password: "unused-secret", to: preferences.defaults)
        let loaded = try CodexProxyStore.load(from: preferences.defaults)
        let stored = try #require(loaded)
        #expect(stored.configuration == configuration)
        #expect(stored.password.isEmpty)
        try CodexProxyStore.save(nil, password: "", to: preferences.defaults)
        #expect(!CodexProxyStore.containsConfiguration(in: preferences.defaults))
    }

    @Test func invalidEnabledProxyDoesNotOverwriteLastSavedConfiguration() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let valid = CodexProxyConfiguration(isEnabled: true, host: "localhost", port: "8080")
        try CodexProxyStore.save(valid, password: "", to: preferences.defaults)
        #expect(throws: (any Error).self) {
            try CodexProxyStore.save(CodexProxyConfiguration(isEnabled: true), password: "", to: preferences.defaults)
        }
        #expect(try CodexProxyStore.load(from: preferences.defaults)?.configuration == valid)
    }

    @Test func corruptStoredProxyIsReportedInsteadOfTreatedAsMissing() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set("broken", forKey: "CodexProxy.configuration")
        #expect(CodexProxyStore.containsConfiguration(in: preferences.defaults))
        #expect(throws: (any Error).self) { try CodexProxyStore.load(from: preferences.defaults) }
    }

    @Test func layoutRepairsDuplicateOrderAndAlwaysKeepsAVisibleSection() {
        let layout = MainPanelLayout(orderedSections: [.usage, .usage, .activity], hiddenSections: Set(MainPanelSection.allCases))
        #expect(layout.orderedSections == [.usage, .activity, .account, .quota, .status])
        #expect(layout.visibleSections == [.usage])
        let activityOnly = MainPanelLayout(orderedSections: [.activity], hiddenSections: Set(MainPanelSection.allCases).subtracting([.activity]))
        #expect(activityOnly.disablingActivitySection().visibleSections == [.account])
    }

    @Test func hookDisableHidesActivityAndExplicitReenableRestoresIt() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MainPanelSettings(defaults: preferences.defaults)
        settings.updateHookEnabled(false)
        #expect(!settings.layout.isVisible(.activity))
        settings.updateHookEnabled(true)
        #expect(settings.layout.isVisible(.activity))
        let undo = UndoManager()
        settings.setSection(.activity, isVisible: false, undoManager: undo)
        let restored = MainPanelSettings(defaults: preferences.defaults)
        restored.updateHookEnabled(true)
        #expect(!restored.layout.isVisible(.activity))
    }

    @Test func legacyMaintenanceStateRequiresRebuildAndNormalizesDateQueues() throws {
        let state = try TestFixtures.decode(WorkflowMaintenanceState.self, #"{"pending":["2026-09-15","invalid","2026-09-14","2026-09-15"],"dirty":["2026-02-30","2026-09-14"]}"#)
        #expect(state.schema == 0)
        #expect(state.pending == ["2026-09-14", "2026-09-15"])
        #expect(state.dirty == ["2026-09-14"])
    }

    @Test func fileReplacementResetsOffsetsHashesAndMarksDayDirty() throws {
        let date = "2026-09-15"
        var state = WorkflowMaintenanceState(days: [date: WorkflowDayMaintenanceState(
            offset: 50, size: 60, corrupt: 2, sourceGeneration: "old", sourceIsFresh: false,
            fileIdentifier: 1, boundaryHash: "old-hash", boundaryVerifiedAtNanoseconds: 42
        )])
        state.startNewSourceGeneration(for: date, isFresh: true, fileIdentifier: 2)
        let day = try #require(state.days[date])
        #expect(day.offset == 0)
        #expect(day.corrupt == 0)
        #expect(day.sourceGeneration != "old")
        #expect(day.sourceIsFresh)
        #expect(day.fileIdentifier == 2)
        #expect(day.boundaryHash == nil)
        #expect(day.boundaryVerifiedAtNanoseconds == nil)
        #expect(state.dirty == [date])
    }

    @Test func repeatedPendingAndSourceUpdatesAreIdempotent() throws {
        var state = WorkflowMaintenanceState()
        let firstPending = state.markPending("2026-09-15")
        let secondPending = state.markPending("2026-09-15")
        #expect(firstPending)
        #expect(!secondPending)
        let firstSource = state.ensureSourceGeneration(for: "2026-09-15", fileIdentifier: 1)
        let generation = try #require(state.days["2026-09-15"]?.sourceGeneration)
        let secondSource = state.ensureSourceGeneration(for: "2026-09-15", fileIdentifier: 1)
        #expect(firstSource)
        #expect(!secondSource)
        #expect(state.days["2026-09-15"]?.sourceGeneration == generation)
        #expect(state.days["2026-09-15"]?.sourceIsFresh == false)
    }
}
