import CryptoKit
import Foundation
import os

/// 汇总失败时定位到哪一步, 只用于日志
private nonisolated enum MaintenanceStage: String {
    case prepare
    case write
    case prune
}

/// 一轮汇总的计数, 成功路径压进 SyncScheduler 的收尾那一条日志, 不为每天单独记一行
/// dates 从各处理结果的计数求和得出, 不额外保存
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

/// 从 归一化活动事件维护每日聚合, 对外只发布 UI 需要的统计快照
actor HistoryService {
    private let directoryURL: URL
    private let eventsDirectoryURL: URL
    private let dailyLogURL: URL
    private let syncService: SyncService
    private let tokenHistory: TokenHistoryStore
    /// 上次归一化时 Aggregates/activity.jsonl 的 stat 与当天日期键
    private var lastNormalizedDailyLog: HistoryDailyLogStamp?
    /// 上一条维护日志之后连续空转的轮数, 记出去就清零
    private var idleMaintenanceRounds = 0
    private var verifiedBoundaries: [String: HistoryBoundaryVerification] = [:]
    private static let eventReadChunkSize = 64 * 1024

    init(
        directoryURL: URL = HistoryStorage.directoryURL(),
        syncService: SyncService? = nil,
        tokenHistory: TokenHistoryStore? = nil
    ) {
        self.directoryURL = directoryURL
        eventsDirectoryURL = HistoryStorage.eventsDirectoryURL(in: directoryURL)
        dailyLogURL = HistoryStorage.dailyURL(in: directoryURL)
        self.syncService = syncService ?? SyncService(directoryURL: HistoryStorage.syncDirectoryURL(in: directoryURL))
        self.tokenHistory = tokenHistory ?? TokenHistoryStore(directoryURL: directoryURL)
    }

    // MARK: - 快照读取

    func loadSnapshot(
        synchronize: Bool = false,
        trigger: LogTrigger = .auto
    ) async -> HistorySnapshot {
        await makeSnapshot(
            localAggregates: loadDailyAggregates() ?? [],
            synchronize: synchronize,
            trigger: trigger
        )
    }

    /// 先跑一轮维护再取快照
    /// counts 为 nil 表示这一轮空转, 由调用方决定记不记日志
    func loadSnapshotWithMaintenance(
        synchronize: Bool,
        trigger: LogTrigger
    ) async -> (snapshot: HistorySnapshot, counts: HistoryMaintenanceCounts?) {
        let counts = performMaintenanceIfNeeded()
        let snapshot = await loadSnapshot(synchronize: synchronize, trigger: trigger)
        return (snapshot, counts)
    }

    private func makeSnapshot(
        localAggregates: [ActivityAggregate],
        synchronize: Bool,
        trigger: LogTrigger,
        localTokenTurns: [TokenTurn]? = nil
    ) async -> HistorySnapshot {
        let replacements = readyReplacements()
        // 零值替换仍需同步, 展示和普通上传不生成 Token-only 日期的活动贡献
        let localAggregates = localAggregates.filter { $0.eventCount != 0 }
        let tokenTurns: [TokenTurn]
        if let localTokenTurns {
            tokenTurns = localTokenTurns
        } else {
            do {
                let baseline = await syncService.tokenRecoveryBaselineIfEnabled()
                tokenTurns = try await tokenHistory.refresh(baseline: baseline)
            } catch {
                let error = error as NSError
                AppLog.history.error("Token 历史读取失败: domain=\(error.domain, privacy: .public) code=\(error.code)")
                tokenTurns = []
            }
        }
        let syncSnapshot: SyncSnapshot = if synchronize {
            await syncService.synchronizeIfEnabled(
                localAggregates: localAggregates, localTokenTurns: tokenTurns, replacements: replacements, trigger: trigger
            )
        } else {
            await syncService.snapshotFromCacheIfEnabled(localTokenTurns: tokenTurns, replacements: replacements)
        }
        acknowledgeReplacements(syncSnapshot.completedReplacements)
        var snapshot = HistorySnapshot(
            localAggregates: localAggregates,
            syncedRecords: syncSnapshot.records.filter { $0.daily.eventCount != 0 },
            currentDeviceID: syncSnapshot.currentDeviceID
        )
        snapshot.tokenUsageByDate = syncSnapshot.tokenUsageByDate ?? TokenTurn.dailyUsage(tokenTurns)
        return snapshot
    }

    /// 以指定日期范围内的本机原始事件为权威来源重建, 并安排替换当前设备的同日云端贡献
    func rebuildData(
        for dateKeys: [String],
        synchronize: Bool
    ) async throws -> HistoryDataRebuildOutcome {
        let duration = LogDuration()
        let normalizedDateKeys = Set(dateKeys).sorted()
        guard !normalizedDateKeys.isEmpty else {
            throw HistoryDataRebuildError.sourceUnavailable
        }

        // 已保存请求的失败日期交给常规维护重试, 单日失败不中止整批
        // 中止会让「前几天已改写, 后几天没碰」这个事实完全不被上报
        var rebuildResults = [HistoryMaintenanceResult]()
        var failedDateKeys = [String]()
        var failedRequestDateKeys = [String]()
        var firstFailure: Error?
        let eventDateKeysWithData = normalizedDateKeys.filter { HistoryStorage.fileSize(at: eventLogURL(for: $0)) > 0 }
        for dateKey in eventDateKeysWithData {
            var requestWasSaved = false
            do {
                try rebuildResults.append(rebuildLocalData(for: dateKey, requestWasSaved: &requestWasSaved))
            } catch {
                // 整批成功时这个原因不会往上抛, 摘要只带得走日期
                let details = LogFields.joined(
                    "stage=date",
                    "date=\(dateKey)",
                    "detail=\(error.localizedDescription)"
                )
                AppLog.history.error("数据重建失败: \(details, privacy: .public)")
                failedDateKeys.append(dateKey)
                if !requestWasSaved {
                    failedRequestDateKeys.append(dateKey)
                }
                firstFailure = firstFailure ?? error
            }
        }

        var tokenResult = TokenRebuildResult.empty
        var didFailTokenRebuild = false
        do {
            tokenResult = try await tokenHistory.rebuild(for: normalizedDateKeys)
            if !tokenResult.failedDateKeys.isEmpty {
                firstFailure = firstFailure ?? TokenCacheError.incompleteJournal
            }
        } catch {
            didFailTokenRebuild = true
            firstFailure = firstFailure ?? error
            let error = error as NSError
            AppLog.history.error("Token 重建失败: domain=\(error.domain, privacy: .public) code=\(error.code)")
        }

        // 一天都没成功才算整体失败, 并保留首个真实原因而非笼统报「数据发生变化」
        guard !rebuildResults.isEmpty || !tokenResult.dateKeys.isEmpty else {
            throw firstFailure ?? HistoryDataRebuildError.sourceUnavailable
        }

        // 重建只由设置页的用户操作发起
        let localTurns = if let turns = tokenResult.turns {
            turns
        } else {
            await (try? tokenHistory.currentTurns()) ?? []
        }
        let snapshot = await makeSnapshot(
            localAggregates: loadDailyAggregates() ?? [],
            synchronize: synchronize,
            trigger: .manual,
            localTokenTurns: localTurns
        )
        let tokenSyncPending = await syncService.hasPendingTokenUpdates(local: localTurns)
        let tokenFailures = didFailTokenRebuild ? normalizedDateKeys : tokenResult.failedDateKeys
        let summary = HistoryDataRebuildSummary(
            rebuiltDateCount: Set(rebuildResults.map(\.dateKey)).union(tokenResult.dateKeys)
                .subtracting(failedDateKeys).subtracting(tokenFailures).count,
            eventCount: rebuildResults.reduce(0) { $0 + ($1.aggregate.eventCount ?? 0) },
            isSyncReplacementPending: hasPendingReplacement(for: eventDateKeysWithData) || tokenSyncPending,
            failedDateKeys: failedDateKeys,
            failedRequestDateKeys: failedRequestDateKeys,
            failedTokenDateKeys: tokenFailures,
            tokenTurnCount: tokenResult.turnCount,
            didFailTokenRebuild: didFailTokenRebuild || !tokenResult.failedDateKeys.isEmpty
        )
        let elapsed = duration.elapsed
        let details = LogFields.joined(
            "dates=\(summary.rebuiltDateCount)",
            "events=\(summary.eventCount)",
            "tokenTurns=\(summary.tokenTurnCount)",
            "failedDates=\(failedDateKeys.count)",
            "elapsed=\(elapsed)"
        )
        AppLog.history.notice("数据重建完成: \(details, privacy: .public)")
        return HistoryDataRebuildOutcome(snapshot: snapshot, summary: summary)
    }

    func hasPendingReplacement(for dates: [String]) -> Bool {
        let state = HistoryStorage.loadMaintenanceState(in: directoryURL)
        return dates.contains { state.days[$0]?.requiresCloudReplacement == true }
    }

    /// 只从同一锁内读取的聚合和提交状态形成替换授权, dirty 状态不允许覆盖云端
    private func readyReplacements() -> [ActivityAggregate] {
        (try? HistoryStorage.withExclusiveLock(in: directoryURL) {
            let state = HistoryStorage.loadMaintenanceState(in: directoryURL)
            return (loadDailyAggregates() ?? []).filter { aggregate in
                guard let day = state.days[aggregate.date], day.requiresCloudReplacement,
                      !state.dirty.contains(aggregate.date), day.corrupt == 0, day.offset == day.size, day.offset > 0,
                      let generation = day.generationID, aggregate.generationID == generation,
                      aggregate.eventCount != nil,
                      let stat = HistoryStorage.fileStat(at: eventLogURL(for: aggregate.date)),
                      stat.identifier == day.fileIdentifier, stat.size >= day.offset else { return false }
                return !hasBoundaryChanged(dateKey: aggregate.date, day: day, stat: stat)
            }
        }) ?? []
    }

    func acknowledgeReplacements(_ completed: [String: String]) {
        guard !completed.isEmpty else { return }
        do {
            try HistoryStorage.withExclusiveLock(in: directoryURL) {
                var state = HistoryStorage.loadMaintenanceState(in: directoryURL)
                for (date, generation) in completed where state.days[date]?.generationID == generation
                    && !state.dirty.contains(date) {
                    state.days[date]?.requiresCloudReplacement = false
                }
                try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            }
        } catch {
            AppLog.history.error("云端替换确认保存失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadDailyAggregates() -> [ActivityAggregate]? {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return nil
        }

        let aggregates: [ActivityAggregate] = JSONLines.decode(from: data)
        guard !aggregates.isEmpty else {
            return nil
        }

        return ActivityAggregate.normalized(aggregates: aggregates)
    }

    // MARK: - 重建与维护调度

    private func rebuildLocalData(for dateKey: String, requestWasSaved: inout Bool) throws -> HistoryMaintenanceResult {
        var aggregates = loadDailyAggregates() ?? []
        let eventCountAvailability = aggregates
            .first(where: { $0.date == dateKey })?
            .eventCountAvailability ?? .legacy
        let task = try prepareRebuildTask(
            for: dateKey,
            eventCountAvailability: eventCountAvailability
        )
        requestWasSaved = true

        do {
            let result = try buildDailyAggregate(for: task)
            guard try commit(result, aggregates: &aggregates),
                  rebuildWasCommitted(result) else {
                throw HistoryDataRebuildError.sourceChanged
            }
            return result
        } catch {
            markDirty(dateKey)
            throw error
        }
    }

    private func prepareRebuildTask(
        for dateKey: String,
        eventCountAvailability: ActivityCountAvailability
    ) throws -> HistoryMaintenanceTask {
        let retentionCutoffKey = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        guard HistoryStorage.isValidDateKey(dateKey), dateKey >= retentionCutoffKey else {
            throw HistoryDataRebuildError.sourceUnavailable
        }

        return try HistoryStorage.withExclusiveLock(in: directoryURL) {
            guard let stat = HistoryStorage.fileStat(at: eventLogURL(for: dateKey)),
                  stat.size > 0 else {
                throw HistoryDataRebuildError.sourceUnavailable
            }

            var state = HistoryStorage.loadMaintenanceState(in: directoryURL)
            state.startNewGeneration(for: dateKey, startedEmpty: false, fileIdentifier: stat.identifier)
            state.days[dateKey]?.requiresCloudReplacement = true
            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            guard let day = state.days[dateKey] else { throw HistoryDataRebuildError.sourceUnavailable }
            return dirtyTask(for: dateKey, day: day, size: stat.size, eventCountAvailability: eventCountAvailability)
        }
    }

    private func rebuildWasCommitted(_ result: HistoryMaintenanceResult) -> Bool {
        let dailyGeneration = loadDailyAggregates()?
            .first(where: { $0.date == result.dateKey })?
            .generationID
        guard dailyGeneration == result.aggregate.generationID else {
            return false
        }

        return (try? HistoryStorage.withExclusiveLock(in: directoryURL) {
            guard let day = HistoryStorage.loadMaintenanceState(in: directoryURL).days[result.dateKey] else {
                return false
            }
            return day.generationID == result.aggregate.generationID
                && day.offset == result.size
        }) ?? false
    }

    /// 空转的一轮返回 nil
    /// 维护跟随额度刷新执行, 只记录有实际工作的轮次, 避免空闲时持续产生重复日志
    /// 收尾日志由 SyncScheduler 统一记, 这里只负责判断有没有值得记的东西
    private func performMaintenanceIfNeeded() -> HistoryMaintenanceCounts? {
        let duration = LogDuration()
        var counts = HistoryMaintenanceCounts()
        var stage = MaintenanceStage.prepare
        do {
            let tasks = try prepareMaintenanceTasks()
            stage = .write
            let didCommitDailyLog = perform(tasks, counts: &counts)
            // 成功提交前已整体归一化, 没有完整提交时再做一次稳态检查
            if !didCommitDailyLog {
                try normalizeDailyAggregatesIfNeeded()
            }
            stage = .prune
            counts.pruned = try pruneExpiredEventFiles()
        } catch {
            let elapsed = duration.elapsed
            let details = LogFields.joined(
                "stage=\(stage.rawValue)",
                "elapsed=\(elapsed)",
                "detail=\(error.localizedDescription)"
            )
            AppLog.history.error("事件汇总失败: \(details, privacy: .public)")
            idleMaintenanceRounds = 0
            return nil
        }

        guard counts.hasWork else {
            idleMaintenanceRounds += 1
            return nil
        }

        counts.idle = idleMaintenanceRounds
        idleMaintenanceRounds = 0
        return counts
    }

    /// 返回是否至少完整提交一个聚合与维护状态
    /// 批次内共享同一份内存聚合, 避免每个任务重新读盘
    private func perform(
        _ tasks: [HistoryMaintenanceTask],
        counts: inout HistoryMaintenanceCounts
    ) -> Bool {
        // 任务是 dirty 与 pending 两段拼接, 只在各自半边有序, 取首尾会得到反向区间
        let dateKeys = tasks.map(\.dateKey)
        guard let oldestDateKey = dateKeys.min(),
              let newestDateKey = dateKeys.max() else {
            return false
        }

        counts.dateRange = oldestDateKey == newestDateKey
            ? oldestDateKey
            : oldestDateKey + ".." + newestDateKey

        var aggregates = loadDailyAggregates() ?? []
        var didCommit = false
        for task in tasks {
            do {
                let result = try buildDailyAggregate(for: task)
                if try commit(result, aggregates: &aggregates) {
                    didCommit = true
                    counts.written += 1
                    // 记本轮新摄入的量; 累加 eventCount 会变成当日总数, 事件停写也看不出来
                    // dirty 任务没有 base, 差值即整天重算的量, 与"这轮处理了多少"仍然一致
                    counts.events += (result.aggregate.eventCount ?? 0) - task.baseEventCount
                } else {
                    counts.skipped += 1
                }
            } catch {
                counts.failed += 1
                let details = LogFields.joined(
                    "stage=daily",
                    "date=\(task.dateKey)",
                    "detail=\(error.localizedDescription)",
                    "action=markDirty"
                )
                AppLog.history.error("事件汇总失败: \(details, privacy: .public)")
                markDirty(task.dateKey)
            }
        }

        return didCommit
    }

    private func prepareMaintenanceTasks() throws -> [HistoryMaintenanceTask] {
        let eventDateKeys = eventDateKeys()
        let dailyDecodeResult = loadDailyAggregatesWithFailures()

        return try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var state = HistoryStorage.loadMaintenanceState(in: directoryURL)
            var changedState = state.normalize()
            let dailyByDate = dailyDecodeResult.values.reduce(into: [String: ActivityAggregate]()) { result, aggregate in
                result[aggregate.date] = aggregate
            }

            let changedByRebuild = markRebuildDates(
                eventDateKeys: eventDateKeys,
                dailyDecodeResult: dailyDecodeResult,
                dailyByDate: dailyByDate,
                state: &state
            )
            let changedByReconcile = reconcileEventFiles(eventDateKeys: eventDateKeys, state: &state)
            changedState = changedState || changedByRebuild || changedByReconcile

            let tasks = makeMaintenanceTasks(
                state: &state,
                dailyByDate: dailyByDate,
                changedState: &changedState
            )

            if changedState {
                try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            }

            return tasks
        }
    }

    private func markRebuildDates(
        eventDateKeys: [String],
        dailyDecodeResult: JSONLinesDecodeResult<ActivityAggregate>,
        dailyByDate: [String: ActivityAggregate],
        state: inout HistoryMaintenanceState
    ) -> Bool {
        var changed = false

        if state.version != HistoryMaintenanceState.currentVersion {
            changed = state.markDirty(contentsOf: eventDateKeys) || changed
            state.version = HistoryMaintenanceState.currentVersion
            changed = true
        }

        if dailyDecodeResult.failedLineCount > 0 || (dailyDecodeResult.values.isEmpty && !eventDateKeys.isEmpty) {
            changed = state.markDirty(contentsOf: eventDateKeys) || changed
        }

        changed = state.markDirty(contentsOf: eventDateKeys.filter { dailyByDate[$0] == nil }) || changed
        changed = state.markDirty(contentsOf: state.pending.filter { dailyByDate[$0] == nil }) || changed

        return changed
    }

    private func reconcileEventFiles(
        eventDateKeys: [String],
        state: inout HistoryMaintenanceState
    ) -> Bool {
        verifiedBoundaries = verifiedBoundaries.filter { state.days[$0.key] != nil }
        var changed = state.markDirty(contentsOf: eventDateKeys.filter { state.days[$0] == nil })

        for dateKey in eventDateKeys {
            guard let stat = HistoryStorage.fileStat(at: eventLogURL(for: dateKey)) else {
                continue
            }

            changed = state.ensureGenerationID(
                for: dateKey,
                fileIdentifier: stat.identifier
            ) || changed
            guard let day = state.days[dateKey] else {
                continue
            }

            let identifierChanged = day.fileIdentifier != nil
                && day.fileIdentifier != stat.identifier
            let boundaryChanged = hasBoundaryChanged(dateKey: dateKey, day: day, stat: stat)

            if identifierChanged || stat.size < day.offset || boundaryChanged {
                state.startNewGeneration(
                    for: dateKey,
                    startedEmpty: stat.size == 0,
                    fileIdentifier: stat.identifier
                )
                changed = true
            } else if day.offset != day.size {
                state.markDirty(dateKey)
                changed = true
            } else if stat.size > day.offset,
                      !state.pending.contains(dateKey),
                      !state.dirty.contains(dateKey) {
                state.markPending(dateKey)
                changed = true
            }
        }

        return changed
    }

    /// boundaryHash 覆盖 offset 之前的边界片段, 追加只写在 offset 之后
    /// 文件未修改时复用已有哈希, 减少持锁时间和采集器的等待
    private func hasBoundaryChanged(
        dateKey: String,
        day: HistoryDayMaintenanceState,
        stat: HistoryFileStat
    ) -> Bool {
        guard let recordedHash = day.boundaryHash else {
            return false
        }

        // 只有完整 stat 可以跳过校验, 毫秒精度不能区分同毫秒内的改写
        if let verified = verifiedBoundaries[dateKey],
           verified.offset == day.offset, verified.digest == recordedHash, verified.stat == stat {
            return false
        }

        guard (try? eventLogBoundaryHash(for: dateKey, endingAt: day.offset)) == recordedHash else {
            verifiedBoundaries.removeValue(forKey: dateKey)
            return true
        }

        verifiedBoundaries[dateKey] = HistoryBoundaryVerification(offset: day.offset, digest: recordedHash, stat: stat)
        return false
    }

    private func makeMaintenanceTasks(
        state: inout HistoryMaintenanceState,
        dailyByDate: [String: ActivityAggregate],
        changedState: inout Bool
    ) -> [HistoryMaintenanceTask] {
        let dirty = Set(state.dirty)
        var tasks: [HistoryMaintenanceTask] = state.dirty.compactMap { dateKey in
            guard let day = state.days[dateKey] else {
                return nil
            }
            return dirtyTask(
                for: dateKey,
                day: day,
                eventCountAvailability: dailyByDate[dateKey]?
                    .eventCountAvailability ?? .legacy
            )
        }

        for dateKey in state.pending where !dirty.contains(dateKey) {
            let day = state.days[dateKey] ?? HistoryDayMaintenanceState()
            let size = eventLogSize(for: dateKey)
            guard size > day.offset else {
                state.removePending(dateKey)
                changedState = true
                continue
            }

            let existingAggregate = dailyByDate[dateKey]
            guard let baseAggregate = existingAggregate,
                  baseAggregate.generationID == day.generationID else {
                state.markDirty(dateKey)
                changedState = true
                tasks.append(dirtyTask(
                    for: dateKey,
                    day: day,
                    size: size,
                    eventCountAvailability: existingAggregate?
                        .eventCountAvailability ?? .legacy
                ))
                continue
            }

            // ID 已压缩的聚合无法判断追加事件是否属于已有 session 或 turn
            // 任何不能证明与全量结果等价的增量任务都降级为完整重建
            guard retainsIdentifiers(for: dateKey),
                  baseAggregate.supportsIncrementalAggregation else {
                state.markDirty(dateKey)
                changedState = true
                tasks.append(dirtyTask(
                    for: dateKey,
                    day: day,
                    size: size,
                    eventCountAvailability: baseAggregate.eventCountAvailability
                ))
                continue
            }

            tasks.append(
                pendingTask(
                    for: dateKey,
                    day: day,
                    size: size,
                    baseAggregate: baseAggregate
                )
            )
        }

        return tasks
    }

    private func dirtyTask(
        for dateKey: String,
        day: HistoryDayMaintenanceState,
        size: UInt64? = nil,
        eventCountAvailability: ActivityCountAvailability = .legacy
    ) -> HistoryMaintenanceTask {
        let stat = HistoryStorage.fileStat(at: eventLogURL(for: dateKey))
        return HistoryMaintenanceTask(
            dateKey: dateKey,
            startOffset: 0,
            size: size ?? stat?.size ?? 0,
            mode: .rebuild(eventCountAvailability),
            existingCorrupt: 0,
            generationID: day.generationID,
            generationStartedEmpty: day.generationStartedEmpty,
            fileIdentifier: stat?.identifier
        )
    }

    private func pendingTask(
        for dateKey: String,
        day: HistoryDayMaintenanceState,
        size: UInt64,
        baseAggregate: ActivityAggregate
    ) -> HistoryMaintenanceTask {
        HistoryMaintenanceTask(
            dateKey: dateKey,
            startOffset: day.offset,
            size: size,
            mode: .append(baseAggregate),
            existingCorrupt: day.corrupt,
            generationID: day.generationID,
            generationStartedEmpty: day.generationStartedEmpty,
            fileIdentifier: day.fileIdentifier
        )
    }

    // MARK: - 事件文件读取与聚合

    private func eventLogURL(for dateKey: String) -> URL {
        HistoryStorage.eventLogURL(for: dateKey, in: eventsDirectoryURL)
    }

    private func eventLogSize(for dateKey: String) -> UInt64 {
        HistoryStorage.fileSize(at: eventLogURL(for: dateKey))
    }

    private func eventLogBoundaryHash(
        for dateKey: String,
        endingAt offset: UInt64
    ) throws -> String? {
        guard offset > 0 else {
            return nil
        }

        let length = min(offset, 4 * 1024)
        let handle = try FileHandle(forReadingFrom: eventLogURL(for: dateKey))
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: offset - length)
        guard let data = try handle.read(upToCount: Int(length)),
              data.count == Int(length) else {
            throw CocoaError(.fileReadUnknown)
        }

        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func loadDailyAggregatesWithFailures() -> JSONLinesDecodeResult<ActivityAggregate> {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return JSONLinesDecodeResult(values: [], failedLineCount: 0)
        }

        return JSONLines.decodeWithFailures(from: data)
    }

    private func eventDateKeys() -> [String] {
        HistoryStorage.eventLogDateKeys(in: eventsDirectoryURL)
    }

    private func buildDailyAggregate(
        for task: HistoryMaintenanceTask
    ) throws -> HistoryMaintenanceResult {
        var accumulator = switch task.mode {
        case let .rebuild(eventCountAvailability):
            ActivityAccumulator(
                rebuilding: task.dateKey,
                generationID: task.generationID,
                generationStartedEmpty: task.generationStartedEmpty,
                eventCountAvailability: eventCountAvailability
            )
        case let .append(baseAggregate):
            ActivityAccumulator(
                appending: baseAggregate,
                generationID: task.generationID,
                generationStartedEmpty: task.generationStartedEmpty
            )
        }
        var corrupt = task.existingCorrupt

        corrupt += try readEvents(
            at: eventLogURL(for: task.dateKey),
            from: task.startOffset,
            upTo: task.size
        ) { event in
            accumulator.record(event)
        }

        let identifierStorage: ActivityIdentifiers = retainsIdentifiers(for: task.dateKey)
            ? .retained
            : .compacted
        let aggregate = accumulator.finalized(identifierStorage: identifierStorage)
        return try HistoryMaintenanceResult(
            dateKey: task.dateKey,
            aggregate: aggregate,
            size: task.size,
            corrupt: corrupt,
            fileIdentifier: task.fileIdentifier,
            boundaryHash: eventLogBoundaryHash(for: task.dateKey, endingAt: task.size)
        )
    }

    private func readEvents(
        at url: URL,
        from startOffset: UInt64,
        upTo size: UInt64,
        record: (ActivityRecord) -> Void
    ) throws -> Int {
        guard size > startOffset else {
            return 0
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        try fileHandle.seek(toOffset: startOffset)

        var remainingBytes = size - startOffset
        var buffer = Data()
        var corrupt = 0

        // 分块读取防止大日志一次性进内存, 但仍按完整 JSONL 行解码
        while remainingBytes > 0 {
            let readSize = min(Int(remainingBytes), Self.eventReadChunkSize)
            guard let chunk = try fileHandle.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }

            remainingBytes -= UInt64(chunk.count)
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: JSONLines.newlineByte) {
                let lineData = buffer[..<newlineIndex]
                corrupt += Self.decode(lineData, record: record)
                buffer.removeSubrange(...newlineIndex)
            }
        }

        if !buffer.isEmpty {
            corrupt += Self.decode(buffer, record: record)
        }

        return corrupt
    }

    nonisolated static func decode(
        _ lineData: Data.SubSequence,
        record: (ActivityRecord) -> Void
    ) -> Int {
        guard let line = String(bytes: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return 1
        }

        guard !line.isEmpty else {
            return 0
        }

        guard let data = line.data(using: .utf8),
              let entry = try? AppServerEventRecord.decode(from: data) else {
            return 1
        }

        if let event = entry.activity {
            record(event)
        }
        return 0
    }

    // MARK: - 落盘与状态提交

    /// 返回聚合与维护状态是否都基于同一份事件源完成提交
    private func commit(
        _ result: HistoryMaintenanceResult,
        aggregates: inout [ActivityAggregate]
    ) throws -> Bool {
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var state = HistoryStorage.loadMaintenanceState(in: directoryURL)
            guard let currentSize = try validatedEventLogSize(for: result, state: &state) else { return false }
            if state.days[result.dateKey]?.requiresCloudReplacement == true, result.corrupt > 0 {
                throw HistoryDataRebuildError.incompleteSource
            }
            // 两个文件提交前先标脏, 中途退出会从事件重建, 不沿旧偏移重复追加
            state.markDirty(result.dateKey)
            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            aggregates = loadDailyAggregates() ?? []
            try writeDailyAggregate(result.aggregate, into: &aggregates)
            state.days[result.dateKey] = HistoryDayMaintenanceState(
                requiresCloudReplacement: state.days[result.dateKey]?.requiresCloudReplacement ?? false,
                offset: result.size, size: result.size, corrupt: result.corrupt,
                generationID: result.aggregate.generationID,
                generationStartedEmpty: result.aggregate.generationStartedEmpty,
                fileIdentifier: result.fileIdentifier, boundaryHash: result.boundaryHash
            )
            state.removeDirty(result.dateKey)
            if currentSize == result.size {
                state.removePending(result.dateKey)
            } else {
                state.markPending(result.dateKey)
            }
            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            return true
        }
    }

    /// 锁内确认读取期间仍是同一份追加源; 断代时换 generation 并等待重建
    private func validatedEventLogSize(
        for result: HistoryMaintenanceResult,
        state: inout HistoryMaintenanceState
    ) throws -> UInt64? {
        guard state.days[result.dateKey]?.generationID == result.aggregate.generationID else {
            return nil
        }

        let stat = HistoryStorage.fileStat(at: eventLogURL(for: result.dateKey))
        let identifierMatches = result.fileIdentifier == nil
            || result.fileIdentifier == stat?.identifier
        let boundaryMatches = (try? eventLogBoundaryHash(
            for: result.dateKey,
            endingAt: result.size
        )) == result.boundaryHash

        guard let stat,
              stat.size >= result.size,
              identifierMatches,
              boundaryMatches else {
            state.startNewGeneration(
                for: result.dateKey,
                startedEmpty: stat?.size == 0,
                fileIdentifier: stat?.identifier
            )
            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            return nil
        }

        return stat.size
    }

    private func writeDailyAggregate(
        _ aggregate: ActivityAggregate,
        into aggregates: inout [ActivityAggregate]
    ) throws {
        try FileManager.default.createDirectory(
            at: dailyLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        upsert(aggregate, into: &aggregates)
        aggregates = ActivityAggregate.normalized(aggregates: aggregates)
        let data = try ActivityAggregate.encodeJSONLines(aggregates)
        try data.write(to: dailyLogURL, options: .atomic)
    }

    private func normalizeDailyAggregatesIfNeeded() throws {
        guard let stat = HistoryStorage.fileStat(at: dailyLogURL), stat.size > 0 else {
            return
        }

        // 稳态下文件与日期都没变, 跳过全量解码与重编码比对
        let dayKey = HistoryStorage.dateKey(for: Date())
        if lastNormalizedDailyLog == HistoryDailyLogStamp(size: stat.size, identifier: stat.identifier, dayKey: dayKey) {
            return
        }

        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return
        }

        let decodeResult = JSONLines.decodeWithFailures(ActivityAggregate.self, from: data)
        guard decodeResult.failedLineCount == 0 else {
            return
        }

        let normalizedAggregates = ActivityAggregate.normalized(aggregates: decodeResult.values)
        let normalizedData = try ActivityAggregate.encodeJSONLines(normalizedAggregates)
        if normalizedData != data {
            try FileManager.default.createDirectory(
                at: dailyLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedData.write(to: dailyLogURL, options: .atomic)
        }

        if let latestStat = HistoryStorage.fileStat(at: dailyLogURL) {
            lastNormalizedDailyLog = HistoryDailyLogStamp(
                size: latestStat.size,
                identifier: latestStat.identifier,
                dayKey: dayKey
            )
        }
    }

    private func upsert(_ aggregate: ActivityAggregate, into aggregates: inout [ActivityAggregate]) {
        if let index = aggregates.firstIndex(where: { $0.date == aggregate.date }) {
            aggregates[index] = aggregate
        } else {
            aggregates.append(aggregate)
        }
    }

    private func markDirty(_ dateKey: String) {
        do {
            try HistoryStorage.withExclusiveLock(in: directoryURL) {
                var state = HistoryStorage.loadMaintenanceState(in: directoryURL)
                state.markDirty(dateKey)
                try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            }
        } catch {
            // 标记丢了下一轮就不会重建这天, 数据会静默缺一块
            let details = LogFields.joined(
                "stage=markDirty",
                "date=\(dateKey)",
                "detail=\(error.localizedDescription)"
            )
            AppLog.history.error("事件汇总失败: \(details, privacy: .public)")
        }
    }

    // MARK: - 保留期清理

    @discardableResult
    private func pruneExpiredEventFiles() throws -> Int {
        let cutoffDate = HistoryStorage.retentionCutoffDate()
        let expiredDateKeys = eventDateKeys().filter { dateKey in
            guard let date = CodexDateFormat.dayDate(from: dateKey) else {
                return false
            }

            return date < cutoffDate
        }

        guard !expiredDateKeys.isEmpty else {
            return 0
        }

        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var state = HistoryStorage.loadMaintenanceState(in: directoryURL)
            for dateKey in expiredDateKeys {
                try? FileManager.default.removeItem(at: eventLogURL(for: dateKey))
                state.remove(dateKey)
            }

            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
        }
        // 保留期到点会真的删掉原始事件文件, 数据对不上时要能查到哪些日期被清掉了
        let details = LogFields.joined(
            "dates=\(expiredDateKeys.count)",
            "oldest=\(expiredDateKeys.first ?? "-")"
        )
        AppLog.history.notice("过期事件已清理: \(details, privacy: .public)")
        return expiredDateKeys.count
    }

    private func retainsIdentifiers(for dateKey: String) -> Bool {
        guard let date = CodexDateFormat.dayDate(from: dateKey) else {
            return true
        }

        return date >= HistoryStorage.identifierRetentionCutoffDate()
    }
}

