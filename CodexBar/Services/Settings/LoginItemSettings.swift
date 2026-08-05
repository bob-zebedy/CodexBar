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

        AppLog.settings.notice("开机自动启动变更: enabled=\(enabled ? 1 : 0)")
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            refresh()
        } catch {
            let details = LogFields.joined(
                "enabled=\(enabled ? 1 : 0)",
                "detail=\(error.localizedDescription)"
            )
            AppLog.settings.error("开机自动启动失败: \(details, privacy: .public)")
            refresh()
            errorMessage = String(localized: "设置开机启动失败")
        }
    }
}
