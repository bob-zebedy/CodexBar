import Foundation
import os

/// 合并工作流维护刷新中的同步请求, 避免频繁开关产生重复同步
@MainActor
final class SyncScheduler {
    typealias RebuildCompletion = (Result<HistoryDataRebuildSummary, Error>) -> Void
    typealias RebuildHandler = ([String], @escaping RebuildCompletion) -> Void

    private static let syncCooldown: TimeInterval = 8

    private let maintenance: (Bool, LogTrigger) async -> HistoryMaintenanceCounts?
    private let rebuild: ([String], Bool) async throws -> HistoryDataRebuildSummary
    private let syncActivation: () -> SyncActivation
    private var isRunning = false
    private var runningTask: Task<Void, Never>?
    private var runningSynchronizes = false
    private var pendingRebuild: RebuildRequest?
    private var cooldownTask: Task<Void, Never>?
    private var lastSyncFinishedAt: Date?
    /// 请求会被合并成一次执行, 触发来源跟着一起排队, 非 nil 即代表有一个请求在等
    /// 合并时保留先到的那个, 它才是这一轮真正的起因
    private var pendingSyncTrigger: LogTrigger?
    private var pendingMaintenanceTrigger: LogTrigger?

    convenience init(viewModel: HistoryViewModel, syncActivation: @escaping () -> SyncActivation) {
        self.init(
            syncActivation: syncActivation,
            maintenance: { await viewModel.refreshMaintenance(synchronize: $0, trigger: $1) },
            rebuild: { try await viewModel.rebuildData(for: $0, synchronize: $1) }
        )
    }

    init(
        syncActivation: @escaping () -> SyncActivation,
        maintenance: @escaping (Bool, LogTrigger) async -> HistoryMaintenanceCounts?,
        rebuild: @escaping ([String], Bool) async throws -> HistoryDataRebuildSummary
    ) {
        self.syncActivation = syncActivation
        self.maintenance = maintenance
        self.rebuild = rebuild
    }

    deinit {
        runningTask?.cancel()
        cooldownTask?.cancel()
    }

    func requestMaintenance(allowsSync: Bool, trigger: LogTrigger) {
        if allowsSync, syncActivation().isActive {
            pendingSyncTrigger = pendingSyncTrigger ?? trigger
        } else {
            pendingMaintenanceTrigger = pendingMaintenanceTrigger ?? trigger
        }

        drain()
    }

    func requestSync(trigger: LogTrigger) {
        let activation = syncActivation()
        guard activation.isActive else {
            let details = LogFields.joined(
                "trigger=\(trigger.rawValue)",
                "reason=\(activation.rawValue)"
            )
            AppLog.sync.notice("同步已跳过: \(details, privacy: .public)")
            clearPendingSync()
            return
        }

        pendingSyncTrigger = pendingSyncTrigger ?? trigger
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
        if runningSynchronizes {
            runningTask?.cancel()
        }
        pendingSyncTrigger = nil
        cancelCooldownTask()
        drain()
    }

    func clearPendingMaintenance() {
        pendingSyncTrigger = nil
        pendingMaintenanceTrigger = nil
        cancelCooldownTask()
    }

    func cancel() {
        runningTask?.cancel()
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

        var syncCooldownRemaining: TimeInterval?
        if pendingSyncTrigger != nil, syncActivation().isActive {
            let remaining = remainingSyncCooldown()
            if remaining <= 0 {
                startMaintenance(synchronize: true)
                return
            }

            syncCooldownRemaining = remaining
        } else {
            pendingSyncTrigger = nil
            cancelCooldownTask()
        }

        if pendingMaintenanceTrigger != nil {
            startMaintenance(synchronize: false)
            return
        }

        if let syncCooldownRemaining {
            scheduleCooldownDrain(after: syncCooldownRemaining)
        }
    }