/// 完整精度的校验结果只在当前进程复用
private nonisolated struct HistoryBoundaryVerification {
    let offset: UInt64
    let digest: String
    let stat: HistoryFileStat
}

/// Aggregates/activity.jsonl 某一时刻的 stat 快照与当天日期键, 用于跳过稳态下的重复归一化
private nonisolated struct HistoryDailyLogStamp: Equatable {
    let size: UInt64
    let identifier: UInt64?
    let dayKey: String
}

/// 全量重建与安全增量使用不同初始状态, 避免用 nil 隐含任务语义
private nonisolated enum HistoryMaintenanceMode {
    case rebuild(ActivityCountAvailability)
    case append(ActivityAggregate)
}

// 单次维护任务: 从 startOffset 读到 size, 可基于已有聚合继续追加
private nonisolated struct HistoryMaintenanceTask {
    let dateKey: String
    let startOffset: UInt64
    let size: UInt64
    let mode: HistoryMaintenanceMode
    let existingCorrupt: Int
    let generationID: String?
    let generationStartedEmpty: Bool
    let fileIdentifier: UInt64?

    var baseEventCount: Int {
        switch mode {
        case .rebuild:
            0
        case let .append(aggregate):
            aggregate.eventCount ?? 0
        }
    }
}

/// 维护任务的提交结果, corrupt 统计保留给后续诊断
private nonisolated struct HistoryMaintenanceResult {
    let dateKey: String
    let aggregate: ActivityAggregate
    let size: UInt64
    let corrupt: Int
    let fileIdentifier: UInt64?
    let boundaryHash: String?
}

nonisolated struct HistoryDataRebuildSummary: Equatable, Sendable {
    let rebuiltDateCount: Int
    let eventCount: Int
    let isSyncReplacementPending: Bool
    let failedDateKeys: [String]
    let failedRequestDateKeys: [String]
    let failedTokenDateKeys: [String]
    let tokenTurnCount: Int
    let didFailTokenRebuild: Bool
}

nonisolated struct HistoryDataRebuildOutcome {
    let snapshot: HistorySnapshot
    let summary: HistoryDataRebuildSummary
}

private nonisolated enum HistoryDataRebuildError: LocalizedError {
    case sourceUnavailable
    case sourceChanged
    case incompleteSource

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            String(localized: "history.rebuild.error.source-unavailable")
        case .sourceChanged:
            String(localized: "history.rebuild.error.source-changed")
        case .incompleteSource:
            String(localized: "history.rebuild.error.incomplete-source")
        }
    }
}
