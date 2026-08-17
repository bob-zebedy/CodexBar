import Combine
import CryptoKit
import Darwin
import Foundation
import os

/// 汇总失败时定位到哪一步, 只用于日志
private nonisolated enum MaintenanceStage: String {
    case prepare
    case write
    case prune
}

/// 一轮汇总的计数, 成功路径压进 WorkflowSyncScheduler 的收尾那一条日志, 不为每天单独记一行
/// dates 由三个分支相加得出, 不额外存一份
nonisolated struct WorkflowMaintenanceCounts {
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

/// 从 Hook 原始事件维护每日聚合, 对外只发布 UI 需要的统计快照
actor WorkflowService {
    private let eventsDirectoryURL: URL
    private let dailyLogURL: URL
    private let syncService: WorkflowSyncService
    /// 上次归一化时 daily.jsonl 的 stat 与当天日期键
    private var lastNormalizedDailyLog: WorkflowDailyLogStamp?
    /// 上一条维护日志之后连续空转的轮数, 记出去就清零
    private var idleMaintenanceRounds = 0
    private static let eventReadChunkSize = 64 * 1024

    init(
        eventsDirectoryURL: URL = WorkflowStorage.eventsDirectoryURL(),
        dailyLogURL: URL = WorkflowStorage.dailyURL(),
        syncService: WorkflowSyncService = WorkflowSyncService()
    ) {
        self.eventsDirectoryURL = eventsDirectoryURL
        self.dailyLogURL = dailyLogURL
        self.syncService = syncService
    }

    // MARK: - 快照读取

    func loadSnapshot(
        synchronize: Bool = false,
        trigger: LogTrigger = .auto
    ) async -> WorkflowSnapshot {
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
    ) async -> (snapshot: WorkflowSnapshot, counts: WorkflowMaintenanceCounts?) {
        let counts = performMaintenanceIfNeeded()
        let snapshot = await loadSnapshot(synchronize: synchronize, trigger: trigger)
        return (snapshot, counts)
    }

    private func makeSnapshot(
        localAggregates: [WorkflowDailyAggregate],
        synchronize: Bool,
        trigger: LogTrigger
    ) async -> WorkflowSnapshot {
        let syncSnapshot: WorkflowSyncSnapshot = if synchronize {
            await syncService.synchronizeIfEnabled(localAggregates: localAggregates, trigger: trigger)
        } else {
            await syncService.snapshotFromCacheIfEnabled()
        }

        guard !localAggregates.isEmpty || !syncSnapshot.records.isEmpty else {
            return .empty
        }

        return WorkflowSnapshot(
            localAggregates: localAggregates,
            syncedRecords: syncSnapshot.records,
            currentDeviceId: syncSnapshot.currentDeviceId
        )
    }

    /// 以指定日期范围内的本机原始事件为权威来源重建, 并安排替换当前设备的同日云端贡献
    fileprivate func rebuildData(
        for dateKeys: [String],
        synchronize: Bool
    ) async throws -> WorkflowDataRebuildOutcome {
        let duration = LogDuration()
        let normalizedDateKeys = Set(dateKeys).sorted()
        guard !normalizedDateKeys.isEmpty else {
            throw WorkflowDataRebuildError.sourceUnavailable
        }

        // 单日失败不中止整批: 失败的日期已被 rebuildLocalData 标脏, 常规维护会自动重建
        // 中止会让「前几天已改写, 后几天没碰」这个事实完全不被上报
        var rebuildResults = [WorkflowMaintenanceResult]()
        var failedDateKeys = [String]()
        var firstFailure: Error?
        for dateKey in normalizedDateKeys {
            do {
                try rebuildResults.append(rebuildLocalData(for: dateKey))
            } catch {
                // 整批成功时这个原因不会往上抛, 摘要只带得走日期
                let details = LogFields.joined(
                    "stage=date",
                    "date=\(dateKey)",
                    "detail=\(error.localizedDescription)"
                )
                AppLog.workflow.error("数据重建失败: \(details, privacy: .public)")
                failedDateKeys.append(dateKey)
                if firstFailure == nil {
                    firstFailure = error
                }
            }
        }

        // 成功与失败的日期都要登记: 失败的日期稍后会被自动重建并推进 sourceGeneration,
        // 届时会上传到新的 record ID, 不清理旧记录会在云端留下同日重复的贡献
        // 全部失败时同样要登记, 它们一样已被标脏
        var didFailReplacementMarking = false
        do {
            try await syncService.markReplacementNeeded(for: normalizedDateKeys)
        } catch {
            let details = LogFields.joined(
                "stage=replacementMarking",
                "dates=\(normalizedDateKeys.count)",
                "detail=\(error.localizedDescription)"
            )
            AppLog.workflow.error("数据重建失败: \(details, privacy: .public)")
            didFailReplacementMarking = true
        }

        // 一天都没成功才算整体失败, 并保留首个真实原因而非笼统报「数据发生变化」
        guard !rebuildResults.isEmpty else {
            throw firstFailure ?? WorkflowDataRebuildError.sourceUnavailable
        }

        // 重建只由设置页的用户操作发起
        let snapshot = await makeSnapshot(
            localAggregates: loadDailyAggregates() ?? [],
            synchronize: synchronize,
            trigger: .manual
        )
        let summary = await WorkflowDataRebuildSummary(
            rebuiltDateCount: rebuildResults.count,
            eventCount: rebuildResults.reduce(0) { $0 + ($1.aggregate.eventCount ?? 0) },
            corruptLineCount: rebuildResults.reduce(0) { $0 + $1.corrupt },
            isSyncReplacementPending: syncService.hasPendingReplacement(for: normalizedDateKeys),
            failedDateKeys: failedDateKeys,
            didFailSyncReplacementMarking: didFailReplacementMarking
        )
        let elapsed = duration.elapsed
        let details = LogFields.joined(
            "dates=\(summary.rebuiltDateCount)",
            "events=\(summary.eventCount)",
            "corruptLines=\(summary.corruptLineCount)",
            "failedDates=\(failedDateKeys.count)",
            "elapsed=\(elapsed)"
        )
        AppLog.workflow.notice("数据重建完成: \(details, privacy: .public)")
        return WorkflowDataRebuildOutcome(snapshot: snapshot, summary: summary)
    }

    private func loadDailyAggregates() -> [WorkflowDailyAggregate]? {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return nil
        }

        let aggregates: [WorkflowDailyAggregate] = JSONLines.decode(from: data)
        guard !aggregates.isEmpty else {
            return nil
        }

        return WorkflowDailyAggregate.normalized(aggregates: aggregates)
    }

    // MARK: - 重建与维护调度

    private func rebuildLocalData(for dateKey: String) throws -> WorkflowMaintenanceResult {
        var aggregates = loadDailyAggregates() ?? []
        let hookCountAvailability = aggregates
            .first(where: { $0.date == dateKey })?
            .hookCountAvailability ?? .all
        let task = try prepareRebuildTask(
            for: dateKey,
            hookCountAvailability: hookCountAvailability
        )

        do {
            let result = try buildDailyAggregate(for: task)
            guard try commit(result, aggregates: &aggregates),
                  rebuildWasCommitted(result) else {
                throw WorkflowDataRebuildError.sourceChanged
            }
            return result
        } catch {
            markDirty(dateKey)
            throw error
        }
    }

    private func prepareRebuildTask(
        for dateKey: String,
        hookCountAvailability: WorkflowHookCountAvailability
    ) throws -> WorkflowMaintenanceTask {
        let retentionCutoffKey = WorkflowStorage.dateKey(for: WorkflowStorage.retentionCutoffDate())
        guard WorkflowStorage.isValidDateKey(dateKey), dateKey >= retentionCutoffKey else {
            throw WorkflowDataRebuildError.sourceUnavailable
        }

        return try WorkflowStorage.withExclusiveLock {
            guard let stat = WorkflowStorage.fileStat(at: eventLogURL(for: dateKey)),
                  stat.size > 0 else {
                throw WorkflowDataRebuildError.sourceUnavailable
            }

            var state = WorkflowStorage.loadMaintenanceState()
            state.startNewSourceGeneration(
                for: dateKey,
                isFresh: false,
                fileIdentifier: stat.identifier
            )
            try WorkflowStorage.saveMaintenanceState(state)

            guard let day = state.days[dateKey] else {
                throw WorkflowDataRebuildError.sourceUnavailable
            }
            return dirtyTask(
                for: dateKey,
                day: day,
                size: stat.size,
                hookCountAvailability: hookCountAvailability
            )
        }
    }

    private func rebuildWasCommitted(_ result: WorkflowMaintenanceResult) -> Bool {
        let dailyGeneration = loadDailyAggregates()?
            .first(where: { $0.date == result.dateKey })?
            .sourceGeneration
        guard dailyGeneration == result.aggregate.sourceGeneration else {
            return false
        }

        return (try? WorkflowStorage.withExclusiveLock {
            guard let day = WorkflowStorage.loadMaintenanceState().days[result.dateKey] else {
                return false
            }
            return day.sourceGeneration == result.aggregate.sourceGeneration
                && day.offset == result.size
        }) ?? false
    }

    /// 空转的一轮返回 nil
    /// 它跟着每 60 秒的额度刷新跑, 无条件记会让空闲机器每天多出上千条没有信息的日志
    /// 收尾日志由 WorkflowSyncScheduler 统一记, 这里只负责判断有没有值得记的东西
    private func performMaintenanceIfNeeded() -> WorkflowMaintenanceCounts? {
        let duration = LogDuration()
        var counts = WorkflowMaintenanceCounts()
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
            AppLog.workflow.error("事件汇总失败: \(details, privacy: .public)")
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
        _ tasks: [WorkflowMaintenanceTask],
        counts: inout WorkflowMaintenanceCounts
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
                    // 记本轮新摄入的量; 累加 eventCount 会变成当日总数, Hook 停写也看不出来
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
                AppLog.workflow.error("事件汇总失败: \(details, privacy: .public)")
                markDirty(task.dateKey)
            }
        }

        return didCommit
    }

    private func prepareMaintenanceTasks() throws -> [WorkflowMaintenanceTask] {
        let eventDateKeys = eventDateKeys()
        let dailyDecodeResult = loadDailyAggregatesWithFailures()

        return try WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()
            var changedState = state.normalize()
            let dailyByDate = dailyDecodeResult.values.reduce(into: [String: WorkflowDailyAggregate]()) { result, aggregate in
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
                try WorkflowStorage.saveMaintenanceState(state)
            }

            return tasks
        }
    }

    private func markRebuildDates(
        eventDateKeys: [String],
        dailyDecodeResult: JSONLinesDecodeResult<WorkflowDailyAggregate>,
        dailyByDate: [String: WorkflowDailyAggregate],
        state: inout WorkflowMaintenanceState
    ) -> Bool {
        var changed = false

        if state.schema != WorkflowMaintenanceState.currentAggregationSchema {
            changed = state.markDirty(contentsOf: eventDateKeys) || changed
            state.schema = WorkflowMaintenanceState.currentAggregationSchema
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
        state: inout WorkflowMaintenanceState
    ) -> Bool {
        var changed = state.markDirty(contentsOf: eventDateKeys.filter { state.days[$0] == nil })

        for dateKey in eventDateKeys {
            guard let stat = WorkflowStorage.fileStat(at: eventLogURL(for: dateKey)) else {
                continue
            }

            changed = state.ensureSourceGeneration(
                for: dateKey,
                fileIdentifier: stat.identifier
            ) || changed
            guard let day = state.days[dateKey] else {
                continue
            }

            let identifierChanged = day.fileIdentifier != nil
                && day.fileIdentifier != stat.identifier
            let boundary = boundaryStatus(dateKey: dateKey, day: day, stat: stat)
            if let verifiedAt = boundary.verifiedAtNanoseconds {
                changed = state.recordBoundaryVerification(
                    for: dateKey,
                    at: verifiedAt
                ) || changed
            }

            if identifierChanged || stat.size < day.offset || boundary.isChanged {
                state.startNewSourceGeneration(
                    for: dateKey,
                    isFresh: stat.size == 0,
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

    /// boundaryHash 覆盖的是 [offset-4KB, offset), 而追加只写在 offset 之后,
    /// 所以文件没被写过时那段字节不可能变化, 无需重算哈希.
    /// 保留期内可能有上百个历史文件, 每轮全量重算会显著拉长持锁时间,
    /// 而 Hook 子进程要等这把锁才能记录事件.
    /// 返回边界是否变化, 以及重算确认无变化时应记下的 mtime (无需记录时为 nil)
    private func boundaryStatus(
        dateKey: String,
        day: WorkflowDayMaintenanceState,
        stat: WorkflowFileStat
    ) -> (isChanged: Bool, verifiedAtNanoseconds: Int64?) {
        guard let recordedHash = day.boundaryHash else {
            return (false, nil)
        }

        // mtime 是主判据: 任何写入都会推进它, identifier 与 size 作为附加保险
        if day.boundaryVerifiedAtNanoseconds == stat.modifiedAtNanoseconds,
           day.fileIdentifier == stat.identifier,
           day.size == stat.size {
            return (false, nil)
        }

        guard (try? eventLogBoundaryHash(for: dateKey, endingAt: day.offset)) == recordedHash else {
            return (true, nil)
        }

        // 记下本次校验时的 mtime, 文件保持不动的话下一轮即可跳过
        return (false, stat.modifiedAtNanoseconds)
    }

    private func makeMaintenanceTasks(
        state: inout WorkflowMaintenanceState,
        dailyByDate: [String: WorkflowDailyAggregate],
        changedState: inout Bool
    ) -> [WorkflowMaintenanceTask] {
        let dirty = Set(state.dirty)
        var tasks: [WorkflowMaintenanceTask] = state.dirty.compactMap { dateKey in
            guard let day = state.days[dateKey] else {
                return nil
            }
            return dirtyTask(
                for: dateKey,
                day: day,
                hookCountAvailability: dailyByDate[dateKey]?
                    .hookCountAvailability ?? .all
            )
        }

        for dateKey in state.pending where !dirty.contains(dateKey) {
            let day = state.days[dateKey] ?? WorkflowDayMaintenanceState()
            let size = eventLogSize(for: dateKey)
            guard size > day.offset else {
                state.removePending(dateKey)
                changedState = true
                continue
            }

            let existingAggregate = dailyByDate[dateKey]
            guard let baseAggregate = existingAggregate,
                  baseAggregate.sourceGeneration == day.sourceGeneration else {
                state.markDirty(dateKey)
                changedState = true
                tasks.append(dirtyTask(
                    for: dateKey,
                    day: day,
                    size: size,
                    hookCountAvailability: existingAggregate?
                        .hookCountAvailability ?? .all
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
                    hookCountAvailability: baseAggregate.hookCountAvailability
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
        day: WorkflowDayMaintenanceState,
        size: UInt64? = nil,
        hookCountAvailability: WorkflowHookCountAvailability = .all
    ) -> WorkflowMaintenanceTask {
        let stat = WorkflowStorage.fileStat(at: eventLogURL(for: dateKey))
        return WorkflowMaintenanceTask(
            dateKey: dateKey,
            startOffset: 0,
            size: size ?? stat?.size ?? 0,
            mode: .rebuild(hookCountAvailability),
            existingCorrupt: 0,
            sourceGeneration: day.sourceGeneration,
            sourceIsFresh: day.sourceIsFresh,
            fileIdentifier: stat?.identifier
        )
    }

    private func pendingTask(
        for dateKey: String,
        day: WorkflowDayMaintenanceState,
        size: UInt64,
        baseAggregate: WorkflowDailyAggregate
    ) -> WorkflowMaintenanceTask {
        WorkflowMaintenanceTask(
            dateKey: dateKey,
            startOffset: day.offset,
            size: size,
            mode: .append(baseAggregate),
            existingCorrupt: day.corrupt,
            sourceGeneration: day.sourceGeneration,
            sourceIsFresh: day.sourceIsFresh,
            fileIdentifier: day.fileIdentifier
        )
    }

    // MARK: - 事件文件读取与聚合

    private func eventLogURL(for dateKey: String) -> URL {
        WorkflowStorage.eventLogURL(for: dateKey, in: eventsDirectoryURL)
    }

    private func eventLogSize(for dateKey: String) -> UInt64 {
        WorkflowStorage.fileSize(at: eventLogURL(for: dateKey))
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

    private func loadDailyAggregatesWithFailures() -> JSONLinesDecodeResult<WorkflowDailyAggregate> {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return JSONLinesDecodeResult(values: [], failedLineCount: 0)
        }

        return JSONLines.decodeWithFailures(from: data)
    }

    private func eventDateKeys() -> [String] {
        WorkflowStorage.eventLogDateKeys(in: eventsDirectoryURL)
    }

    private func buildDailyAggregate(
        for task: WorkflowMaintenanceTask
    ) throws -> WorkflowMaintenanceResult {
        var accumulator = switch task.mode {
        case let .rebuild(hookCountAvailability):
            WorkflowDailyAccumulator(
                rebuilding: task.dateKey,
                sourceGeneration: task.sourceGeneration,
                sourceIsFresh: task.sourceIsFresh,
                hookCountAvailability: hookCountAvailability
            )
        case let .append(baseAggregate):
            WorkflowDailyAccumulator(
                appending: baseAggregate,
                sourceGeneration: task.sourceGeneration,
                sourceIsFresh: task.sourceIsFresh
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

        let identifierStorage: WorkflowIdentifierStorage = retainsIdentifiers(for: task.dateKey)
            ? .retained
            : .compacted
        let aggregate = accumulator.finalized(identifierStorage: identifierStorage)
        return try WorkflowMaintenanceResult(
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
        record: (WorkflowHookEvent) -> Void
    ) throws -> Int {
        guard size > startOffset else {
            return 0
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        try fileHandle.seek(toOffset: startOffset)

        let decoder = JSONDecoder()
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
                corrupt += decode(lineData, using: decoder, record: record)
                buffer.removeSubrange(...newlineIndex)
            }
        }

        if !buffer.isEmpty {
            corrupt += decode(buffer, using: decoder, record: record)
        }

        return corrupt
    }

    private func decode(
        _ lineData: Data.SubSequence,
        using decoder: JSONDecoder,
        record: (WorkflowHookEvent) -> Void
    ) -> Int {
        guard let line = String(bytes: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return 1
        }

        guard !line.isEmpty else {
            return 0
        }

        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(WorkflowHookEvent.self, from: data) else {
            return 1
        }

        record(event)
        return 0
    }

    // MARK: - 落盘与状态提交

    /// 返回聚合与维护状态是否都基于同一份事件源完成提交
    private func commit(
        _ result: WorkflowMaintenanceResult,
        aggregates: inout [WorkflowDailyAggregate]
    ) throws -> Bool {
        guard try eventLogSourceIsValid(for: result) else {
            return false
        }

        // daily.jsonl 和 maintenance.json 分开写
        // 每次提交前后都检查事件文件是否被并发追加
        try writeDailyAggregate(result.aggregate, into: &aggregates)
        return try commitMaintenanceState(result)
    }

    private func eventLogSourceIsValid(for result: WorkflowMaintenanceResult) throws -> Bool {
        try WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()
            return try validatedEventLogSize(for: result, state: &state) != nil
        }
    }

    /// 锁内确认读取期间仍是同一份追加源; 断代时换 generation 并等待重建
    private func validatedEventLogSize(
        for result: WorkflowMaintenanceResult,
        state: inout WorkflowMaintenanceState
    ) throws -> UInt64? {
        guard state.days[result.dateKey]?.sourceGeneration == result.aggregate.sourceGeneration else {
            return nil
        }

        let stat = WorkflowStorage.fileStat(at: eventLogURL(for: result.dateKey))
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
            state.startNewSourceGeneration(
                for: result.dateKey,
                isFresh: stat?.size == 0,
                fileIdentifier: stat?.identifier
            )
            try WorkflowStorage.saveMaintenanceState(state)
            return nil
        }

        return stat.size
    }

    private func writeDailyAggregate(
        _ aggregate: WorkflowDailyAggregate,
        into aggregates: inout [WorkflowDailyAggregate]
    ) throws {
        try FileManager.default.createDirectory(
            at: dailyLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        upsert(aggregate, into: &aggregates)
        aggregates = WorkflowDailyAggregate.normalized(aggregates: aggregates)
        let data = try WorkflowDailyAggregate.encodeJSONLines(aggregates)
        try data.write(to: dailyLogURL, options: .atomic)
    }

    private func normalizeDailyAggregatesIfNeeded() throws {
        guard let stat = WorkflowStorage.fileStat(at: dailyLogURL), stat.size > 0 else {
            return
        }

        // 稳态下文件与日期都没变, 跳过全量解码与重编码比对
        let dayKey = WorkflowStorage.dateKey(for: Date())
        if lastNormalizedDailyLog == WorkflowDailyLogStamp(size: stat.size, identifier: stat.identifier, dayKey: dayKey) {
            return
        }

        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return
        }

        let decodeResult = JSONLines.decodeWithFailures(WorkflowDailyAggregate.self, from: data)
        guard decodeResult.failedLineCount == 0 else {
            return
        }

        let normalizedAggregates = WorkflowDailyAggregate.normalized(aggregates: decodeResult.values)
        let normalizedData = try WorkflowDailyAggregate.encodeJSONLines(normalizedAggregates)
        if normalizedData != data {
            try FileManager.default.createDirectory(
                at: dailyLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedData.write(to: dailyLogURL, options: .atomic)
        }

        if let latestStat = WorkflowStorage.fileStat(at: dailyLogURL) {
            lastNormalizedDailyLog = WorkflowDailyLogStamp(
                size: latestStat.size,
                identifier: latestStat.identifier,
                dayKey: dayKey
            )
        }
    }

    /// 返回第二次源校验后是否真正推进了维护状态
    private func commitMaintenanceState(_ result: WorkflowMaintenanceResult) throws -> Bool {
        try WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()

            guard let currentSize = try validatedEventLogSize(for: result, state: &state) else {
                return false
            }

            state.days[result.dateKey] = WorkflowDayMaintenanceState(
                offset: result.size,
                size: result.size,
                corrupt: result.corrupt,
                sourceGeneration: result.aggregate.sourceGeneration,
                sourceIsFresh: result.aggregate.sourceIsFresh,
                fileIdentifier: result.fileIdentifier,
                boundaryHash: result.boundaryHash
            )
            state.removeDirty(result.dateKey)

            if currentSize == result.size {
                state.removePending(result.dateKey)
            } else {
                state.markPending(result.dateKey)
            }

            try WorkflowStorage.saveMaintenanceState(state)
            return true
        }
    }

    private func upsert(_ aggregate: WorkflowDailyAggregate, into aggregates: inout [WorkflowDailyAggregate]) {
        if let index = aggregates.firstIndex(where: { $0.date == aggregate.date }) {
            aggregates[index] = aggregate
        } else {
            aggregates.append(aggregate)
        }
    }

    private func markDirty(_ dateKey: String) {
        do {
            try WorkflowStorage.withExclusiveLock {
                var state = WorkflowStorage.loadMaintenanceState()
                state.markDirty(dateKey)
                try WorkflowStorage.saveMaintenanceState(state)
            }
        } catch {
            // 标记丢了下一轮就不会重建这天, 数据会静默缺一块
            let details = LogFields.joined(
                "stage=markDirty",
                "date=\(dateKey)",
                "detail=\(error.localizedDescription)"
            )
            AppLog.workflow.error("事件汇总失败: \(details, privacy: .public)")
        }
    }

    // MARK: - 保留期清理

    @discardableResult
    private func pruneExpiredEventFiles() throws -> Int {
        let cutoffDate = WorkflowStorage.retentionCutoffDate()
        let expiredDateKeys = eventDateKeys().filter { dateKey in
            guard let date = CodexDateFormat.dayDate(from: dateKey) else {
                return false
            }

            return date < cutoffDate
        }

        guard !expiredDateKeys.isEmpty else {
            return 0
        }

        try WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()
            for dateKey in expiredDateKeys {
                try? FileManager.default.removeItem(at: eventLogURL(for: dateKey))
                state.remove(dateKey)
            }

            try WorkflowStorage.saveMaintenanceState(state)
        }
        // 保留期到点会真的删掉原始事件文件, 数据对不上时要能查到哪些日期被清掉了
        let details = LogFields.joined(
            "dates=\(expiredDateKeys.count)",
            "oldest=\(expiredDateKeys.first ?? "-")"
        )
        AppLog.workflow.notice("过期事件已清理: \(details, privacy: .public)")
        return expiredDateKeys.count
    }

    private func retainsIdentifiers(for dateKey: String) -> Bool {
        guard let date = CodexDateFormat.dayDate(from: dateKey) else {
            return true
        }

        return date >= WorkflowStorage.identifierRetentionCutoffDate()
    }
}

/// Hook 统计文件路径, 保留期和跨进程 flock 都集中在这里
nonisolated enum WorkflowStorage {
    private static let retentionDayCount = 210
    private static let identifierRetentionDayCount = 3

    // MARK: - 存储路径

    static func eventsDirectoryURL() -> URL {
        directoryURL()
            .appendingPathComponent("events", isDirectory: true)
    }

    static func eventLogURL(for dateKey: String, in directoryURL: URL = eventsDirectoryURL()) -> URL {
        directoryURL.appendingPathComponent("\(dateKey).jsonl", isDirectory: false)
    }

    static func dailyURL() -> URL {
        directoryURL()
            .appendingPathComponent("daily.jsonl", isDirectory: false)
    }

    static func lockURL() -> URL {
        directoryURL()
            .appendingPathComponent("stats.lock", isDirectory: false)
    }

    static func maintenanceURL() -> URL {
        directoryURL()
            .appendingPathComponent("maintenance.json", isDirectory: false)
    }

    static func syncDirectoryURL() -> URL {
        directoryURL()
            .appendingPathComponent("Sync", isDirectory: true)
    }

    static func directoryURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        return applicationSupportURL
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("HookEvents", isDirectory: true)
    }

    /// waitLimitSeconds 为 nil 时无限等待, 供不在 Codex 关键路径上的主 App 使用
    static func withExclusiveLock<T>(
        waitLimitSeconds: Double? = nil,
        _ work: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: directoryURL(),
            withIntermediateDirectories: true
        )

        // 创建与打开必须是同一次调用: 分开做时两个进程可能各自创建,
        // 后创建的会 unlink 掉前者正在锁的 inode, 于是双方都以为自己独占
        let fileDescriptor = open(lockURL().path, O_RDWR | O_CREAT, 0o644)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(fileDescriptor)
        }

        // Hook 子进程和主 App 可能同时写统计文件, 必须使用进程级排他锁
        try acquireExclusiveLock(fileDescriptor, waitLimitSeconds: waitLimitSeconds)

        defer {
            flock(fileDescriptor, LOCK_UN)
        }

        return try work()
    }

    /// 有等待上限时改用非阻塞重试: Hook 子进程不能无限期占着 Codex 的一轮
    private static func acquireExclusiveLock(
        _ fileDescriptor: Int32,
        waitLimitSeconds: Double?
    ) throws {
        guard let waitLimitSeconds else {
            guard flock(fileDescriptor, LOCK_EX) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(waitLimitSeconds))
        var retryInterval = lockMinimumRetryIntervalMicroseconds
        while flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErrno = errno
            guard lockErrno == EWOULDBLOCK else {
                throw POSIXError(POSIXErrorCode(rawValue: lockErrno) ?? .EIO)
            }
            guard clock.now < deadline else {
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(retryInterval)
            retryInterval = min(retryInterval * 2, lockMaximumRetryIntervalMicroseconds)
        }
    }

    /// 轮询间隔从 1ms 起翻倍: 维护流程每次持锁都只有几毫秒,
    /// 固定长间隔会让 Hook 子进程为一次已经释放的锁白等一整个间隔
    private static let lockMinimumRetryIntervalMicroseconds: UInt32 = 1000
    private static let lockMaximumRetryIntervalMicroseconds: UInt32 = 20000

    static func loadMaintenanceState() -> WorkflowMaintenanceState {
        let url = maintenanceURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let state = try? JSONDecoder().decode(WorkflowMaintenanceState.self, from: data) else {
            return WorkflowMaintenanceState()
        }

        return state
    }

    static func saveMaintenanceState(_ state: WorkflowMaintenanceState) throws {
        try FileManager.default.createDirectory(
            at: directoryURL(),
            withIntermediateDirectories: true
        )

        let data = try JSONLines.stableEncoder.encode(state)
        try data.write(to: maintenanceURL(), options: .atomic)
    }

    static func fileSize(at url: URL) -> UInt64 {
        fileStat(at: url)?.size ?? 0
    }

    /// 单次 stat 同时返回大小与 inode 标识, 文件缺失或不可读时为 nil
    /// 维护流程每轮要 stat 上百个事件文件, 用裸 stat(2) 而非 attributesOfItem 避免逐个构造属性字典
    /// mtime 记整数纳秒: 落盘状态用 JSON 编码, Date 会退化成浮点而无法精确比较
    /// 沿用 attributesOfItem 的语义跟随符号链接, 因此用 stat 而非 lstat
    static func fileStat(at url: URL) -> WorkflowFileStat? {
        var info = Darwin.stat()
        guard stat(url.path, &info) == 0 else {
            return nil
        }

        return WorkflowFileStat(
            size: UInt64(clamping: info.st_size),
            identifier: UInt64(info.st_ino),
            modifiedAtNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1000000000
                + Int64(info.st_mtimespec.tv_nsec)
        )
    }

    /// 枚举目录中文件名为合法日期键的 .jsonl 事件日志, 返回升序日期键
    static func eventLogDateKeys(in directoryURL: URL = eventsDirectoryURL()) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { isValidDateKey($0) }
            .sorted()
    }

    /// 返回保留窗口内且本机原始事件文件非空的日期, 供设置页标记和筛选实际重建项
    static func rebuildableEventDateKeys(
        in directoryURL: URL = eventsDirectoryURL()
    ) -> [String] {
        let cutoffKey = dateKey(for: retentionCutoffDate())
        return eventLogDateKeys(in: directoryURL)
            .filter { dateKey in
                dateKey >= cutoffKey
                    && fileSize(at: eventLogURL(for: dateKey, in: directoryURL)) > 0
            }
            .sorted(by: >)
    }

    static func retentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: retentionDayCount, today: today, calendar: calendar)
    }

    static func identifierRetentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: identifierRetentionDayCount, today: today, calendar: calendar)
    }

    private static func cutoffDate(dayCount: Int, today: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: today)
        return calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: todayStart
        ) ?? todayStart
    }

    static func dateKey(for date: Date) -> String {
        CodexDateFormat.dayString(from: date)
    }

    static func isValidDateKey(_ dateKey: String) -> Bool {
        CodexDateFormat.dayDate(from: dateKey) != nil
    }
}

