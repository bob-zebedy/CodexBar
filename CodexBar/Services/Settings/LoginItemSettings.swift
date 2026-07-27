import Combine
import Foundation
import os
import ServiceManagement

/// 开机启动设置, 所有 ServiceManagement 错误只展示简短文案
@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        AppLog.settings.notice("开机启动已变更: enabled=\(enabled ? 1 : 0)")
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            refresh()
        } catch {
            AppLog.settings.error(
                "设置开机启动失败: enabled=\(enabled ? 1 : 0); detail=\(error.localizedDescription, privacy: .public)"
            )
            refresh()
            errorMessage = "设置开机启动失败"
        }
    }
}
