import Combine
import Foundation
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

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            refresh()
        } catch {
            refresh()
            errorMessage = "设置开机启动失败: \(error.localizedDescription)"
        }
    }
}
