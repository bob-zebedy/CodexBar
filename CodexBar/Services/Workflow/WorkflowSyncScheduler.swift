import Foundation

/// 合并工作流维护刷新中的同步请求, 避免频繁开关产生重复同步
@MainActor
final class WorkflowSyncScheduler {
    private static let syncCooldown: TimeInterval = 8

    private let viewModel: WorkflowViewModel
    private let canSynchronize: () -> Bool
    private var isRunning = false
    private var pendingSync = false
    private var pendingLocalMaintenance = false
    private var cooldownTask: Task<Void, Never>?
    private var lastSyncFinishedAt: Date?

    init(
        viewModel: WorkflowViewModel,
        canSynchronize: @escaping () -> Bool
    ) {
        self.viewModel = viewModel
        self.canSynchronize = canSynchronize
    }

    deinit {
        cooldownTask?.cancel()
    }

    func requestMaintenance(allowsSync: Bool) {
        if allowsSync, canSynchronize() {
            pendingSync = true
        } else {
            pendingLocalMaintenance = true
        }

        drain()
    }

    func requestSync() {
        guard canSynchronize() else {
            clearPendingSync()
            return
        }

        pendingSync = true
        drain()
    }

    func clearPendingSync() {
        pendingSync = false
        cancelCooldownTask()
        drain()
    }

    func clearPendingMaintenance() {
        pendingSync = false
        pendingLocalMaintenance = false
        cancelCooldownTask()
    }

    func cancel() {
        clearPendingMaintenance()
    }

    private func drain() {
        guard !isRunning else {
            return
        }

        let canSync = pendingSync && canSynchronize()
        if canSync {
            if remainingSyncCooldown() <= 0 {
                startMaintenance(synchronize: true)
                return
            }
        } else {
            pendingSync = false
            cancelCooldownTask()
        }

        if pendingLocalMaintenance {
            startMaintenance(synchronize: false)
            return
        }

        if canSync {
            scheduleCooldownDrain(after: remainingSyncCooldown())
        }
    }

    private func startMaintenance(synchronize: Bool) {
        isRunning = true
        pendingLocalMaintenance = false

        if synchronize {
            pendingSync = false
            cancelCooldownTask()
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await viewModel.refreshMaintenance(synchronize: synchronize)
            finishMaintenance(synchronize: synchronize)
        }
    }

    private func finishMaintenance(synchronize: Bool) {
        isRunning = false

        if synchronize {
            lastSyncFinishedAt = Date()
        }

        if !canSynchronize() {
            pendingSync = false
            cancelCooldownTask()
        }

        drain()
    }

    private func remainingSyncCooldown() -> TimeInterval {
        guard let lastSyncFinishedAt else {
            return 0
        }

        let elapsed = Date().timeIntervalSince(lastSyncFinishedAt)
        return max(0, Self.syncCooldown - elapsed)
    }

    private func scheduleCooldownDrain(after delay: TimeInterval) {
        guard cooldownTask == nil else {
            return
        }

        let milliseconds = max(1, Int((delay * 1000).rounded(.up)))
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard let self, !Task.isCancelled else {
                return
            }

            cooldownTask = nil
            drain()
        }
    }

    private func cancelCooldownTask() {
        cooldownTask?.cancel()
        cooldownTask = nil
    }
}
