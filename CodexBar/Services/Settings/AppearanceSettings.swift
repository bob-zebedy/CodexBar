import AppKit
import Combine

@MainActor
final class AppearanceSettings: ObservableObject {
    @Published private(set) var theme: Theme

    private let defaults: UserDefaults
    private static let themeKey = "Appearance.theme"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Self.loadTheme(from: defaults)
    }

    func setTheme(_ theme: Theme) {
        guard theme != self.theme else { return }
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        self.theme = theme
    }

    func refresh() {
        let theme = Self.loadTheme(from: defaults)
        if theme != self.theme {
            self.theme = theme
        }
    }

    private static func loadTheme(from defaults: UserDefaults) -> Theme {
        defaults.string(forKey: themeKey).flatMap(Theme.init(rawValue:)) ?? .system
    }

    enum Theme: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: String(localized: "settings.appearance.theme.system")
            case .light: String(localized: "settings.appearance.theme.light")
            case .dark: String(localized: "settings.appearance.theme.dark")
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }
}
