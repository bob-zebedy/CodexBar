//
//  MenuBarStatusView.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import SwiftUI

struct MenuBarStatusView: View {
    @ObservedObject var viewModel: RateLimitsViewModel
    
    var body: some View {
        Image(systemName: viewModel.hasError ? "person.fill.xmark" : "person.fill.checkmark")
            .contentTransition(.symbolEffect(.replace))
            .animation(.default, value: viewModel.hasError)
            .task {
                viewModel.startAutoRefresh()
            }
    }
}
