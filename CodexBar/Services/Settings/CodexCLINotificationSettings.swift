import Combine
import Foundation
import os

/// Codex TUI 通知设置, 通过 app-server 读写用户级 config.toml
@MainActor
final class CodexCLINotificationSettings: ObservableObject {
    @Published private(set) var isEnabled = true
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let codexStatusService: CodexStatusService
    private let updateCoordinator = RefreshTaskCoordinator()

    init(codexStatusService: CodexStatusService) {
        self.codexStatusService = codexStatusService
    }

    func refresh() {
        guard !isUpdating else {
            return
        }

        runLatestUpdate(operation: .read) { settings, generation in
            let response = try await settings.codexStatusService.readCodexConfig()
            try settings.ensureCurrentUpdate(generation)
            return response.areTUINotificationsEnabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        AppLog.settings.notice("Codex TUI 通知变更: enabled=\(enabled ? 1 : 0)")
        guard enabled != isEnabled else {
            return
        }

        runLatestUpdate(operation: .write) { settings, generation in
            _ = try await settings.codexStatusService.writeCodexConfigBatch(
                edits: [
                    .init(
                        keyPath: Self.configKeyPath,
                        value: enabled,
                        mergeStrategy: Self.configMergeStrategy
                    )
                ]
            )
            try settings.ensureCurrentUpdate(generation)

            let response = try await settings.codexStatusService.readCodexConfig()
            try settings.ensureCurrentUpdate(generation)
            guard response.areTUINotificationsEnabled == enabled else {
                throw SettingsError.verificationFailed
            }
            return enabled
        }
    }

    /// 一次操作的用户文案与日志标题由它一处派生, 不在调用点各写一份
    /// 两者都是固定字面量, 日志标题仍然能直接 grep
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
        body: @escaping @MainActor @Sendable (CodexCLINotificationSettings, Int) async throws -> Bool
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

    private static let configKeyPath = "tui.notifications"
    private static let configMergeStrategy = "upsert"
}
