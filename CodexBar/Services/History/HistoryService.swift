import Foundation
import os

nonisolated struct HistoryMaintenanceCounts {
    var events = 0
    var written = 0
    var skipped = 0
    var failed = 0
    var pruned = 0
    var dateRange = "-"
    /// 这条之前连续空转了多少轮, 用来确认静默期是没事干而不是没跑
    var idle = 0

    var dates: Int {
        written + skipped + failed
    }

    /// 这一轮有没有真的改变过状态
    var hasWork: Bool {
        dates > 0 || pruned > 0
    }
}

/// 原始事件与聚合进度由数据库事务维护, 同步只读取已提交的聚合
actor HistoryService {
    private let database: HistoryDatabaseStore
    private let syncService: SyncService
    private let tokenUsageHistory: TokenUsageHistoryStore
    private var idleMaintenanceRounds = 0
    private var lastRetentionCutoff: Date?

    init(directoryURL: URL = HistoryStorage.directoryURL(), syncService: SyncService? = nil, tokenUsageHistory: TokenUsageHistoryStore? = nil) {
        database = HistoryDatabaseStore.shared(in: directoryURL)
        self.syncService = syncService ?? SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directoryURL))
        self.tokenUsageHistory = tokenUsageHistory ?? TokenUsageHistoryStore(directoryURL: directoryURL)
    }

    func loadSnapshot(synchronize: Bool = false, trigger: LogTrigger = .auto) async -> HistorySnapshot {
        var aggregates: [ActivityDataAggregate] = []
        var pending = Set<String>()
        var readable = true
        do {
            (aggregates, pending) = try await database.access { database in
                try database.transaction {
                    try (database.activityDataAggregates(), Set(database.pendingActivityDataDates()))
                }
            }
        } catch {
            readable = false
            AppLog.history.error("活动历史读取失败: \(error.localizedDescription, privacy: .public)")
        }
        let tokenUsageSnapshot: TokenUsageHistorySnapshot
        do {
            tokenUsageSnapshot = try await tokenUsageHistory.loadSnapshot()
        } catch {
            tokenUsageSnapshot = await TokenUsageHistorySnapshot(aggregates: (try? tokenUsageHistory.persistedAggregates()) ?? [], coverage: .unavailable)
            AppLog.history.error("Token 历史读取失败: \(error.localizedDescription, privacy: .public)")
        }
        let tokenUsageAggregates = tokenUsageSnapshot.aggregates
        let reliable = tokenUsageSnapshot.coverage.isComplete
        let sync: SyncSnapshot = if synchronize {
            await syncService.synchronizeIfEnabled(
                localActivityDataAggregates: aggregates.filter { !pending.contains($0.date) }, localTokenUsageAggregates: tokenUsageAggregates,
                isTokenUsageSourceComplete: reliable, trigger: trigger
            )
        } else {
            await syncService.snapshotFromCacheIfEnabled(localTokenUsageAggregates: reliable ? tokenUsageAggregates : [])
        }
        var snapshot = HistorySnapshot(localActivityDataAggregates: aggregates, syncedActivityDataRecords: sync.activityData, currentDeviceID: sync.currentDeviceID)
        snapshot.tokenUsageByDate = sync.tokenUsageByDate ?? TokenUsageAggregate.tokenUsageByDate(tokenUsageAggregates)
        snapshot.isActivityDataComplete = snapshot.isActivityDataComplete && readable && sync.isActivityDataComplete
        let known = Set(aggregates.map(\.date)).union(sync.activityData.filter { $0.deviceID == sync.currentDeviceID }.map(\.date))
        snapshot.unavailableActivityDataDates.formUnion(pending.subtracting(known))
        return snapshot
    }

    func loadSnapshotWithMaintenance(
        synchronize: Bool, trigger: LogTrigger, now: Date = Date()
    ) async -> (snapshot: HistorySnapshot, counts: HistoryMaintenanceCounts?) {
        await syncService.pruneLocalCaches(now: now)
        var counts = HistoryMaintenanceCounts()
        do {
            let cutoff = HistoryStorage.retentionCutoffDate(today: now)
            if lastRetentionCutoff != cutoff {
                counts.pruned = try await database.access { try $0.prune(now: now) }
                lastRetentionCutoff = cutoff
            }
            let (dates, previous) = try await database.access {
                try ($0.pendingActivityDataDates(), $0.activityDataAggregates().reduce(into: [String: Int]()) { $0[$1.date] = $1.eventCount ?? 0 })
            }
            counts.dateRange = dates.first.map { $0 == dates.last ? $0 : $0 + ".." + (dates.last ?? $0) } ?? "-"
            for date in dates {
                do {
                    let aggregate = try await database.access { try $0.aggregateActivityData(date: date, now: now) }
                    counts.events += (aggregate.eventCount ?? 0) - (previous[date] ?? 0)
                    counts.written += 1
                } catch {
                    counts.failed += 1
                    AppLog.history.error("活动聚合失败: date=\(date, privacy: .public) detail=\(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            counts.failed += 1
            AppLog.history.error("历史维护失败: \(error.localizedDescription, privacy: .public)")
        }
        counts.idle = idleMaintenanceRounds
        idleMaintenanceRounds = counts.hasWork ? 0 : idleMaintenanceRounds + 1
        return await (loadSnapshot(synchronize: synchronize, trigger: trigger), counts.hasWork ? counts : nil)
    }

    func rebuildData(for dateKeys: [String], synchronize: Bool) async throws -> HistoryDataRebuildOutcome {
        let dates = Set(dateKeys.filter(HistoryStorage.isValidDateKey))
        guard !dates.isEmpty else { throw HistoryDataRebuildError.sourceUnavailable }
        let available = try await database.access { try Set($0.dates()) }
        var rebuilt: [ActivityDataAggregate] = []
        var failed: [String] = []
        for date in dates.intersection(available).sorted() {
            do {
                try await rebuilt.append(database.access { try $0.aggregateActivityData(date: date, rebuilding: true) })
            } catch {
                failed.append(date)
            }
        }
        let tokenUsageRebuild: TokenUsageRebuildResult
        do {
            tokenUsageRebuild = try await tokenUsageHistory.rebuild(for: Array(dates))
        } catch {
            tokenUsageRebuild = TokenUsageRebuildResult(failedDateKeys: dates.sorted())
        }
        guard !rebuilt.isEmpty || !tokenUsageRebuild.dateKeys.isEmpty else { throw HistoryDataRebuildError.sourceUnavailable }
        let snapshot = await loadSnapshot(synchronize: synchronize, trigger: .manual)
        let tokenUsageAggregates = await (try? tokenUsageHistory.persistedAggregates()) ?? []
        let tokenUsagePending = await syncService.hasPendingTokenUsageUpdates(local: tokenUsageAggregates)
        let localActivityData = await (try? database.access { try $0.activityDataAggregates() }) ?? []
        let activityDataPending = await syncService.hasPendingActivityDataUpdates(local: localActivityData)
        let tokenUsageFailures = tokenUsageRebuild.failedDateKeys
        let summary = HistoryDataRebuildSummary(
            rebuiltDateCount: Set(rebuilt.map(\.date)).union(tokenUsageRebuild.dateKeys).subtracting(failed).subtracting(tokenUsageFailures).count,
            eventCount: rebuilt.reduce(0) { $0 + ($1.eventCount ?? 0) }, isSyncPending: tokenUsagePending || activityDataPending,
            failedDateKeys: failed, failedTokenUsageDateKeys: tokenUsageFailures,
            tokenUsageEventCount: tokenUsageRebuild.eventCount
        )
        return HistoryDataRebuildOutcome(snapshot: snapshot, summary: summary)
    }
}

nonisolated struct HistoryDataRebuildSummary: Equatable, Sendable {
    let rebuiltDateCount: Int
    let eventCount: Int
    let isSyncPending: Bool
    let failedDateKeys: [String]
    let failedTokenUsageDateKeys: [String]
    let tokenUsageEventCount: Int

    var didFailTokenUsageRebuild: Bool {
        !failedTokenUsageDateKeys.isEmpty
    }
}

nonisolated struct HistoryDataRebuildOutcome {
    let snapshot: HistorySnapshot
    let summary: HistoryDataRebuildSummary
}

nonisolated enum HistoryDataRebuildError: LocalizedError {
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            String(localized: "history.rebuild.error.source-unavailable")
        }
    }
}
