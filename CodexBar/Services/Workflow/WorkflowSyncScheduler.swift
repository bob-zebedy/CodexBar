import Foundation

/// 合并工作流维护刷新中的同步请求, 避免频繁开关产生重复同步
@MainActor
final class WorkflowSyncScheduler {
    typealias RebuildCompletion = (Result<WorkflowDataRebuildSummary, Error>) -> Void
    typealias RebuildHandler = ([String], @escaping RebuildCompletion) -> Void

    private static let syncCooldown: TimeInterval = 8

    private let viewModel: WorkflowViewModel
    private let canSynchronize: () -> Bool
    private var isRunning = false
    private var pendingSync = false
    private var pendingLocalMaintenance = false
    private var pendingRebuild: RebuildRequest?
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

    func requestRebuild(
        for dateKeys: [String],
        completion: @escaping RebuildCompletion
    ) {
        pendingRebuild?.completion(.failure(CancellationError()))
        pendingRebuild = RebuildRequest(dateKeys: dateKeys, completion: completion)
        cancelCooldownTask()
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
        pendingRebuild?.completion(.failure(CancellationError()))
        pendingRebuild = nil
    }

    private func drain() {
        guard !isRunning else {
            return
        }

        if let pendingRebuild {
            startRebuild(pendingRebuild)
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

    private func startRebuild(_ request: RebuildRequest) {
        isRunning = true
        pendingRebuild = nil
        let synchronize = canSynchronize()

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let result: Result<WorkflowDataRebuildSummary, Error>
            do {
                result = try await .success(
                    viewModel.rebuildData(
                        for: request.dateKeys,
                        synchronize: synchronize
                    )
                )
            } catch {
                result = .failure(error)
            }

            isRunning = false
            if synchronize {
                lastSyncFinishedAt = Date()
            }
            request.completion(result)
            drain()
        }
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

    private struct RebuildRequest {
        let dateKeys: [String]
        let completion: RebuildCompletion
    }
}
