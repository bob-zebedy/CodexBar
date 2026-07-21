import Combine
import CryptoKit
import Darwin
import Foundation

/// 从 Hook 原始事件维护每日聚合, 对外只发布 UI 需要的统计快照
actor WorkflowService {
    private let eventsDirectoryURL: URL
    private let dailyLogURL: URL
    private let syncService: WorkflowSyncService
    /// 上次归一化时 daily.jsonl 的 stat 与当天日期键
    private var lastNormalizedDailyLog: WorkflowDailyLogStamp?
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

    func loadSnapshot(
        performMaintenance: Bool = false,
        synchronize: Bool = false
    ) async -> WorkflowSnapshot {
        if performMaintenance {
            performMaintenanceIfNeeded()
        }

        return await makeSnapshot(
            localAggregates: loadDailyAggregates() ?? [],
            synchronize: synchronize
        )
    }

    private func makeSnapshot(
        localAggregates: [WorkflowDailyAggregate],
        synchronize: Bool
    ) async -> WorkflowSnapshot {
        let syncSnapshot: WorkflowSyncSnapshot = if synchronize {
            await syncService.synchronizeIfEnabled(localAggregates: localAggregates)
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
        let normalizedDateKeys = Set(dateKeys).sorted()
        guard !normalizedDateKeys.isEmpty else {
            throw WorkflowDataRebuildError.sourceUnavailable
        }

        var rebuildResults = [WorkflowMaintenanceResult]()
        do {
            for dateKey in normalizedDateKeys {
                try rebuildResults.append(rebuildLocalData(for: dateKey))
            }
        } catch {
            try? await syncService.markReplacementNeeded(for: rebuildResults.map(\.dateKey))
            throw error
        }
        try await syncService.markReplacementNeeded(for: normalizedDateKeys)

        let snapshot = await makeSnapshot(
            localAggregates: loadDailyAggregates() ?? [],
            synchronize: synchronize
        )
        let summary = await WorkflowDataRebuildSummary(
            rebuiltDateCount: rebuildResults.count,
            eventCount: rebuildResults.reduce(0) { $0 + $1.aggregate.eventCount },
            corruptLineCount: rebuildResults.reduce(0) { $0 + $1.corrupt },
            isSyncReplacementPending: syncService.hasPendingReplacement(for: normalizedDateKeys)
        )
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

    private func rebuildLocalData(for dateKey: String) throws -> WorkflowMaintenanceResult {
        let task = try prepareRebuildTask(for: dateKey)
        var aggregates = loadDailyAggregates() ?? []

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

    private func prepareRebuildTask(for dateKey: String) throws -> WorkflowMaintenanceTask {
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
            return dirtyTask(for: dateKey, day: day, size: stat.size)
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

    private func performMaintenanceIfNeeded() {
        do {
            let tasks = try prepareMaintenanceTasks()
            let didWriteDailyLog = perform(tasks)
            // 每次落盘前都已整体归一化, 写入过就不必再做一轮全量解码比对
            if !didWriteDailyLog {
                try normalizeDailyAggregatesIfNeeded()
            }
            try pruneExpiredEventFiles()
        } catch {
            return
        }
    }

    /// 返回是否写入过 daily.jsonl; 批次内共享同一份内存聚合, 避免每个任务重新读盘
    private func perform(_ tasks: [WorkflowMaintenanceTask]) -> Bool {
        guard !tasks.isEmpty else {
            return false
        }

        var aggregates = loadDailyAggregates() ?? []
        var didWrite = false
        for task in tasks {
            do {
                let result = try buildDailyAggregate(for: task)
                didWrite = try commit(result, aggregates: &aggregates) || didWrite
            } catch {
                markDirty(task.dateKey)
            }
        }

        return didWrite
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

        if state.schema != WorkflowMaintenanceState.currentSchema {
            changed = state.markDirty(contentsOf: eventDateKeys) || changed
            state.schema = WorkflowMaintenanceState.currentSchema
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
                && stat.identifier != nil
                && day.fileIdentifier != stat.identifier
            let boundaryChanged = day.boundaryHash.map {
                (try? eventLogBoundaryHash(for: dateKey, endingAt: day.offset)) != $0
            } ?? false

            if identifierChanged || stat.size < day.offset || boundaryChanged {
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
            return dirtyTask(for: dateKey, day: day)
        }

        for dateKey in state.pending where !dirty.contains(dateKey) {
            let day = state.days[dateKey] ?? WorkflowDayMaintenanceState()
            let size = eventLogSize(for: dateKey)
            guard size > day.offset else {
                state.removePending(dateKey)
                changedState = true
                continue
            }

            guard let baseAggregate = dailyByDate[dateKey],
                  baseAggregate.sourceGeneration == day.sourceGeneration else {
                state.markDirty(dateKey)
                changedState = true
                tasks.append(dirtyTask(for: dateKey, day: day, size: size))
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
        size: UInt64? = nil
    ) -> WorkflowMaintenanceTask {
        let stat = WorkflowStorage.fileStat(at: eventLogURL(for: dateKey))
        return WorkflowMaintenanceTask(
            dateKey: dateKey,
            startOffset: 0,
            size: size ?? stat?.size ?? 0,
            baseAggregate: nil,
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
            baseAggregate: baseAggregate,
            existingCorrupt: day.corrupt,
            sourceGeneration: day.sourceGeneration,
            sourceIsFresh: day.sourceIsFresh,
            fileIdentifier: day.fileIdentifier
        )
    }

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
        var aggregate = task.baseAggregate ?? WorkflowDailyAggregate(
            date: task.dateKey,
            sourceGeneration: task.sourceGeneration,
            sourceIsFresh: task.sourceIsFresh
        )
        aggregate.sourceGeneration = task.sourceGeneration
        aggregate.sourceIsFresh = task.sourceIsFresh
        var corrupt = task.existingCorrupt
        var identifierCache = WorkflowDailyIdentifierCache(aggregate: aggregate)
        let keepsIdentifiers = keepsIdentifiers(for: task.dateKey)

        corrupt += try readEvents(
            at: eventLogURL(for: task.dateKey),
            from: task.startOffset,
            upTo: task.size
        ) { event in
            aggregate.record(
                event,
                keepsIdentifiers: keepsIdentifiers,
                identifierCache: &identifierCache
            )
        }

        aggregate.compactIdentifiersIfNeeded(keepsIdentifiers: keepsIdentifiers)
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

    /// 返回是否写入了 daily.jsonl
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
        try commitMaintenanceState(result)
        return true
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
            || stat?.identifier == nil
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

    private func commitMaintenanceState(_ result: WorkflowMaintenanceResult) throws {
        try WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()

            guard let currentSize = try validatedEventLogSize(for: result, state: &state) else {
                return
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
        try? WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()
            state.markDirty(dateKey)
            try WorkflowStorage.saveMaintenanceState(state)
        }
    }

    private func pruneExpiredEventFiles() throws {
        let cutoffDate = WorkflowStorage.retentionCutoffDate()
        let expiredDateKeys = eventDateKeys().filter { dateKey in
            guard let date = CodexDateFormat.dayDate(from: dateKey) else {
                return false
            }

            return date < cutoffDate
        }

        guard !expiredDateKeys.isEmpty else {
            return
        }

        try WorkflowStorage.withExclusiveLock {
            var state = WorkflowStorage.loadMaintenanceState()
            for dateKey in expiredDateKeys {
                try? FileManager.default.removeItem(at: eventLogURL(for: dateKey))
                state.remove(dateKey)
            }

            try WorkflowStorage.saveMaintenanceState(state)
        }
    }

    private func keepsIdentifiers(for dateKey: String) -> Bool {
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

    static func withExclusiveLock<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: directoryURL(),
            withIntermediateDirectories: true
        )

        let lockURL = lockURL()
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }

        let lockHandle = try FileHandle(forUpdating: lockURL)
        defer {
            try? lockHandle.close()
        }

        // Hook 子进程和主 App 可能同时写统计文件, 必须使用进程级排他锁
        if flock(lockHandle.fileDescriptor, LOCK_EX) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        defer {
            flock(lockHandle.fileDescriptor, LOCK_UN)
        }

        return try work()
    }

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
    static func fileStat(at url: URL) -> (size: UInt64, identifier: UInt64?)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }

        return (
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            identifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
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
nonisolated struct WorkflowDayMaintenanceState: Codable, Equatable {
    var offset: UInt64
    var size: UInt64
    var corrupt: Int
    var sourceGeneration: String?
    var sourceIsFresh: Bool
    var fileIdentifier: UInt64?
    var boundaryHash: String?

    init(
        offset: UInt64 = 0,
        size: UInt64 = 0,
        corrupt: Int = 0,
        sourceGeneration: String? = nil,
        sourceIsFresh: Bool = false,
        fileIdentifier: UInt64? = nil,
        boundaryHash: String? = nil
    ) {
        self.offset = offset
        self.size = size
        self.corrupt = corrupt
        self.sourceGeneration = sourceGeneration
        self.sourceIsFresh = sourceIsFresh
        self.fileIdentifier = fileIdentifier
        self.boundaryHash = boundaryHash
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
    }
}

/// maintenance.json 的全局状态, pending 表示可增量, dirty 表示需全量重建
nonisolated struct WorkflowMaintenanceState: Codable, Equatable {
    static let currentSchema = 4

    var schema: Int
    var pending: [String]
    var dirty: [String]
    var days: [String: WorkflowDayMaintenanceState]

    init(
        schema: Int = Self.currentSchema,
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
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
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

// 单次维护任务: 从 startOffset 读到 size, 可基于已有聚合继续追加
private nonisolated struct WorkflowMaintenanceTask {
    let dateKey: String
    let startOffset: UInt64
    let size: UInt64
    let baseAggregate: WorkflowDailyAggregate?
    let existingCorrupt: Int
    let sourceGeneration: String?
    let sourceIsFresh: Bool
    let fileIdentifier: UInt64?
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
            "没有可重建的本地数据"
        case .sourceChanged:
            "本地数据发生变化, 请重试"
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
    func refreshMaintenance(synchronize: Bool) async {
        refreshCoordinator.cancel()
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        let snapshot = await service.loadSnapshot(
            performMaintenance: true,
            synchronize: synchronize
        )

        self.snapshot = snapshot
        lastRefreshedAt = Date()
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
