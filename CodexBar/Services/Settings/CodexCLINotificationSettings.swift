import Combine
import Foundation

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

        runLatestUpdate(errorPrefix: "读取 Codex TUI 通知失败") { settings, generation in
            let response = try await settings.codexStatusService.readCodexConfig()
            try settings.ensureCurrentUpdate(generation)
            return response.areTUINotificationsEnabled
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        runLatestUpdate(errorPrefix: "设置 Codex TUI 通知失败") { settings, generation in
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

    private func runLatestUpdate(
        errorPrefix: String,
        operation: @escaping @MainActor (CodexCLINotificationSettings, Int) async throws -> Bool
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
                let isEnabled = try await operation(self, generation)
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
                errorMessage = "\(errorPrefix): \(error.localizedDescription)"
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
            "Codex TUI 通知状态与设置不一致"
        }
    }

    private static let configKeyPath = "tui.notifications"
    private static let configMergeStrategy = "upsert"
}