/// 记录单日事件文件已处理到的 offset, 支持后续增量维护
/// stat(2) 里维护流程需要的三个字段
nonisolated struct WorkflowFileStat {
    let size: UInt64
    let identifier: UInt64
    let modifiedAtNanoseconds: Int64
}

nonisolated struct WorkflowDayMaintenanceState: Codable, Equatable {
    var offset: UInt64
    var size: UInt64
    var corrupt: Int
    var sourceGeneration: String?
    var sourceIsFresh: Bool
    var fileIdentifier: UInt64?
    var boundaryHash: String?
    /// 上次校验 boundaryHash 时文件的 mtime; 未变即可跳过重算
    var boundaryVerifiedAtNanoseconds: Int64?

    init(
        offset: UInt64 = 0,
        size: UInt64 = 0,
        corrupt: Int = 0,
        sourceGeneration: String? = nil,
        sourceIsFresh: Bool = false,
        fileIdentifier: UInt64? = nil,
        boundaryHash: String? = nil,
        boundaryVerifiedAtNanoseconds: Int64? = nil
    ) {
        self.offset = offset
        self.size = size
        self.corrupt = corrupt
        self.sourceGeneration = sourceGeneration
        self.sourceIsFresh = sourceIsFresh
        self.fileIdentifier = fileIdentifier
        self.boundaryHash = boundaryHash
        self.boundaryVerifiedAtNanoseconds = boundaryVerifiedAtNanoseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        size = try container.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
        corrupt = try container.decodeIfPresent(Int.self, forKey: .corrupt) ?? 0
        sourceGeneration = try container.decodeIfPresent(String.self, forKey: .sourceGeneration)
        sourceIsFresh = try container.decodeIfPresent(Bool.self, forKey: .sourceIsFresh) ?? false
        fileIdentifier = try container.decodeIfPresent(UInt64.self, forKey: .fileIdentifier)
        boundaryHash = try container.decodeIfPresent(String.self, forKey: .boundaryHash)
        boundaryVerifiedAtNanoseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .boundaryVerifiedAtNanoseconds
        )
    }
}

