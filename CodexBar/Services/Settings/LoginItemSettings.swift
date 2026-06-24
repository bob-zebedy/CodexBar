import Combine
import Foundation
import ServiceManagement

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
