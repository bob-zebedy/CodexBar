//
//  CodexBarApp.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import AppKit
import SwiftUI

@main
struct CodexBarApp: App {
    @NSApplicationDelegateAdaptor(CodexBarAppDelegate.self) private var appDelegate

    var body: some Scene {
        // 实际 UI 由 CodexBarAppDelegate 的 StatusItemController 驱动
        // App 仅需声明一个占位 Scene 设置窗口走右键菜单的 makeSettingsWindow
        Settings {
            EmptyView()
        }
    }
}

nonisolated extension Bundle {
    var shortVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `v1.2.3` 形式的版本文案,缺失时回退 `--`(不带 v 前缀)
    var displayVersionLabel: String {
        guard let version = shortVersionString else { return "--" }
        return "v\(version)"
    }
}
