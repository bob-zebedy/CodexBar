import Combine
import Foundation
import os

/// 全局快捷键偏好设置, 负责持久化和注册失败后的 UI 回滚
@MainActor
final class GlobalHotKeySettings: ObservableObject {
    @Published private(set) var shortcut: GlobalHotKeyShortcut?
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = Self.loadShortcut(from: defaults)
    }

    func setShortcut(_ shortcut: GlobalHotKeyShortcut) {
        if let validationError = shortcut.validationError {
            errorMessage = validationError
            return
        }

        AppLog.settings.notice("快捷键已设置")
        self.shortcut = shortcut
        saveShortcut(shortcut)
        errorMessage = nil
    }

    func clearShortcut() {
        AppLog.settings.notice("快捷键已清除")
        shortcut = nil
        saveShortcut(nil)
        errorMessage = nil
    }

    func restoreDefaultShortcut() {
        setShortcut(.default)
    }

    /// 只设用户可见文案, 不记日志
    /// 注册失败由 GlobalHotKeyController 记且带 code=, 这里再记一条会把一次冲突算成两次
    /// 另一个调用方是录制时的按键解析失败, 那次根本没发起注册, 记成 stage=register 更是误导
    func setRegistrationError(_ message: String) {
        errorMessage = message
    }

    /// 参数不可为空: 传 nil 会经 saveShortcut 清空用户保存的配置
    /// 没有可回退的快捷键时应改用 setRegistrationError
    func restoreShortcut(_ shortcut: GlobalHotKeyShortcut, message: String) {
        AppLog.settings.notice("快捷键已回退: reason=occupied")
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