    private func startMaintenance(synchronize: Bool) {
        let trigger = (synchronize ? pendingSyncTrigger : pendingMaintenanceTrigger) ?? .auto
        let duration = LogDuration()
        isRunning = true
        pendingMaintenanceTrigger = nil

        if synchronize {
            pendingSyncTrigger = nil
            cancelCooldownTask()
        }

        runningSynchronizes = synchronize
        runningTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let counts = await maintenance(synchronize, trigger)
            finishMaintenance(
                synchronize: synchronize,
                trigger: trigger,
                duration: duration,
                counts: counts
            )
        }
    }

    private func finishMaintenance(
        synchronize: Bool,
        trigger: LogTrigger,
        duration: LogDuration,
        counts: HistoryMaintenanceCounts?
    ) {
        logMaintenanceOutcome(
            synchronize: synchronize,
            trigger: trigger,
            duration: duration,
            counts: counts
        )
        isRunning = false
        runningTask = nil
        runningSynchronizes = false

        if synchronize, !Task.isCancelled {
            lastSyncFinishedAt = Date()
        }

        if !syncActivation().isActive {
            pendingSyncTrigger = nil
            cancelCooldownTask()
        }

        drain()
    }

    private func startRebuild(_ request: RebuildRequest) {
        isRunning = true
        pendingRebuild = nil
        let synchronize = syncActivation().isActive

        runningSynchronizes = synchronize
        runningTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else {
                return
            }

            let result: Result<HistoryDataRebuildSummary, Error>
            do {
                result = try await .success(
                    rebuild(request.dateKeys, synchronize)
                )
            } catch {
                let details = LogFields.joined(
                    "stage=request",
                    "dates=\(request.dateKeys.count)",
                    "detail=\(error.localizedDescription)"
                )
                AppLog.history.error("数据重建失败: \(details, privacy: .public)")
                result = .failure(error)
            }

            isRunning = false
            runningTask = nil
            runningSynchronizes = false
            if synchronize, !Task.isCancelled {
                lastSyncFinishedAt = Date()
            }
            request.completion(result)
            drain()
        }
    }

    /// 空转轮次不记录日志, 避免周期刷新产生重复信息
    /// 同步自身的起止由 SyncService 记, 这里只承载维护结果, 不给 sync 开后门
    private func logMaintenanceOutcome(
        synchronize: Bool,
        trigger: LogTrigger,
        duration: LogDuration,
        counts: HistoryMaintenanceCounts?
    ) {
        guard let counts else {
            return
        }

        let triggerName = trigger.rawValue
        let sync = synchronize ? 1 : 0
        let range = counts.dateRange
        let elapsed = duration.elapsed
        let details = LogFields.joined(
            "trigger=\(triggerName)",
            "sync=\(sync)",
            "idle=\(counts.idle)",
            "dates=\(counts.dates)",
            "range=\(range)",
            "events=\(counts.events)",
            "written=\(counts.written)",
            "skipped=\(counts.skipped)",
            "failed=\(counts.failed)",
            "pruned=\(counts.pruned)",
            "elapsed=\(elapsed)"
        )
        AppLog.history.notice("统计刷新完成: \(details, privacy: .public)")
    }

    private func remainingSyncCooldown() -> TimeInterval {
        guard let lastSyncFinishedAt else {
            return 0
        }

        let elapsed = Date().timeIntervalSince(lastSyncFinishedAt)
        return max(0, Self.syncCooldown - elapsed)
    }

    /// 冷却延后只在真的排上队时记一条
    /// drain 一轮会被多个入口调用, 无条件记会把一次延后刷成好几条
    /// 标题与 requestSync 的 已跳过 分开: 这里的请求冷却结束后照常执行, 不是被丢弃
    private func scheduleCooldownDrain(after delay: TimeInterval) {
        guard cooldownTask == nil else {
            return
        }

        let trigger = pendingSyncTrigger ?? .auto
        let remaining = LogDuration.seconds(delay)
        let details = LogFields.joined(
            "trigger=\(trigger.rawValue)",
            "reason=cooldown",
            "remaining=\(remaining)"
        )
        AppLog.sync.notice("同步已延后: \(details, privacy: .public)")

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
