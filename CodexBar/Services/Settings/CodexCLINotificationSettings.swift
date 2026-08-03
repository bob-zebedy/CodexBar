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
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0

    init(codexStatusService: CodexStatusService) {
        self.codexStatusService = codexStatusService
    }

    deinit {
        updateTask?.cancel()
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
            case .read: String(localized: "读取 Codex TUI 通知设置失败")
            case .write: String(localized: "写入 Codex TUI 通知设置失败")
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
        body: @escaping @MainActor (CodexCLINotificationSettings, Int) async throws -> Bool
    ) {
        updateTask?.cancel()
        updateGeneration += 1
        let generation = updateGeneration

        isUpdating = true
        errorMessage = nil
        updateTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let isEnabled = try await body(self, generation)
                guard isCurrentUpdate(generation) else {
                    return
                }
                self.isEnabled = isEnabled
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentUpdate(generation) else {
                    return
                }
                let logStage = operation.logStage
                AppLog.settings.error(
                    "Codex TUI 通知失败: stage=\(logStage, privacy: .public); detail=\(error.localizedDescription, privacy: .public)"
                )
                errorMessage = operation.errorPrefix
            }

            finishUpdate(generation)
        }
    }

    private func finishUpdate(_ generation: Int) {
        guard isCurrentUpdate(generation) else {
            return
        }

        isUpdating = false
        updateTask = nil
    }

    private func ensureCurrentUpdate(_ generation: Int) throws {
        try Task.checkCancellation()
        guard isCurrentUpdate(generation) else {
            throw CancellationError()
        }
    }

    private func isCurrentUpdate(_ generation: Int) -> Bool {
        generation == updateGeneration
    }

    private enum SettingsError: LocalizedError {
        case verificationFailed

        var errorDescription: String? {
            String(localized: "Codex TUI 通知状态与设置不一致")
        }
    }

    private static let configKeyPath = "tui.notifications"
    private static let configMergeStrategy = "upsert"
}
