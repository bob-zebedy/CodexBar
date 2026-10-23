import AppKit
import Darwin
import os
import SwiftUI

// 测试时禁用应用入口
#if !CODEXBAR_TESTING
    @main
#endif
nonisolated enum CodexBarMain {
    static func main() {
        do {
            // 在 SwiftUI 创建 AppDelegate 前互斥, 避免重复实例初始化服务
            guard let descriptor = try JSONFileStorage.acquireLock(
                at: AppStorage().lockURL(.appInstance), nonblocking: true
            ) else { return }
            defer { JSONFileStorage.releaseLock(descriptor) }

            // 同步进程入口位于主线程, 取得锁后才进入 SwiftUI 生命周期
            MainActor.assumeIsolated {
                CodexBarApp.main()
            }
        } catch {
            AppLog.app.error("App 实例锁获取失败")
            exit(EXIT_FAILURE)
        }
    }
}

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

    /// `v1.2.3` 形式的版本文案; 缺失时回退 `--`
    var displayVersionLabel: String {
        guard let version = shortVersionString else { return "--" }
        return "v\(version)"
    }
}
