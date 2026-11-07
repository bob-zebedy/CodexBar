import Combine
import Foundation
import os

/// Codex TUI 通知设置, 通过 app-server 读写用户级 config.toml
@MainActor
final class TUINotificationSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool?
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    var isAvailable: Bool {
        isEnabled != nil
    }

    private let read: @MainActor () async throws -> Bool
    private let write: @MainActor (Bool) async throws -> Void
    private let updateCoordinator = RefreshTaskCoordinator()
    private var isConnected = false
    private var connectionObserver: AnyCancellable?

    convenience init(codexStatusService: CodexStatusService, connectionAvailability: AnyPublisher<Bool, Never>) {
        self.init(
            connectionAvailability: connectionAvailability,
            read: { try await codexStatusService.areTUINotificationsEnabled() },
            write: { try await codexStatusService.setTUINotificationsEnabled($0) }
        )
    }

    init(
        connectionAvailability: AnyPublisher<Bool, Never>,
        read: @escaping @MainActor () async throws -> Bool,
        write: @escaping @MainActor (Bool) async throws -> Void
    ) {
        self.read = read
        self.write = write
        connectionObserver = connectionAvailability
            .removeDuplicates()
            .sink { [weak self] connected in
                self?.updateConnection(connected)
            }
    }

    private func updateConnection(_ connected: Bool) {
        isConnected = connected
        if connected {
            refresh()
        } else {
            // 断开后丢弃在途结果, 展示占位不能写回 Codex 配置
            updateCoordinator.cancel()
            isEnabled = nil
            isUpdating = false
            errorMessage = nil
        }
    }

    func refresh() {
        guard isConnected, !isUpdating else {
            return
        }

        runLatestUpdate(operation: .read) { settings, generation in
            let enabledOnServer = try await settings.read()
            try settings.ensureCurrentUpdate(generation)
            return enabledOnServer
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, !isUpdating, enabled != isEnabled else {
            return
        }
        AppLog.settings.notice("Codex TUI 通知变更: enabled=\(enabled ? 1 : 0)")

        runLatestUpdate(operation: .write) { settings, generation in
            try await settings.write(enabled)
            try settings.ensureCurrentUpdate(generation)

            let enabledOnServer = try await settings.read()
            try settings.ensureCurrentUpdate(generation)
            guard enabledOnServer == enabled else {
                throw SettingsError.verificationFailed
            }
            return enabled
        }
    }

    /// 操作文案和日志阶段在这里定义, 使用固定字面量方便检索
    private enum ConfigOperation {
        case read
        case write

        var errorPrefix: String {
            switch self {
            case .read: String(localized: "codex-tui-notifications.error.read-failed")
            case .write: String(localized: "codex-tui-notifications.error.write-failed")
            }
        }

        var logStage: String {
            switch self {
            case .read: "read"
            case .write: "write"
            }
        }
    }

    private func runLatestUpdate(
        operation: ConfigOperation,
        body: @escaping @MainActor @Sendable (TUINotificationSettings, Int) async throws -> Bool
    ) {
        isUpdating = true
        errorMessage = nil
        updateCoordinator.start { [weak self] generation in
            guard let self else {
                return
            }

            do {
                let isEnabled = try await body(self, generation)
                guard updateCoordinator.canCommit(generation) else {
                    return
                }
                self.isEnabled = isEnabled
            } catch is CancellationError {
                return
            } catch {
                guard updateCoordinator.canCommit(generation) else {
                    return
                }
                let logStage = operation.logStage
                let details = LogFields.joined(
                    "stage=\(logStage)",
                    "detail=\(error.localizedDescription)"
                )
                AppLog.settings.error("Codex TUI 通知失败: \(details, privacy: .public)")
                errorMessage = operation.errorPrefix
                if operation == .read {
                    isEnabled = nil
                }
            }

            updateCoordinator.finish(generation) {
                isUpdating = false
            }
        }
    }

    private func ensureCurrentUpdate(_ generation: Int) throws {
        try Task.checkCancellation()
        guard updateCoordinator.canCommit(generation) else {
            throw CancellationError()
        }
    }

    private enum SettingsError: LocalizedError {
        case verificationFailed

        var errorDescription: String? {
            String(localized: "codex-tui-notifications.error.state-mismatch")
        }
    }
}
