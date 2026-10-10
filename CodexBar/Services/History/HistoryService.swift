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
    private var lastRetentionCutoff: Date?

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
        let decoded = try? loadDailyAggregatesWithFailures()
        var snapshot = await makeSnapshot(
            localAggregates: decoded?.compatibilityError == nil ? ActivityAggregate.normalized(aggregates: decoded?.values ?? []) : [],
            synchronize: synchronize,
            trigger: trigger
        )
        snapshot.isActivityComplete = snapshot.isActivityComplete && decoded != nil
            && decoded?.compatibilityError == nil && decoded?.failedLineCount == 0
        return snapshot
    }

    /// 先跑一轮维护再取快照
    /// counts 为 nil 表示这一轮空转, 由调用方决定记不记日志
    func loadSnapshotWithMaintenance(
        synchronize: Bool,
        trigger: LogTrigger,
        now: Date = Date()
    ) async -> (snapshot: HistorySnapshot, counts: HistoryMaintenanceCounts?) {
        await syncService.pruneLocalCaches(now: now)
        let counts = performMaintenanceIfNeeded(now: now)
        let snapshot = await loadSnapshot(synchronize: synchronize, trigger: trigger)
        return (snapshot, counts)
    }

    private func makeSnapshot(
        localAggregates: [ActivityAggregate],
        synchronize: Bool,
        trigger: LogTrigger,
        localTokenTurns: [TokenTurn]? = nil
    ) async -> HistorySnapshot {
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
                tokenTurns = await (try? tokenHistory.persistedTurns()) ?? []
            }
        }
        let maintenance = try? HistoryStorage.loadMaintenanceState(in: directoryURL)
        let uploadable = localAggregates.filter { aggregate in
            guard let state = maintenance, !state.dirty.contains(aggregate.date),
                  let day = state.days[aggregate.date] else { return false }
            return day.generationID == aggregate.generationID && day.offset == aggregate.sourceCheckpoint?.byteCount
        }
        let syncSnapshot: SyncSnapshot = if synchronize {
            await syncService.synchronizeIfEnabled(
                localAggregates: uploadable, localTokenTurns: tokenTurns,
                recoveredTokenIDs: tokenHistory.pendingRecoveryIDs(), trigger: trigger
            )
        } else {
            await syncService.snapshotFromCacheIfEnabled(localTokenTurns: tokenTurns)
        }
        var snapshot = HistorySnapshot(
            localAggregates: localAggregates,
            syncedRecords: syncSnapshot.records,
            currentDeviceID: syncSnapshot.currentDeviceID
        )
        snapshot.tokenUsageByDate = syncSnapshot.tokenUsageByDate ?? TokenTurn.dailyUsage(tokenTurns)
        snapshot.isActivityComplete = snapshot.isActivityComplete && syncSnapshot.isActivityComplete && maintenance != nil
        let knownDates = Set(localAggregates.map(\.date)).union(
            syncSnapshot.records.filter { $0.deviceID == syncSnapshot.currentDeviceID }.map(\.date)
        )
        snapshot.unavailableActivityDates.formUnion(Set(maintenance?.dirty ?? []).subtracting(knownDates))
        return snapshot
    }

    /// 从指定日期的原始事件重建, 同一来源继续使用同一云端记录
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
        let activitySyncPending = await syncService.hasPendingActivityUpdates(local: loadDailyAggregates() ?? [])
        let tokenFailures = didFailTokenRebuild ? normalizedDateKeys : tokenResult.failedDateKeys
        let summary = HistoryDataRebuildSummary(
            rebuiltDateCount: Set(rebuildResults.map(\.dateKey)).union(tokenResult.dateKeys)
                .subtracting(failedDateKeys).subtracting(tokenFailures).count,
            eventCount: rebuildResults.reduce(0) { $0 + ($1.aggregate.eventCount ?? 0) },
            isSyncPending: activitySyncPending || tokenSyncPending,
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

    private func loadDailyAggregates() -> [ActivityAggregate]? {
        guard let decoded = try? loadDailyAggregatesWithFailures(), decoded.compatibilityError == nil else { return nil }
        return ActivityAggregate.normalized(aggregates: decoded.values)
    }

    // MARK: - 重建与维护调度

    private func rebuildLocalData(for dateKey: String, requestWasSaved: inout Bool) throws -> HistoryMaintenanceResult {
        var aggregates = loadDailyAggregates() ?? []
        let eventCountAvailability = aggregates
            .first(where: { $0.date == dateKey })?
            .eventCountAvailability ?? .all
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

            var state = try HistoryStorage.loadMaintenanceState(in: directoryURL)
            let header = try AppServerEventJournal.header(at: eventLogURL(for: dateKey))
            guard header.date == dateKey else { throw StorageCompatibilityError.sourceConflict }
            if state.days[dateKey]?.generationID != header.generationID {
                state.days[dateKey] = HistoryDayMaintenanceState(generationID: header.generationID, fileIdentifier: stat.identifier)
            }
            state.markDirty(dateKey)
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
            guard let day = try HistoryStorage.loadMaintenanceState(in: directoryURL).days[result.dateKey] else {
                return false
            }
            return day.generationID == result.aggregate.generationID
                && day.offset == result.size
        }) ?? false
    }

    /// 空转的一轮返回 nil
    /// 维护跟随额度刷新执行, 只记录有实际工作的轮次, 避免空闲时持续产生重复日志
    /// 收尾日志由 SyncScheduler 统一记, 这里只负责判断有没有值得记的东西
    private func performMaintenanceIfNeeded(now: Date) -> HistoryMaintenanceCounts? {
        let duration = LogDuration()
        var counts = HistoryMaintenanceCounts()
        var stage = MaintenanceStage.prepare
        do {
            stage = .prune
            counts.pruned = try pruneExpiredEventFiles(now: now)
            stage = .prepare
            let tasks = try prepareMaintenanceTasks()
            stage = .write
            let didCommitDailyLog = perform(tasks, counts: &counts)
            // 成功提交前已整体归一化, 没有完整提交时再做一次稳态检查
            if !didCommitDailyLog {
                try normalizeDailyAggregatesIfNeeded()
            }
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
                    "action=retry"
                )
                AppLog.history.error("事件汇总失败: \(details, privacy: .public)")
                if case .rebuild = task.mode {
                    markDirty(task.dateKey)
                }
            }
        }

        return didCommit
    }

    private func prepareMaintenanceTasks() throws -> [HistoryMaintenanceTask] {
        let eventDateKeys = try eventDateKeys()
        let dailyDecodeResult = try loadDailyAggregatesWithFailures()
        if let error = dailyDecodeResult.compatibilityError {
            throw error
        }

        return try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var state = try HistoryStorage.loadMaintenanceState(in: directoryURL)
            var changedState = state.normalize()
            let dailyByDate = dailyDecodeResult.values.reduce(into: [String: ActivityAggregate]()) { result, aggregate in
                result[aggregate.date] = aggregate
            }

            let changedByRebuild = markRebuildDates(
                eventDateKeys: eventDateKeys,
                dailyByDate: dailyByDate,
                state: &state
            )
            let changedByReconcile = try reconcileEventFiles(eventDateKeys: eventDateKeys, dailyByDate: dailyByDate, state: &state)
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
        dailyByDate: [String: ActivityAggregate],
        state: inout HistoryMaintenanceState
    ) -> Bool {
        var changed = false

        changed = state.markDirty(contentsOf: eventDateKeys.filter { dailyByDate[$0] == nil }) || changed
        changed = state.markDirty(contentsOf: state.pending.filter { dailyByDate[$0] == nil }) || changed

        return changed
    }

    private func reconcileEventFiles(
        eventDateKeys: [String],
        dailyByDate: [String: ActivityAggregate],
        state: inout HistoryMaintenanceState
    ) throws -> Bool {
        verifiedBoundaries = verifiedBoundaries.filter { state.days[$0.key] != nil }
        var changed = false

        for dateKey in eventDateKeys {
            guard let stat = HistoryStorage.fileStat(at: eventLogURL(for: dateKey)) else {
                continue
            }

            let header: AppServerEventJournal.Header
            do {
                header = try AppServerEventJournal.header(at: eventLogURL(for: dateKey))
                guard header.date == dateKey else { throw StorageCompatibilityError.sourceConflict }
            } catch {
                changed = state.markDirty(dateKey) || changed
                continue
            }
            if state.days[dateKey] == nil, let aggregate = dailyByDate[dateKey],
               aggregate.generationID == header.generationID, let checkpoint = aggregate.sourceCheckpoint,
               !hasBoundaryChanged(dateKey: dateKey, checkpoint: checkpoint, stat: stat) {
                state.days[dateKey] = HistoryDayMaintenanceState(
                    offset: checkpoint.byteCount, size: checkpoint.byteCount,
                    generationID: header.generationID, fileIdentifier: stat.identifier
                )
                changed = true
            } else if state.days[dateKey]?.generationID != header.generationID {
                state.days[dateKey] = HistoryDayMaintenanceState(generationID: header.generationID, fileIdentifier: stat.identifier)
                changed = state.markDirty(dateKey) || changed
            }
            guard let day = state.days[dateKey] else {
                continue
            }

            let identifierChanged = day.fileIdentifier != nil
                && day.fileIdentifier != stat.identifier
            let boundaryChanged = hasBoundaryChanged(dateKey: dateKey, checkpoint: dailyByDate[dateKey]?.sourceCheckpoint, stat: stat)

            if identifierChanged || stat.size < day.offset || boundaryChanged {
                state.markDirty(dateKey)
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

    /// 完整前缀校验避免日志中部改写被误认成普通追加, 文件未变时复用校验结果
    private func hasBoundaryChanged(dateKey: String, checkpoint: ActivitySourceCheckpoint?, stat: HistoryFileStat) -> Bool {
        guard let checkpoint else { return true }
        if let verified = verifiedBoundaries[dateKey],
           verified.offset == checkpoint.byteCount, verified.digest == checkpoint.digest, verified.stat == stat {
            return false
        }
        guard checkpoint.matchesSource(try? ActivitySourceCheckpoint.read(at: eventLogURL(for: dateKey), byteCount: checkpoint.byteCount)) else {
            verifiedBoundaries.removeValue(forKey: dateKey)
            return true
        }
        verifiedBoundaries[dateKey] = HistoryBoundaryVerification(offset: checkpoint.byteCount, digest: checkpoint.digest, stat: stat)
        return false
    }

    private func makeMaintenanceTasks(
        state: inout HistoryMaintenanceState,
        dailyByDate: [String: ActivityAggregate],
        changedState: inout Bool
    ) -> [HistoryMaintenanceTask] {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        let dirty = Set(state.dirty.filter { $0 >= cutoff })
        var tasks: [HistoryMaintenanceTask] = state.dirty.filter { $0 >= cutoff }.compactMap { dateKey in
            guard let day = state.days[dateKey] else {
                return nil
            }
            return dirtyTask(
                for: dateKey,
                day: day,
                eventCountAvailability: dailyByDate[dateKey]?
                    .eventCountAvailability ?? .all
            )
        }

        for dateKey in state.pending where dateKey >= cutoff && !dirty.contains(dateKey) {
            let day = state.days[dateKey] ?? HistoryDayMaintenanceState()
            let size = eventLogSize(for: dateKey)
            guard size > day.offset else {
                state.removePending(dateKey)
                changedState = true
                continue
            }

            let existingAggregate = dailyByDate[dateKey]
            guard let baseAggregate = existingAggregate,
                  baseAggregate.generationID == day.generationID,
                  baseAggregate.sourceCheckpoint?.byteCount == day.offset else {
                state.markDirty(dateKey)
                changedState = true
                tasks.append(dirtyTask(
                    for: dateKey,
                    day: day,
                    size: size,
                    eventCountAvailability: existingAggregate?
                        .eventCountAvailability ?? .all
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
        eventCountAvailability: ActivityCountAvailability = .all
    ) -> HistoryMaintenanceTask {
        let stat = HistoryStorage.fileStat(at: eventLogURL(for: dateKey))
        return HistoryMaintenanceTask(
            dateKey: dateKey,
            startOffset: 0,
            size: size ?? stat?.size ?? 0,
            mode: .rebuild(eventCountAvailability),
            existingCorrupt: 0,
            generationID: day.generationID,
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

    private func loadDailyAggregatesWithFailures() throws -> JSONLinesDecodeResult<ActivityAggregate> {
        do {
            return try JSONLines.decodeWithFailures(from: Data(contentsOf: dailyLogURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return JSONLinesDecodeResult(values: [], failedLineCount: 0)
        }
    }

    private func eventDateKeys() throws -> [String] {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate())
        return try HistoryStorage.readEventLogDateKeys(in: eventsDirectoryURL).filter { $0 >= cutoff }
    }

    private func buildDailyAggregate(
        for task: HistoryMaintenanceTask
    ) throws -> HistoryMaintenanceResult {
        var accumulator = switch task.mode {
        case let .rebuild(eventCountAvailability):
            ActivityAccumulator(
                rebuilding: task.dateKey,
                generationID: task.generationID,

                eventCountAvailability: eventCountAvailability
            )
        case let .append(baseAggregate):
            ActivityAccumulator(
                appending: baseAggregate,
                generationID: task.generationID
            )
        }
        var corrupt = task.existingCorrupt
        if case let .append(base) = task.mode, !base.supportsIncrementalAggregation {
            // 恢复去重身份不重新计算旧计数, 追加到压缩日期也不会改变历史口径
            corrupt += try readEvents(at: eventLogURL(for: task.dateKey), from: 0, upTo: task.startOffset) {
                accumulator.restoreIdentity(from: $0)
            }
        }

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
        var aggregate = accumulator.finalized(identifierStorage: identifierStorage)
        var checkpoint = try ActivitySourceCheckpoint.read(at: eventLogURL(for: task.dateKey), byteCount: task.size)
        let ranges: [AggregationRange] = switch task.mode {
        case .rebuild:
            []
        case let .append(base):
            base.sourceCheckpoint?.aggregationRanges.isEmpty == false
                ? base.sourceCheckpoint?.aggregationRanges ?? []
                : [AggregationRange(version: base.aggregationVersion, end: task.startOffset)]
        }
        checkpoint.aggregationRanges = AggregationRange.appending(to: ranges, version: AggregationVersion.activity, end: task.size)
        aggregate.aggregationVersion = AggregationVersion.activity
        aggregate.sourceCheckpoint = checkpoint
        return HistoryMaintenanceResult(
            dateKey: task.dateKey,
            aggregate: aggregate,
            size: task.size,
            corrupt: corrupt,
            fileIdentifier: task.fileIdentifier
        )
    }

    private func readEvents(
        at url: URL,
        from startOffset: UInt64,
        upTo size: UInt64,
        record: (ActivityRecord) -> Void
    ) throws -> Int {
        var corrupt = 0
        try AppServerEventJournal.read(at: url, from: startOffset, upTo: size, onInvalidLine: { corrupt += 1 }, consume: { entry in
            if let event = entry.activity {
                record(event)
            }
        })
        return corrupt
    }

    // MARK: - 落盘与状态提交

    /// 返回聚合与维护状态是否都基于同一份事件源完成提交
    private func commit(
        _ result: HistoryMaintenanceResult,
        aggregates: inout [ActivityAggregate]
    ) throws -> Bool {
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var state = try HistoryStorage.loadMaintenanceState(in: directoryURL)
            guard let currentSize = try validatedEventLogSize(for: result, state: &state) else { return false }
            if result.corrupt > 0 {
                throw HistoryDataRebuildError.incompleteSource
            }
            // 两个文件提交前先标脏, 中途退出会从事件重建, 不沿旧偏移重复追加
            state.markDirty(result.dateKey)
            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            aggregates = loadDailyAggregates() ?? []
            try writeDailyAggregate(result.aggregate, into: &aggregates)
            state.days[result.dateKey] = HistoryDayMaintenanceState(
                offset: result.size, size: result.size, corrupt: result.corrupt,
                generationID: result.aggregate.generationID,
                fileIdentifier: result.fileIdentifier
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

    /// 锁内确认读取期间仍是同一份追加源, 发生改写则等待重建
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
        let boundaryMatches = result.aggregate.sourceCheckpoint?.matchesSource(try? ActivitySourceCheckpoint.read(
            at: eventLogURL(for: result.dateKey), byteCount: result.size
        )) == true

        guard let stat,
              stat.size >= result.size,
              identifierMatches,
              boundaryMatches else {
            state.markDirty(result.dateKey)
            try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            return nil
        }

        return stat.size
    }

    private func writeDailyAggregate(
        _ aggregate: ActivityAggregate,
        into aggregates: inout [ActivityAggregate]
    ) throws {
        if let error = try loadDailyAggregatesWithFailures().compatibilityError {
            throw error
        }
        try FileManager.default.createDirectory(
            at: dailyLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        upsert(aggregate, into: &aggregates)
        aggregates = ActivityAggregate.normalized(aggregates: aggregates)
        let data = try ActivityAggregate.encodeJSONLines(aggregates)
        try data.write(to: dailyLogURL, options: .atomic)
    }

    func normalizeDailyAggregatesIfNeeded() throws {
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
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
            if let error = decodeResult.compatibilityError {
                throw error
            }
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
                var state = try HistoryStorage.loadMaintenanceState(in: directoryURL)
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
    private func pruneExpiredEventFiles(now: Date) throws -> Int {
        let cutoffDate = HistoryStorage.retentionCutoffDate(today: now)
        guard lastRetentionCutoff != cutoffDate else { return 0 }
        let expiredDateKeys = try HistoryStorage.withExclusiveLock(in: directoryURL) {
            let expiredDateKeys = try HistoryStorage.readEventLogDateKeys(in: eventsDirectoryURL).filter { dateKey in
                dateKey < HistoryStorage.dateKey(for: cutoffDate)
            }
            var state = try HistoryStorage.loadMaintenanceState(in: directoryURL)
            var failedDates = Set<String>()
            for dateKey in expiredDateKeys {
                do {
                    try AppServerEventJournal.read(at: eventLogURL(for: dateKey)) { _ in }
                    try FileManager.default.removeItem(at: eventLogURL(for: dateKey))
                } catch CocoaError.fileNoSuchFile {
                    continue
                } catch {
                    failedDates.insert(dateKey)
                    AppLog.history.error("过期事件清理失败: date=\(dateKey, privacy: .public) detail=\(error.localizedDescription, privacy: .public)")
                }
            }
            let cutoffKey = HistoryStorage.dateKey(for: cutoffDate)
            let expiredStateKeys = Set(state.days.keys).union(state.pending).union(state.dirty)
                .filter { $0 < cutoffKey && !failedDates.contains($0) }
            for dateKey in expiredStateKeys {
                state.remove(dateKey)
            }
            if !expiredStateKeys.isEmpty {
                try HistoryStorage.saveMaintenanceState(state, in: directoryURL)
            }
            return expiredDateKeys.filter { !failedDates.contains($0) }
        }
        // 单文件失败留待下一天或重启后重试, 避免刷新时反复扫描同一异常文件
        lastRetentionCutoff = cutoffDate
        guard !expiredDateKeys.isEmpty else { return 0 }
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
}

nonisolated struct HistoryDataRebuildSummary: Equatable, Sendable {
    let rebuiltDateCount: Int
    let eventCount: Int
    let isSyncPending: Bool
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