/// maintenance.json 的全局状态, pending 表示可增量, dirty 表示需全量重建
nonisolated struct WorkflowMaintenanceState: Codable, Equatable {
    /// 原始事件到每日聚合的算法版本, 变化时统一从原始 JSONL 重建
    static let currentAggregationSchema = 5

    var schema: Int
    var pending: [String]
    var dirty: [String]
    var days: [String: WorkflowDayMaintenanceState]

    init(
        schema: Int = Self.currentAggregationSchema,
        pending: [String] = [],
        dirty: [String] = [],
        days: [String: WorkflowDayMaintenanceState] = [:]
    ) {
        self.schema = schema
        self.pending = Self.normalizedDates(pending)
        self.dirty = Self.normalizedDates(dirty)
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 缺少版本只能说明来源更旧, 不能乐观视为当前算法
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? 0
        pending = try Self.normalizedDates(container.decodeIfPresent([String].self, forKey: .pending) ?? [])
        dirty = try Self.normalizedDates(container.decodeIfPresent([String].self, forKey: .dirty) ?? [])
        days = try container.decodeIfPresent([String: WorkflowDayMaintenanceState].self, forKey: .days) ?? [:]
    }

    /// 返回状态是否有实际变化, 便于调用方跳过无谓的落盘
    @discardableResult
    mutating func markPending(_ dateKey: String) -> Bool {
        let newPending = Self.inserting(dateKey, into: pending)
        let changed = newPending != pending || days[dateKey] == nil
        pending = newPending
        ensureDayState(for: dateKey)
        return changed
    }

    @discardableResult
    mutating func markDirty(_ dateKey: String) -> Bool {
        markDirty(contentsOf: [dateKey])
    }

    /// 批量标脏一次性归一化, 避免逐个插入的重复排序与校验
    @discardableResult
    mutating func markDirty(contentsOf dateKeys: [String]) -> Bool {
        guard !dateKeys.isEmpty else {
            return false
        }

        let newDirty = Self.normalizedDates(dirty + dateKeys)
        var changed = newDirty != dirty
        dirty = newDirty

        for dateKey in dateKeys where days[dateKey] == nil {
            days[dateKey] = WorkflowDayMaintenanceState()
            changed = true
        }

        return changed
    }

    mutating func removePending(_ dateKey: String) {
        pending.removeAll { $0 == dateKey }
    }

    mutating func removeDirty(_ dateKey: String) {
        dirty.removeAll { $0 == dateKey }
    }

    mutating func remove(_ dateKey: String) {
        removePending(dateKey)
        removeDirty(dateKey)
        days.removeValue(forKey: dateKey)
    }

    @discardableResult
    mutating func ensureSourceGeneration(
        for dateKey: String,
        fileIdentifier: UInt64?
    ) -> Bool {
        var day = days[dateKey] ?? WorkflowDayMaintenanceState()
        var changed = false

        if day.sourceGeneration == nil {
            day.sourceGeneration = Self.newSourceGeneration()
            day.sourceIsFresh = false
            changed = true
        }
        if day.fileIdentifier == nil, let fileIdentifier {
            day.fileIdentifier = fileIdentifier
            changed = true
        }

        days[dateKey] = day
        return changed
    }

    /// 记下 boundaryHash 重算通过时文件的 mtime, 供下一轮跳过重算
    @discardableResult
    mutating func recordBoundaryVerification(for dateKey: String, at nanoseconds: Int64) -> Bool {
        guard var day = days[dateKey], day.boundaryVerifiedAtNanoseconds != nanoseconds else {
            return false
        }

        day.boundaryVerifiedAtNanoseconds = nanoseconds
        days[dateKey] = day
        return true
    }

    mutating func startNewSourceGeneration(
        for dateKey: String,
        isFresh: Bool,
        fileIdentifier: UInt64?
    ) {
        days[dateKey] = WorkflowDayMaintenanceState(
            sourceGeneration: Self.newSourceGeneration(),
            sourceIsFresh: isFresh,
            fileIdentifier: fileIdentifier
        )
        markDirty(dateKey)
    }

    mutating func normalize() -> Bool {
        let previousPending = pending
        let previousDirty = dirty
        let previousDays = days

        pending = Self.normalizedDates(pending)
        dirty = Self.normalizedDates(dirty)
        days = days.filter { WorkflowStorage.isValidDateKey($0.key) }

        return previousPending != pending || previousDirty != dirty || previousDays != days
    }

    private mutating func ensureDayState(for dateKey: String) {
        if days[dateKey] == nil {
            days[dateKey] = WorkflowDayMaintenanceState()
        }
    }

    private static func inserting(_ dateKey: String, into dates: [String]) -> [String] {
        normalizedDates(dates + [dateKey])
    }

    private static func normalizedDates(_ dates: [String]) -> [String] {
        Set(dates.filter(WorkflowStorage.isValidDateKey)).sorted()
    }

    private static func newSourceGeneration() -> String {
        UUID().uuidString.lowercased()
    }
}

