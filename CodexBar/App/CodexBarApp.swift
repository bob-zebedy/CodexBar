import AppKit
import SwiftUI

struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarAppDelegate.self) private var appDelegate

    init() {
        // 缩短系统工具提示首次出现的延迟 (毫秒)
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        // 菜单栏 UI 由 AppDelegate 驱动; 系统设置命令转交给自定义设置窗口
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("app.command.settings") {
                    appDelegate.openSettingsFromCommand()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

nonisolated extension Bundle {
    var shortVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 版本文案包含构建号; 版本缺失时回退 `--`
    var displayVersionLabel: String {
        guard let version = shortVersionString else { return "--" }
        let label = "v\(version)"
        guard let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty else { return label }
        return "\(label) (Build \(build))"
    }
}
