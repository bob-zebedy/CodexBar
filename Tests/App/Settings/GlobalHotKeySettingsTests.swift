import Carbon.HIToolbox
import Combine
import Testing

struct GlobalHotKeySettingsTests {
    @Test func registrationFailurePreservesPublishedAndStoredShortcut() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = GlobalHotKeySettings(defaults: preferences.defaults)
        let previous = settings.shortcut
        let replacement = GlobalHotKeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "R")
        var active = previous
        settings.configureRegistration { shortcut in
            if shortcut == replacement {
                return "conflict"
            }
            active = shortcut
            return nil
        }
        settings.setShortcut(replacement)
        #expect(settings.shortcut == previous)
        #expect(active == previous)
        #expect(settings.errorMessage == "conflict")
        #expect(GlobalHotKeySettings(defaults: preferences.defaults).shortcut == previous)
    }

    @Test func successfulRegistrationPrecedesPublicationAndPersists() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = GlobalHotKeySettings(defaults: preferences.defaults)
        let replacement = GlobalHotKeyShortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "R")
        var active = settings.shortcut
        settings.configureRegistration { shortcut in
            active = shortcut
            return nil
        }
        let observer = settings.$shortcut.sink { shortcut in
            #expect(active == shortcut)
        }
        defer { observer.cancel() }
        settings.setShortcut(replacement)
        #expect(settings.shortcut == replacement)
        #expect(GlobalHotKeySettings(defaults: preferences.defaults).shortcut == replacement)
        settings.clearShortcut()
        #expect(active == nil)
        #expect(GlobalHotKeySettings(defaults: preferences.defaults).shortcut == nil)
        settings.restoreDefaultShortcut()
        #expect(active == .default)
        #expect(GlobalHotKeySettings(defaults: preferences.defaults).shortcut == .default)
    }

    @Test func startupConflictPreservesPreferenceAndError() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = GlobalHotKeySettings(defaults: preferences.defaults)
        settings.configureRegistration { _ in "conflict" }
        #expect(settings.shortcut == .default)
        #expect(settings.errorMessage == "conflict")
        #expect(GlobalHotKeySettings(defaults: preferences.defaults).shortcut == .default)
    }
}
