import Darwin
import Foundation

nonisolated enum HookEventBatch {
    case bootstrapStart
    case bootstrapEvents([WorkflowHookEvent])
    /// degraded 表示历史覆盖不完整, 不得据此判断任务静默
    case bootstrapEnd(degraded: Bool, attempts: Int)
    case live([WorkflowHookEvent])
    case sourceHealthChanged(Bool)
}

nonisolated enum HookEventDrainResult: Sendable {
    case completed
    case sourceUnavailable
    case cancelled
}

/// 在独立 actor 中按完整 JSONL 行读取 HookEvents/events
/// bootstrap 覆盖滚动 24 小时并作为单次事务发送, live 随后按窗口内各日期文件 offset 增量读取
actor HookEventTailReader {
    private let onBatch: @MainActor @Sendable (HookEventBatch) -> Void
    private var pollTask: Task<Void, Never>?
    private var readProcessingTask: Task<Void, Never>?
    private var isRunning = false
    // actor 会在 await 期间重入; 所有外部读取请求通过这两个标记合并为单一读取流程
    private var isProcessingReads = false
    private var hasPendingDrain = false
    private var fileCursors: [String: HookFileCursor] = [:]
    private let eventsDirectoryURL: URL
    private let now: @Sendable () -> Date
    private var bootstrapRetryAt: Date?
    private var lastReportedSourceHealth: Bool?
    private var requestedDrainGeneration: UInt64 = 0
    private var drainWaiters: [UInt64: CheckedContinuation<HookEventDrainResult, Never>] = [:]

    init(
        eventsDirectoryURL: URL = WorkflowStorage.eventsDirectoryURL(),
        now: @escaping @Sendable () -> Date = Date.init,
        onBatch: @escaping @MainActor @Sendable (HookEventBatch) -> Void
    ) {
        self.eventsDirectoryURL = eventsDirectoryURL
        self.now = now
        self.onBatch = onBatch
    }

    func start() async {
        guard !isRunning, !isProcessingReads else {
            return
        }
        isRunning = true
        isProcessingReads = true
        defer {
            isProcessingReads = false
        }

        await bootstrapRecentActivity()
        await drainPendingRequests()
        guard isRunning, !Task.isCancelled else {
            return
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard !Task.isCancelled else {
                    return
                }
                _ = await self?.drainNow()
            }
        }
    }

    func stop() {
        isRunning = false
        hasPendingDrain = false
        pollTask?.cancel()
        pollTask = nil
        readProcessingTask?.cancel()
        readProcessingTask = nil
        completeAllDrainWaiters(with: .cancelled)
    }

    /// 每个调用方等待一轮在本次请求之后开始的读取, 已经在途的旧读取不能提前满足该请求
    func drainNow() async -> HookEventDrainResult {
        guard isRunning, !Task.isCancelled else {
            return .cancelled
        }

        requestedDrainGeneration &+= 1
        let generation = requestedDrainGeneration
        hasPendingDrain = true

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                drainWaiters[generation] = continuation
                startPendingReadIfNeeded()
            }
        } onCancel: {
            Task {
                await self.cancelDrainWaiter(generation)
            }
        }
    }

    private func startPendingReadIfNeeded() {
        guard isRunning, !isProcessingReads else {
            return
        }
        isProcessingReads = true
        readProcessingTask = Task { [weak self] in
            await self?.processPendingReads()
        }
    }

    private func processPendingReads() async {
        await drainPendingRequests()
        isProcessingReads = false
        readProcessingTask = nil

        // 最后一轮完成后没有 await 空窗, 正常不会遗漏请求; 这里仍保留自愈以约束未来改动
        if isRunning, hasPendingDrain {
            startPendingReadIfNeeded()
        }
    }

    private func drainPendingRequests() async {
        while isRunning, hasPendingDrain, !Task.isCancelled {
            hasPendingDrain = false
            let generation = requestedDrainGeneration
            let result = await drainNewLines()
            completeDrainWaiters(through: generation, with: result)
        }

        if !isRunning || Task.isCancelled {
            completeAllDrainWaiters(with: .cancelled)
        }
    }

    private func completeDrainWaiters(
        through generation: UInt64,
        with result: HookEventDrainResult
    ) {
        let completedGenerations = drainWaiters.keys.filter { $0 <= generation }
        for completedGeneration in completedGenerations {
            drainWaiters.removeValue(forKey: completedGeneration)?.resume(returning: result)
        }
    }

    private func completeAllDrainWaiters(with result: HookEventDrainResult) {
        let waiters = Array(drainWaiters.values)
        drainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func cancelDrainWaiter(_ generation: UInt64) {
        drainWaiters.removeValue(forKey: generation)?.resume(returning: .cancelled)
    }

    private func eventLogURL(for dateKey: String) -> URL {
        WorkflowStorage.eventLogURL(for: dateKey, in: eventsDirectoryURL)
    }

    // MARK: - bootstrap

    private func bootstrapRecentActivity() async {
        for attempt in 0 ..< Self.bootstrapAttemptLimit {
            guard isRunning, !Task.isCancelled else {
                return
            }
            if let result = await bootstrapAttempt(now: now()) {
                bootstrapRetryAt = nil
                fileCursors = result.cursors
                let healthy = result.cursors.values.allSatisfy { !$0.isDegraded }
                await onBatch(.bootstrapEnd(degraded: !healthy, attempts: attempt + 1))
                await reportSourceHealth(healthy)
                return
            }
        }

        // 连续读取失败时清空恢复态并跳过当前已有字节, 避免稍后误当 live 发送历史通知
        // 代价是丢掉最多 24 小时的任务状态, 所以要让下游知道这一轮是降级而不是真的没有历史
        let current = now()
        bootstrapRetryAt = current.addingTimeInterval(Self.bootstrapRetryInterval)
        fileCursors = Dictionary(uniqueKeysWithValues: Self.dateKeys(
            from: current.addingTimeInterval(-Self.activityRetention), through: current
        ).map { dateKey in
            let stat = WorkflowStorage.fileStat(at: eventLogURL(for: dateKey))
            return (dateKey, HookFileCursor(offset: stat?.size ?? 0, identifier: stat?.identifier, isDegraded: true))
        })
        await onBatch(.bootstrapStart)
        await onBatch(.bootstrapEnd(degraded: true, attempts: Self.bootstrapAttemptLimit))
        await reportSourceHealth(false)
    }

    private func bootstrapAttempt(now: Date) async -> BootstrapResult? {
        guard (try? FileManager.default.contentsOfDirectory(atPath: eventsDirectoryURL.path)) != nil else { return nil }
        let cutoff = now.addingTimeInterval(-Self.activityRetention)
        let dateKeys = Self.dateKeys(from: cutoff, through: now)
        let bootstrapDateKey = WorkflowStorage.dateKey(for: now)
        guard let boundaries = try? dateKeys.map({ dateKey in
            let url = eventLogURL(for: dateKey)
            let stat = try readableStat(at: url)
            return HookFileBoundary(
                dateKey: dateKey,
                url: url,
                size: stat?.size ?? 0,
                fileIdentifier: stat?.identifier
            )
        }) else { return nil }

        await onBatch(.bootstrapStart)

        var cursors: [String: HookFileCursor] = [:]
        for boundary in boundaries {
            guard isRunning, !Task.isCancelled else {
                return nil
            }

            let streamResult = await streamEvents(
                at: boundary.url,
                from: 0,
                through: boundary.size,
                cutoff: cutoff,
                makeBatch: HookEventBatch.bootstrapEvents
            )
            guard streamResult.didReachUpperBound else {
                return nil
            }
            cursors[boundary.dateKey] = HookFileCursor(
                offset: streamResult.completeOffset,
                identifier: boundary.fileIdentifier,
                isDegraded: streamResult.hasDecodeFailures
            )
        }

        guard boundariesAreStable(boundaries, activeDateKey: bootstrapDateKey),
              WorkflowStorage.dateKey(for: self.now()) == bootstrapDateKey else {
            return nil
        }

        return BootstrapResult(cursors: cursors)
    }

    // MARK: - 增量 tail

    private func drainNewLines() async -> HookEventDrainResult {
        guard isRunning, !Task.isCancelled else {
            return .cancelled
        }

        guard (try? FileManager.default.contentsOfDirectory(atPath: eventsDirectoryURL.path)) != nil else {
            await reportSourceHealth(false)
            return .sourceUnavailable
        }
        let current = now()
        if let bootstrapRetryAt {
            guard current >= bootstrapRetryAt else { return .sourceUnavailable }
            await bootstrapRecentActivity()
            guard isRunning, !Task.isCancelled else { return .cancelled }
            return lastReportedSourceHealth == true ? .completed : .sourceUnavailable
        }
        let dates = Self.dateKeys(from: current.addingTimeInterval(-Self.activityRetention), through: current)
        fileCursors = fileCursors.filter { dates.contains($0.key) }
        var healthy = true
        for dateKey in dates {
            let url = eventLogURL(for: dateKey)
            let stat: WorkflowFileStat?
            do {
                stat = try readableStat(at: url)
            } catch {
                await reportSourceHealth(false)
                return .sourceUnavailable
            }
            var cursor = fileCursors[dateKey] ?? HookFileCursor()
            if (cursor.identifier != nil && stat?.identifier != cursor.identifier)
                || (stat?.size ?? 0) < cursor.offset {
                await bootstrapRecentActivity()
                return lastReportedSourceHealth == true ? .completed : .sourceUnavailable
            }
            let size = stat?.size ?? 0
            let result = await streamEvents(
                at: url, from: cursor.offset, through: size,
                cutoff: current.addingTimeInterval(-Self.activityRetention), makeBatch: HookEventBatch.live
            )
            guard isRunning, !Task.isCancelled else { return .cancelled }
            cursor.offset = result.completeOffset
            cursor.identifier = stat?.identifier
            cursor.isDegraded = cursor.isDegraded || result.hasDecodeFailures
            fileCursors[dateKey] = cursor
            healthy = healthy && result.didReachUpperBound && !cursor.isDegraded
        }
        await reportSourceHealth(healthy)
        return healthy ? .completed : .sourceUnavailable
    }

    private func readableStat(at url: URL) throws -> WorkflowFileStat? {
        guard let stat = WorkflowStorage.fileStat(at: url) else {
            let code = errno
            if code == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let handle = try FileHandle(forReadingFrom: url)
        try handle.close()
        return stat
    }

    private func reportSourceHealth(_ isHealthy: Bool) async {
        guard isHealthy != lastReportedSourceHealth else {
            return
        }
        lastReportedSourceHealth = isHealthy
        await onBatch(.sourceHealthChanged(isHealthy))
    }

    /// 返回已处理完整行的绝对 offset 和是否读完固定上界; 后续失败时保留此前进度
    private func streamEvents(
        at url: URL,
        from startOffset: UInt64,
        through upperBound: UInt64,
        cutoff: Date?,
        makeBatch: ([WorkflowHookEvent]) -> HookEventBatch
    ) async -> HookEventStreamResult {
        guard upperBound > startOffset else {
            return .completed(at: startOffset)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .interrupted(at: startOffset)
        }
        defer {
            try? handle.close()
        }

        guard (try? handle.seek(toOffset: startOffset)) != nil else {
            return .interrupted(at: startOffset)
        }

        var readOffset = startOffset
        var completeOffset = startOffset
        var pending = Data()
        var hasDecodeFailures = false

        while readOffset < upperBound {
            guard isRunning, !Task.isCancelled else {
                return HookEventStreamResult(completeOffset: completeOffset, didReachUpperBound: false, hasDecodeFailures: hasDecodeFailures)
            }

            let requestedCount = Int(min(
                UInt64(Self.readChunkByteCount),
                upperBound - readOffset
            ))
            guard let chunk = try? handle.read(upToCount: requestedCount),
                  !chunk.isEmpty else {
                return HookEventStreamResult(completeOffset: completeOffset, didReachUpperBound: false, hasDecodeFailures: hasDecodeFailures)
            }

            readOffset += UInt64(chunk.count)
            pending.append(chunk)

            guard let lastNewlineIndex = pending.lastIndex(of: JSONLines.newlineByte) else {
                await Task.yield()
                continue
            }

            let remainderStart = pending.index(after: lastNewlineIndex)
            let completeData = Data(pending[...lastNewlineIndex])
            pending = remainderStart < pending.endIndex
                ? Data(pending[remainderStart...])
                : Data()
            completeOffset = readOffset - UInt64(pending.count)

            let decoded = JSONLines.decodeWithFailures(WorkflowHookEvent.self, from: completeData)
            if decoded.failedLineCount > 0 {
                hasDecodeFailures = true
                await reportSourceHealth(false)
            }
            var events = decoded.values
            if let cutoff {
                events.removeAll { $0.timestamp < cutoff }
            }
            if !events.isEmpty {
                await onBatch(makeBatch(events))
            }
            await Task.yield()
        }

        return HookEventStreamResult(
            completeOffset: completeOffset,
            didReachUpperBound: completeOffset == upperBound,
            hasDecodeFailures: hasDecodeFailures
        )
    }

    /// 从 24 小时窗口之前的事件文件中定向查找 Prompt 起点, 供 bootstrap 后回填恢复任务的开始时间
    func findPromptStartTimes(
        for references: [CodexActivityPromptReference]
    ) -> [CodexActivityPromptReference: Date] {
        let cutoff = now().addingTimeInterval(-Self.activityRetention)
        var unresolvedKeys = Set(references)
        var startTimes: [CodexActivityPromptReference: Date] = [:]
        var remainingBytes = Self.promptSearchByteLimit

        for url in eventLogURLs(onOrBefore: cutoff) {
            guard !unresolvedKeys.isEmpty, remainingBytes > 0 else {
                break
            }

            let size = WorkflowStorage.fileSize(at: url)
            let readCount = min(size, remainingBytes)
            guard readCount > 0,
                  let handle = try? FileHandle(forReadingFrom: url) else {
                continue
            }
            defer {
                try? handle.close()
            }

            let readOffset = size - readCount
            guard (try? handle.seek(toOffset: readOffset)) != nil,
                  let data = try? handle.read(upToCount: Int(readCount)),
                  !data.isEmpty else {
                remainingBytes -= readCount
                continue
            }
            remainingBytes -= UInt64(data.count)

            let completeData = readOffset > 0 ? JSONLines.droppingLeadingPartialLine(data) : data

            for event in JSONLines.decode(WorkflowHookEvent.self, from: completeData)
                where event.hookEvent == .userPromptSubmit && event.timestamp < cutoff {
                guard let sessionId = event.sessionId, let turnId = event.turnId else {
                    continue
                }
                let key = CodexActivityPromptReference(sessionId: sessionId, turnId: turnId)
                guard unresolvedKeys.remove(key) != nil else {
                    continue
                }
                startTimes[key] = event.timestamp
            }
        }

        return startTimes
    }

    private func eventLogURLs(onOrBefore cutoff: Date) -> [URL] {
        let cutoffDateKey = WorkflowStorage.dateKey(for: cutoff)
        return WorkflowStorage.eventLogDateKeys(in: eventsDirectoryURL)
            .filter { $0 <= cutoffDateKey }
            .sorted(by: >)
            .map { eventLogURL(for: $0) }
    }

    private func boundariesAreStable(
        _ boundaries: [HookFileBoundary],
        activeDateKey: String
    ) -> Bool {
        for boundary in boundaries {
            let stat = WorkflowStorage.fileStat(at: boundary.url)
            guard stat?.identifier == boundary.fileIdentifier else {
                return false
            }
            let currentSize = stat?.size ?? 0
            if boundary.dateKey == activeDateKey {
                guard currentSize >= boundary.size else {
                    return false
                }
            } else if currentSize != boundary.size {
                return false
            }
        }
        return true
    }

    private static func dateKeys(from start: Date, through end: Date) -> [String] {
        // 产出的日期键要和 WorkflowStorage.dateKey 对齐, 必须固定公历
        let calendar = CodexDateFormat.localGregorianCalendar
        var date = calendar.startOfDay(for: start)
        let endDate = calendar.startOfDay(for: end)
        var keys: [String] = []

        while date <= endDate {
            keys.append(WorkflowStorage.dateKey(for: date))
            guard let nextDate = calendar.date(byAdding: .day, value: 1, to: date),
                  nextDate > date else {
                break
            }
            date = nextDate
        }
        return keys
    }

    private static let pollInterval: TimeInterval = 2
    private static let activityRetention = CodexActivityRetention.window
    private static let readChunkByteCount = 512 * 1024
    private static let promptSearchByteLimit: UInt64 = 8 * 1024 * 1024
    private static let bootstrapAttemptLimit = 3
    private static let bootstrapRetryInterval: TimeInterval = 10
}

private nonisolated struct HookFileBoundary {
    let dateKey: String
    let url: URL
    let size: UInt64
    let fileIdentifier: UInt64?
}

private nonisolated struct HookFileCursor {
    var offset: UInt64 = 0
    var identifier: UInt64?
    var isDegraded = false
}

private nonisolated struct BootstrapResult {
    let cursors: [String: HookFileCursor]
}

private nonisolated struct HookEventStreamResult {
    let completeOffset: UInt64
    let didReachUpperBound: Bool
    var hasDecodeFailures = false

    static func completed(at offset: UInt64) -> Self {
        Self(completeOffset: offset, didReachUpperBound: true)
    }

    static func interrupted(at offset: UInt64) -> Self {
        Self(completeOffset: offset, didReachUpperBound: false)
    }
}
