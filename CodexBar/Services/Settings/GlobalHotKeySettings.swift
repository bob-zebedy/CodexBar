import Combine
import Foundation

@MainActor
final class GlobalHotKeySettings: ObservableObject {
    @Published private(set) var shortcut: GlobalHotKeyShortcut?
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.shortcut = Self.loadShortcut(from: defaults)
    }

    func setShortcut(_ shortcut: GlobalHotKeyShortcut) {
        if let validationError = shortcut.validationError {
            errorMessage = validationError
            return
        }

        self.shortcut = shortcut
        saveShortcut(shortcut)
        errorMessage = nil
    }

    func clearShortcut() {
        shortcut = nil
        saveShortcut(nil)
        errorMessage = nil
    }

    func restoreDefaultShortcut() {
        setShortcut(.default)
    }

    func setRegistrationError(_ message: String) {
        errorMessage = message
    }

    func restoreShortcut(_ shortcut: GlobalHotKeyShortcut?, message: String) {
        self.shortcut = shortcut
        saveShortcut(shortcut)
        errorMessage = message
    }

    func clearError() {
        errorMessage = nil
    }

    private func saveShortcut(_ shortcut: GlobalHotKeyShortcut?) {
        if let shortcut, let data = try? encoder.encode(shortcut) {
            defaults.set(true, forKey: Keys.isEnabled)
            defaults.set(data, forKey: Keys.shortcut)
        } else {
            defaults.set(false, forKey: Keys.isEnabled)
            defaults.removeObject(forKey: Keys.shortcut)
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> GlobalHotKeyShortcut? {
        let hasEnabledValue = defaults.object(forKey: Keys.isEnabled) != nil
        guard !hasEnabledValue || defaults.bool(forKey: Keys.isEnabled) else {
            return nil
        }

        if let data = defaults.data(forKey: Keys.shortcut),
           let shortcut = try? JSONDecoder().decode(GlobalHotKeyShortcut.self, from: data) {
            return shortcut
        }

        return .default
    }

    private enum Keys {
        static let isEnabled = "GlobalHotKey.isEnabled"
        static let shortcut = "GlobalHotKey.shortcut"
    }
}