/// daily.jsonl 某一时刻的 stat 快照与当天日期键, 用于跳过稳态下的重复归一化
private nonisolated struct WorkflowDailyLogStamp: Equatable {
    let size: UInt64
    let identifier: UInt64?
    let dayKey: String
}

/// 全量重建与安全增量使用不同初始状态, 避免用 nil 隐含任务语义
private nonisolated enum WorkflowMaintenanceMode {
    case rebuild(WorkflowHookCountAvailability)
    case append(WorkflowDailyAggregate)
}

// 单次维护任务: 从 startOffset 读到 size, 可基于已有聚合继续追加
private nonisolated struct WorkflowMaintenanceTask {
    let dateKey: String
    let startOffset: UInt64
    let size: UInt64
    let mode: WorkflowMaintenanceMode
    let existingCorrupt: Int
    let sourceGeneration: String?
    let sourceIsFresh: Bool
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
private nonisolated struct WorkflowMaintenanceResult {
    let dateKey: String
    let aggregate: WorkflowDailyAggregate
    let size: UInt64
    let corrupt: Int
    let fileIdentifier: UInt64?
    let boundaryHash: String?
}

nonisolated struct WorkflowDataRebuildSummary: Equatable, Sendable {
    let rebuiltDateCount: Int
    let eventCount: Int
    let corruptLineCount: Int
    let isSyncReplacementPending: Bool
    /// 未完成的日期, 已标脏并会由常规维护自动重建
    let failedDateKeys: [String]
    let didFailSyncReplacementMarking: Bool
}

private nonisolated struct WorkflowDataRebuildOutcome {
    let snapshot: WorkflowSnapshot
    let summary: WorkflowDataRebuildSummary
}

private nonisolated enum WorkflowDataRebuildError: LocalizedError {
    case sourceUnavailable
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            String(localized: "workflow.rebuild.error.source-unavailable")
        case .sourceChanged:
            String(localized: "workflow.rebuild.error.source-changed")
        }
    }
}

