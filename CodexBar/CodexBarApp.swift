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
    
    var body: some Scene {
        MenuBarExtra {
            RateLimitsMenuView(viewModel: viewModel)
                .frame(width: RateLimitsMenuView.menuWidth)
        } label: {
            MenuBarStatusView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
