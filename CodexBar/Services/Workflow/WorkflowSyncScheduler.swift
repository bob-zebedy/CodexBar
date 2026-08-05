import Foundation
import os

/// 合并工作流维护刷新中的同步请求, 避免频繁开关产生重复同步
@MainActor
final class WorkflowSyncScheduler {
    typealias RebuildCompletion = (Result<WorkflowDataRebuildSummary, Error>) -> Void
    typealias RebuildHandler = ([String], @escaping RebuildCompletion) -> Void

    private static let syncCooldown: TimeInterval = 8

    private let viewModel: WorkflowViewModel
    private let syncActivation: () -> WorkflowSyncActivation
    private var isRunning = false
    private var pendingRebuild: RebuildRequest?
    private var cooldownTask: Task<Void, Never>?
    private var lastSyncFinishedAt: Date?
    /// 请求会被合并成一次执行, 触发来源跟着一起排队, 非 nil 即代表有一个请求在等
    /// 合并时保留先到的那个, 它才是这一轮真正的起因
    private var pendingSyncTrigger: LogTrigger?
    private var pendingMaintenanceTrigger: LogTrigger?

    init(
        viewModel: WorkflowViewModel,
        syncActivation: @escaping () -> WorkflowSyncActivation
    ) {
        self.viewModel = viewModel
        self.syncActivation = syncActivation
    }

    deinit {
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

    /// activation 传 nil 时现场求值
    /// 从 @Published 的订阅里调用必须显式传入: 那时属性还是旧值, 现场求值会得到刚被改掉的那个结论
    func requestSync(trigger: LogTrigger, activation overrideActivation: WorkflowSyncActivation? = nil) {
        let activation = overrideActivation ?? syncActivation()
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

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let counts = await viewModel.refreshMaintenance(
                synchronize: synchronize,
                trigger: trigger
            )
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
        counts: WorkflowMaintenanceCounts?
    ) {
        logMaintenanceOutcome(
            synchronize: synchronize,
            trigger: trigger,
            duration: duration,
            counts: counts
        )
        isRunning = false

        if synchronize {
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
                let details = LogFields.joined(
                    "stage=request",
                    "dates=\(request.dateKeys.count)",
                    "detail=\(error.localizedDescription)"
                )
                AppLog.workflow.error("数据重建失败: \(details, privacy: .public)")
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

    /// 空转的一轮什么都没改, 跟着 60 秒额度刷新记一条会把空闲机器的日志刷没
    /// 同步自身的起止由 WorkflowSyncService 记, 这里只承载维护结果, 不给 sync 开后门
    private func logMaintenanceOutcome(
        synchronize: Bool,
        trigger: LogTrigger,
        duration: LogDuration,
        counts: WorkflowMaintenanceCounts?
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
        AppLog.workflow.notice("统计刷新完成: \(details, privacy: .public)")
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