/// UI 层的工作流状态, 节流普通刷新, 维护刷新由上层调度器合并
@MainActor
final class WorkflowViewModel: ObservableObject {
    @Published private(set) var snapshot = WorkflowSnapshot.empty

    private static let minimumRefreshInterval: TimeInterval = 5

    private let service: WorkflowService
    private var isRefreshing = false
    private let refreshCoordinator = RefreshTaskCoordinator()
    private var lastRefreshedAt: Date?

    init(service: WorkflowService = WorkflowService()) {
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

    /// 由 WorkflowSyncScheduler 串行调度, 无需自行判断并发, 只执行一次明确的维护刷新
    /// 返回这一轮的维护计数, 空转为 nil; 收尾日志由调用方按它决定记不记
    func refreshMaintenance(
        synchronize: Bool,
        trigger: LogTrigger
    ) async -> WorkflowMaintenanceCounts? {
        refreshCoordinator.cancel()
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let result = await service.loadSnapshotWithMaintenance(
            synchronize: synchronize,
            trigger: trigger
        )

        snapshot = result.snapshot
        lastRefreshedAt = Date()
        return result.counts
    }

    func rebuildData(
        for dateKeys: [String],
        synchronize: Bool
    ) async throws -> WorkflowDataRebuildSummary {
        refreshCoordinator.cancel()
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let outcome = try await service.rebuildData(
            for: dateKeys,
            synchronize: synchronize
        )
        snapshot = outcome.snapshot
        lastRefreshedAt = Date()
        return outcome.summary
    }
}
