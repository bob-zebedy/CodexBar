import AppKit
import Combine
import Testing

struct AppearanceSettingsTests {
    @Test func missingOrInvalidPreferenceFollowsSystem() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        #expect(AppearanceSettings(defaults: preferences.defaults).theme == .system)

        preferences.defaults.set("unknown", forKey: "Appearance.theme")
        #expect(AppearanceSettings(defaults: preferences.defaults).theme == .system)
        preferences.defaults.set(7, forKey: "Appearance.theme")
        #expect(AppearanceSettings(defaults: preferences.defaults).theme == .system)
    }

    @Test func selectionPersistsAndPublishesOnlyChanges() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = AppearanceSettings(defaults: preferences.defaults)
        var published = [AppearanceSettings.Theme]()
        let observer = settings.$theme.sink { published.append($0) }
        defer { observer.cancel() }

        for theme in [AppearanceSettings.Theme.dark, .light, .system] {
            settings.setTheme(theme)
            settings.setTheme(theme)
            #expect(AppearanceSettings(defaults: preferences.defaults).theme == theme)
        }
        #expect(published == [.system, .dark, .light, .system])
    }

    @Test func refreshReloadsPreferenceAndRestoresSystemWhenRemoved() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = AppearanceSettings(defaults: preferences.defaults)
        preferences.defaults.set("dark", forKey: "Appearance.theme")
        settings.refresh()
        #expect(settings.theme == .dark)

        preferences.defaults.removeObject(forKey: "Appearance.theme")
        settings.refresh()
        #expect(settings.theme == .system)
    }

    @Test func appearanceMatchesSelectionAndSystemRemovesOverride() {
        #expect(AppearanceSettings.Theme.system.appearance == nil)
        #expect(AppearanceSettings.Theme.light.appearance?.name == .aqua)
        #expect(AppearanceSettings.Theme.dark.appearance?.name == .darkAqua)
    }
}
