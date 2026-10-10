import Combine
import Foundation
import os

/// 全局快捷键偏好设置, 注册成功后发布并持久化
@MainActor
final class GlobalHotKeySettings: ObservableObject {
    @Published private(set) var shortcut: GlobalHotKeyShortcut?
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private var registrationHandler: ((GlobalHotKeyShortcut?) -> String?)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = Self.loadShortcut(from: defaults)
    }

    func setShortcut(_ shortcut: GlobalHotKeyShortcut) {
        if let validationError = shortcut.validationError {
            errorMessage = validationError
            return
        }

        if let message = registrationHandler?(shortcut) {
            errorMessage = message
            return
        }

        AppLog.settings.notice("快捷键已设置")
        self.shortcut = shortcut
        saveShortcut(shortcut)
        errorMessage = nil
    }

    func clearShortcut() {
        if let message = registrationHandler?(nil) {
            errorMessage = message
            return
        }
        AppLog.settings.notice("快捷键已清除")
        shortcut = nil
        saveShortcut(nil)
        errorMessage = nil
    }

    func restoreDefaultShortcut() {
        setShortcut(.default)
    }

    /// 只设用户可见文案, 不记日志
    /// 按键解析失败时尚未发起注册, 不记为注册失败
    func setRegistrationError(_ message: String) {
        errorMessage = message
    }

    func configureRegistration(_ handler: ((GlobalHotKeyShortcut?) -> String?)?) {
        registrationHandler = handler
        // 启动注册失败只提示错误, 不覆盖用户保存的快捷键
        errorMessage = handler?(shortcut)
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
