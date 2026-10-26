import AppKit
import Combine

@MainActor
final class AppearanceSettings: ObservableObject {
    @Published private(set) var theme: Theme
    private var transitionOrigin: TransitionOrigin?

    private let defaults: UserDefaults
    private static let themeKey = "Appearance.theme"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = Self.loadTheme(from: defaults)
    }

    func setTheme(_ theme: Theme, from origin: TransitionOrigin? = nil) {
        guard theme != self.theme else { return }
        defaults.set(theme.rawValue, forKey: Self.themeKey)
        transitionOrigin = origin
        self.theme = theme
    }

    func takeTransitionOrigin() -> TransitionOrigin? {
        defer { transitionOrigin = nil }
        return transitionOrigin
    }

    func refresh() {
        let theme = Self.loadTheme(from: defaults)
        if theme != self.theme {
            transitionOrigin = nil
            self.theme = theme
        }
    }

    private static func loadTheme(from defaults: UserDefaults) -> Theme {
        defaults.string(forKey: themeKey).flatMap(Theme.init(rawValue:)) ?? .system
    }

    struct TransitionOrigin {
        let screenPoint: CGPoint
        weak var window: NSWindow?
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
