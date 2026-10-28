import Combine
import Foundation

/// UI 层的工作流状态, 节流普通刷新, 维护刷新由上层调度器合并
@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var snapshot = HistorySnapshot.empty

    private static let minimumRefreshInterval: TimeInterval = 5

    private let service: HistoryService
    private var isRefreshing = false
    private let refreshCoordinator = RefreshTaskCoordinator()
    private var lastRefreshedAt: Date?

    init(service: HistoryService = HistoryService()) {
        self.service = service
    }

    deinit {
        refreshCoordinator.cancel()
    }

    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefreshedAt ?? .distantPast) > Self.minimumRefreshInterval else {
            return
        }

        refresh()
    }

    func refresh() {
        if isRefreshing {
            return
        }

        refreshCoordinator.run(
            setRefreshing: { [weak self] in self?.isRefreshing = $0 },
            operation: { [service = self.service] in await service.loadSnapshot() },
            commit: { [weak self] snapshot in
                self?.snapshot = snapshot
                self?.lastRefreshedAt = Date()
            }
        )
    }

    /// SyncScheduler 串行调度每次维护刷新, 此处无需检查并发
    /// 返回本轮维护计数, 无变化时返回 nil, 调用方据此决定是否记录收尾日志
    func refreshMaintenance(
        synchronize: Bool,
        trigger: LogTrigger
    ) async -> HistoryMaintenanceCounts? {
        refreshCoordinator.cancel()
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let result = await service.loadSnapshotWithMaintenance(
            synchronize: synchronize,
            trigger: trigger
        )

        guard !Task.isCancelled else { return result.counts }
        snapshot = result.snapshot
        lastRefreshedAt = Date()
        return result.counts
    }

    func rebuildData(
        for dateKeys: [String],
        synchronize: Bool
    ) async throws -> HistoryDataRebuildSummary {
        refreshCoordinator.cancel()
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let outcome = try await service.rebuildData(
            for: dateKeys,
            synchronize: synchronize
        )
        if !Task.isCancelled {
            snapshot = outcome.snapshot
            lastRefreshedAt = Date()
        }
        return outcome.summary
    }
}
