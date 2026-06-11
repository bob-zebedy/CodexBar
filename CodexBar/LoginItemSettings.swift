//
//  LoginItemSettings.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Combine
import Foundation
import ServiceManagement

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?
    
    init() {
        refresh()
    }
    
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
    
    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            
            refresh()
        } catch {
            refresh()
            errorMessage = "设置开机自动启动失败: \(error.localizedDescription)"
        }
    }
}
