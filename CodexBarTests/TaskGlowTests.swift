import AppKit
import Testing

struct TaskGlowTests {
    @Test(arguments: ["#", " ", "\t\n", "中文", "😀", "éß１２", "!@#$%^&*()"])
    func nonAlphanumericInputPreservesSelectedColor(_ input: String) {
        let formatter = TaskGlowHexFormatter()
        let original = "123456"
        let selectedRange = NSRange(location: 2, length: 2)
        var proposed = (original as NSString).replacingCharacters(in: selectedRange, with: input) as NSString
        var proposedRange = NSRange(location: 2 + (input as NSString).length, length: 0)
        #expect(!formatter.isPartialStringValid(
            &proposed,
            proposedSelectedRange: &proposedRange,
            originalString: original,
            originalSelectedRange: selectedRange,
            errorDescription: nil
        ))
        #expect(proposed as String == original)
        #expect(proposedRange == selectedRange)
    }

    @Test func pastedColorFiltersNonAlphanumericCharactersBeforeApplyingLengthLimit() {
        let formatter = TaskGlowHexFormatter()
        var proposed: NSString = " #a b-1😀2\t中e_f!78 "
        var proposedRange = NSRange(location: proposed.length, length: 0)
        #expect(!formatter.isPartialStringValid(
            &proposed,
            proposedSelectedRange: &proposedRange,
            originalString: "",
            originalSelectedRange: NSRange(location: 0, length: 0),
            errorDescription: nil
        ))
        #expect(proposed as String == "AB12EF")
        #expect(proposedRange == NSRange(location: 6, length: 0))
    }

    @Test(arguments: [0, 2, 6])
    func repeatedOverflowPreservesColorAndSelection(_ cursor: Int) {
        let formatter = TaskGlowHexFormatter()
        let original = "123456"
        let originalRange = NSRange(location: cursor, length: 0)
        for _ in 0 ..< 100 {
            var proposed = (original as NSString).replacingCharacters(in: originalRange, with: "a") as NSString
            var proposedRange = NSRange(location: cursor + 1, length: 0)
            let accepted = formatter.isPartialStringValid(
                &proposed,
                proposedSelectedRange: &proposedRange,
                originalString: original,
                originalSelectedRange: originalRange,
                errorDescription: nil
            )
            #expect(!accepted)
            #expect(proposed as String == original)
            #expect(proposedRange == originalRange)
        }
    }

    @Test func colorFormatterLimitsReplacementWithoutChangingSurroundingText() {
        let formatter = TaskGlowHexFormatter()
        var proposed: NSString = "12abcdef56"
        var proposedRange = NSRange(location: 8, length: 0)
        #expect(!formatter.isPartialStringValid(
            &proposed,
            proposedSelectedRange: &proposedRange,
            originalString: "123456",
            originalSelectedRange: NSRange(location: 2, length: 2),
            errorDescription: nil
        ))
        #expect(proposed as String == "12AB56")
        #expect(proposedRange == NSRange(location: 4, length: 0))
    }

    @Test func colorStoragePreservesDisplayP3Components() throws {
        let color = NSColor(displayP3Red: 128.0 / 255, green: 1, blue: 0, alpha: 1)
        let hex = try #require(TaskGlowAppearance.encodeColor(color))
        #expect(hex == "80FF00")
        let restored = try #require(TaskGlowAppearance.decodeColor(hex))
        #expect(restored.colorSpace == .displayP3)
        #expect(abs(restored.redComponent - color.redComponent) < 0.0001)
        #expect(restored.greenComponent == 1)
        #expect(restored.blueComponent == 0)
    }

    @Test func existingEnabledPreferenceKeepsOriginalAppearance() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "TaskGlow.isEnabled")
        let settings = TaskGlowSettings(defaults: preferences.defaults)
        #expect(settings.isEnabled)
        #expect(settings.appearance == TaskGlowAppearance())
        #expect(settings.appearance.color(for: .running) == .systemCyan)
        #expect(settings.appearance.color(for: .waiting) == .systemOrange)
        #expect(settings.appearance.color(for: .completed) == .systemGreen)
        #expect(settings.appearance.color(for: .terminated) == .systemRed)
    }

    @Test func appearancePersistsAndRefreshesWithoutChangingEnabledPreference() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = TaskGlowSettings(defaults: preferences.defaults)
        let observer = TaskGlowSettings(defaults: preferences.defaults)
        for (role, hex) in zip(TaskGlowColorRole.allCases, ["123456", "ABCDEF", "00FF00", "FF0000"]) {
            settings.setColorHex(hex, for: role)
            #expect(settings.appearance.colors[role] == hex)
        }
        settings.setAnimationSpeed(.slow)
        settings.setTerminalDuration(15)
        settings.setBrightness(0.45)
        observer.refresh()
        #expect(observer.appearance == settings.appearance)
        #expect(TaskGlowSettings(defaults: preferences.defaults).appearance == settings.appearance)
        #expect(!observer.isEnabled)
        #expect(preferences.defaults.object(forKey: "TaskGlow.isEnabled") == nil)
    }

    @Test func hexInputNormalizesValidColorsAndPreservesSavedColorWhileEditing() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = TaskGlowSettings(defaults: preferences.defaults)
        settings.setColorHex("  #ab12ef\n", for: .running)
        #expect(settings.appearance.colors[.running] == "AB12EF")
        #expect(preferences.defaults.string(forKey: "TaskGlow.color.running") == "AB12EF")
        for invalid in ["#", "#abc", "12345", "1234567", "#12345678", "GGGGGG", "##123456", "12 3456"] {
            settings.setColorHex(invalid, for: .running)
            #expect(settings.appearance.colors[.running] == "AB12EF")
            #expect(preferences.defaults.string(forKey: "TaskGlow.color.running") == "AB12EF")
        }
        settings.setColorHex("12abef", for: .running)
        #expect(TaskGlowSettings(defaults: preferences.defaults).appearance.colors[.running] == "12ABEF")
        settings.setColorHex(" \n", for: .running)
        #expect(settings.appearance.colors[.running] == nil)
        #expect(preferences.defaults.object(forKey: "TaskGlow.color.running") == nil)
        #expect(TaskGlowSettings(defaults: preferences.defaults).appearance.color(for: .running) == .systemCyan)
    }

    @Test func invalidAppearanceValuesFallBackAndInvalidWritesAreIgnored() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set("invalid", forKey: "TaskGlow.color.running")
        preferences.defaults.set("FFFFFFF", forKey: "TaskGlow.color.waiting")
        preferences.defaults.set("future", forKey: "TaskGlow.animationSpeed")
        preferences.defaults.set(-2, forKey: "TaskGlow.terminalDuration")
        preferences.defaults.set(4, forKey: "TaskGlow.brightness")
        let settings = TaskGlowSettings(defaults: preferences.defaults)
        #expect(settings.appearance == TaskGlowAppearance())
        settings.setTerminalDuration(.infinity)
        settings.setTerminalDuration(0)
        settings.setBrightness(.nan)
        #expect(settings.appearance == TaskGlowAppearance())
        settings.setBrightness(-1)
        #expect(settings.appearance.brightness == 0.2)
        settings.setBrightness(2)
        #expect(settings.appearance.brightness == 1)
        #expect(TaskGlowAppearance.decodeColor("-12345") == nil)
        #expect(TaskGlowAppearance.decodeColor("GGGGGG") == nil)
    }

    @Test(arguments: TaskGlowSettings.terminalDurationOptions)
    func terminalDurationOnlyChangesGlowExpiration(_ duration: TimeInterval) {
        let snapshot = completedSnapshot()
        var presentation = TaskGlowPresentationState()
        presentation.update(snapshot: snapshot, terminalEvents: [], isEnabled: true, acceptsBriefEvents: true, now: TestFixtures.now)
        presentation.refresh(now: TestFixtures.now, terminalDuration: duration)
        #expect(presentation.state == .completed)
        #expect(presentation.terminal?.expiresAt == TestFixtures.now.addingTimeInterval(duration))
        #expect(snapshot.statusItemActivityExpiration == TestFixtures.now.addingTimeInterval(10))
        presentation.refresh(now: TestFixtures.now.addingTimeInterval(duration), terminalDuration: duration)
        #expect(presentation.state == .hidden)
        #expect(presentation.terminal == nil)
    }

    @Test func changingDurationPreservesEntranceAndWakeDoesNotReplayExpiredGlow() {
        var presentation = TaskGlowPresentationState()
        presentation.update(snapshot: completedSnapshot(), terminalEvents: [], isEnabled: true, acceptsBriefEvents: true, now: TestFixtures.now)
        presentation.refresh(now: TestFixtures.now, terminalDuration: 10)
        presentation.refresh(now: TestFixtures.now.addingTimeInterval(2), terminalDuration: 15)
        #expect(presentation.terminal?.startedAt == TestFixtures.now)
        #expect(presentation.terminal?.expiresAt == TestFixtures.now.addingTimeInterval(15))
        presentation.refresh(now: TestFixtures.now.addingTimeInterval(16), terminalDuration: 15)
        #expect(presentation.state == .hidden)
    }

    @Test func repeatedTerminalRefreshPreservesPresentationAndNewEventRestartsEntrance() throws {
        let snapshot = completedSnapshot()
        var presentation = TaskGlowPresentationState()
        presentation.update(snapshot: snapshot, terminalEvents: [], isEnabled: true, acceptsBriefEvents: true, now: TestFixtures.now)
        presentation.refresh(now: TestFixtures.now, terminalDuration: 10)
        let original = try #require(presentation.terminal)
        presentation.refresh(now: TestFixtures.now.addingTimeInterval(2), terminalDuration: 10)
        #expect(presentation.terminal == original)

        let nextSnapshot = completedSnapshot()
        let nextPresentationTime = TestFixtures.now.addingTimeInterval(3)
        presentation.update(snapshot: nextSnapshot, terminalEvents: [], isEnabled: true, acceptsBriefEvents: true, now: nextPresentationTime)
        presentation.refresh(now: nextPresentationTime, terminalDuration: 10)
        #expect(presentation.terminal?.eventID == nextSnapshot.latestTerminalEvent?.id)
        #expect(presentation.terminal?.eventID != original.eventID)
        #expect(presentation.terminal?.startedAt == nextPresentationTime)
    }

    @Test func concurrentTaskCompletionStillShowsBrieflyThenRestoresRunning() throws {
        var presentation = TaskGlowPresentationState()
        let running = CodexActivityTaskSnapshot(
            id: UUID(), isAnonymous: false, latestEvent: .toolStarted, projectName: nil,
            modelName: nil, effort: nil, toolName: nil, startedAt: TestFixtures.now,
            stateChangedAt: TestFixtures.now, showsPreciseDuration: true, activeSubagentCount: nil
        )
        let snapshot = CodexActivitySnapshot(
            waitingTasks: [], runningTasks: [running],
            recentCompletions: completedSnapshot().recentCompletions, recentTerminations: []
        )
        presentation.update(snapshot: snapshot, terminalEvents: [], isEnabled: true, acceptsBriefEvents: true, now: TestFixtures.now)
        try presentation.update(
            snapshot: snapshot, terminalEvents: [#require(snapshot.latestTerminalEvent)],
            isEnabled: true, acceptsBriefEvents: true, now: TestFixtures.now
        )
        presentation.refresh(now: TestFixtures.now, terminalDuration: 15)
        #expect(presentation.state == .completed)
        #expect(presentation.terminal?.expiresAt == TestFixtures.now.addingTimeInterval(3))
        presentation.refresh(now: TestFixtures.now.addingTimeInterval(3), terminalDuration: 15)
        #expect(presentation.state == .running)
    }

    private func completedSnapshot() -> CodexActivitySnapshot {
        let completion = CodexActivityCompletion(
            id: UUID(), isAnonymous: false, projectName: nil, modelName: nil,
            effort: nil, completedAt: TestFixtures.now, duration: 60
        )
        return CodexActivitySnapshot(waitingTasks: [], runningTasks: [], recentCompletions: [completion], recentTerminations: [])
    }
}
