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

    @Test func manualOriginIsConsumedOnceAndNeverPersisted() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = AppearanceSettings(defaults: preferences.defaults)
        let origin = AppearanceSettings.TransitionOrigin(screenPoint: CGPoint(x: 480, y: 360))

        settings.setTheme(.dark, from: origin)
        #expect(settings.takeTransitionOrigin()?.screenPoint == origin.screenPoint)
        #expect(settings.takeTransitionOrigin() == nil)
        #expect(AppearanceSettings(defaults: preferences.defaults).takeTransitionOrigin() == nil)

        settings.setTheme(.dark, from: origin)
        #expect(settings.takeTransitionOrigin() == nil)
    }

    @Test func latestThemeChangeDeterminesOriginBeforeDeferredApplication() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = AppearanceSettings(defaults: preferences.defaults)
        let firstOrigin = AppearanceSettings.TransitionOrigin(screenPoint: CGPoint(x: 480, y: 360))
        let lastOrigin = AppearanceSettings.TransitionOrigin(screenPoint: CGPoint(x: 720, y: 420))

        settings.setTheme(.light, from: firstOrigin)
        settings.setTheme(.dark, from: lastOrigin)
        settings.refresh()
        #expect(settings.takeTransitionOrigin()?.screenPoint == lastOrigin.screenPoint)

        settings.setTheme(.light, from: firstOrigin)
        settings.setTheme(.dark)
        #expect(settings.takeTransitionOrigin() == nil)

        settings.setTheme(.light, from: firstOrigin)
        settings.setTheme(.dark, from: lastOrigin)
        preferences.defaults.set("light", forKey: "Appearance.theme")
        settings.refresh()
        #expect(settings.theme == .light)
        #expect(settings.takeTransitionOrigin() == nil)
    }
}
