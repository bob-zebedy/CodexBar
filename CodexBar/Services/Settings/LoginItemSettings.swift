import Combine
import Foundation
import os
import ServiceManagement

/// 开机启动设置, 所有 ServiceManagement 错误只展示简短文案
@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
    }

    func refresh() {
        let currentStatus = readStatus()
        if currentStatus != status {
            errorMessage = nil
        }
        status = currentStatus
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        AppLog.settings.notice("开机自动启动变更: enabled=\(enabled ? 1 : 0)")
        do {
            if enabled {
                try register()
            } else {
                try unregister()
            }

            // 注册成功仍可能等待系统批准, 开关只反映实际授权
            refresh()
        } catch {
            let details = LogFields.joined(
                "enabled=\(enabled ? 1 : 0)",
                "detail=\(error.localizedDescription)"
            )
            AppLog.settings.error("开机自动启动失败: \(details, privacy: .public)")
            refresh()
            if !requiresApproval {
                errorMessage = String(localized: "settings.general.launch-at-login-failed")
            }
        }
    }
}
