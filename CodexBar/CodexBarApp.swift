//
//  CodexBarApp.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import SwiftUI

@main
struct CodexBarApp: App {
    @StateObject private var viewModel = RateLimitsViewModel()
    @StateObject private var appUpdater = AppUpdater()
    
    var body: some Scene {
        MenuBarExtra {
            RateLimitsMenuView(viewModel: viewModel)
                .frame(width: RateLimitsMenuView.menuWidth)
                .environmentObject(appUpdater)
        } label: {
            MenuBarStatusView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}

nonisolated extension Bundle {
    var shortVersionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
