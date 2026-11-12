import AppKit
import SwiftUI

struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarLifecycle.self) private var appLifecycle

    init() {
        // 缩短系统工具提示首次出现的延迟 (毫秒)
        UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")
    }

    var body: some Scene {
        // 菜单栏 UI 由 CodexBarLifecycle 驱动; 系统设置命令转交给自定义设置窗口
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("app.command.settings") {
                    appLifecycle.openSettingsFromCommand()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
