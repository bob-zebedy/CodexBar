import AppKit
import Darwin
import SwiftUI

/// 应用入口; Hook 子进程模式会在初始化阶段记录事件并退出
@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarAppDelegate.self) private var appDelegate

    init() {
        if WorkflowHookEventRecorder.handleIfRequested() {
            exit(EXIT_SUCCESS)
        }
    }

    var body: some Scene {
        // 菜单栏 UI 由 AppDelegate 驱动; 空 Settings scene 仅用于保留系统设置入口
        Settings {
            EmptyView()
        }
    }
}

nonisolated extension Bundle {
    var shortVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// ` v1.2.3` 形式的版本文案; 缺失时回退 `--`
    var displayVersionLabel: String {
        guard let version = shortVersionString else { return "--" }
        return "v\(version)"
    }
}
