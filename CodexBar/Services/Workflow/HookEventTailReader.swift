import Foundation

nonisolated enum HookEventBatch {
    case bootstrapStart
    case bootstrapEvents([WorkflowHookEvent])
    /// degraded 表示放弃回放直接跳到文件末尾, 这一轮的活跃任务是空的而不是真的没有
    /// attempts 由 reader 给出, 它才知道循环跑了几轮以及放弃时补发过一次清场
    case bootstrapEnd(degraded: Bool, attempts: Int)
    case live([WorkflowHookEvent])
}

/// 在独立 actor 中按完整 JSONL 行读取 HookEvents/events
/// bootstrap 覆盖滚动 24 小时并作为单次事务发送, live 随后按当日文件 offset 增量读取
actor HookEventTailReader {
    private let onBatch: @MainActor @Sendable (HookEventBatch) -> Void
    private var pollTask: Task<Void, Never>?
    private var isRunning = false
    // actor 会在 await 期间重入; 所有外部读取请求通过这两个标记合并为单一读取流程
    private var isProcessingReads = false
    private var hasPendingDrain = false
    private var activeDateKey = ""
    private var activeFileOffset: UInt64 = 0
    private var activeFileIdentifier: UInt64?

    init(onBatch: @escaping @MainActor @Sendable (HookEventBatch) -> Void) {
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
                await self?.drainNow()
            }
        }
    }

    func stop() {
        isRunning = false
        hasPendingDrain = false
        pollTask?.cancel()
        pollTask = nil
    }

    func drainNow() async {
        guard isRunning, !Task.isCancelled else {
            return
        }
        hasPendingDrain = true

        guard !isProcessingReads else {
            return
        }
        isProcessingReads = true
        defer {
            isProcessingReads = false
        }
        await drainPendingRequests()
    }

    private func drainPendingRequests() async {
        while isRunning, hasPendingDrain, !Task.isCancelled {
            hasPendingDrain = false
            await drainNewLines()
        }
    }

    private var activeFileURL: URL {
        WorkflowStorage.eventLogURL(for: activeDateKey)
    }

    private func bootstrapRecentActivity() async {
        for attempt in 0 ..< Self.bootstrapAttemptLimit {
            guard isRunning, !Task.isCancelled else {
                return
            }
            if let result = await bootstrapAttempt(now: Date()) {
                activeDateKey = result.activeDateKey
                activeFileOffset = result.activeFileOffset
                activeFileIdentifier = result.activeFileIdentifier
                await onBatch(.bootstrapEnd(degraded: false, attempts: attempt + 1))
                return
            }
        }

        // 连续读取失败时清空恢复态并跳过当前已有字节, 避免稍后误当 live 发送历史通知
        // 代价是丢掉最多 24 小时的任务状态, 所以要让下游知道这一轮是降级而不是真的没有历史
        let dateKey = WorkflowStorage.dateKey(for: Date())
        let stat = WorkflowStorage.fileStat(at: WorkflowStorage.eventLogURL(for: dateKey))
        activeDateKey = dateKey
        activeFileOffset = stat?.size ?? 0
        activeFileIdentifier = stat?.identifier
        await onBatch(.bootstrapStart)
        await onBatch(.bootstrapEnd(degraded: true, attempts: Self.bootstrapAttemptLimit))
    }

    private func bootstrapAttempt(now: Date) async -> BootstrapResult? {
        let cutoff = now.addingTimeInterval(-Self.activityRetention)
        let dateKeys = Self.dateKeys(from: cutoff, through: now)
        let bootstrapDateKey = WorkflowStorage.dateKey(for: now)
        let boundaries = dateKeys.map { dateKey in
            let url = WorkflowStorage.eventLogURL(for: dateKey)
            let stat = WorkflowStorage.fileStat(at: url)
            return HookFileBoundary(
                dateKey: dateKey,
                url: url,
                size: stat?.size ?? 0,
                fileIdentifier: stat?.identifier
            )
        }

        await onBatch(.bootstrapStart)

        var activeCompleteOffset: UInt64 = 0
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
            if boundary.dateKey == bootstrapDateKey {
                activeCompleteOffset = streamResult.completeOffset
            }
        }

        guard boundariesAreStable(boundaries, activeDateKey: bootstrapDateKey),
              WorkflowStorage.dateKey(for: Date()) == bootstrapDateKey else {
            return nil
        }

        let activeBoundary = boundaries.first { $0.dateKey == bootstrapDateKey }
        return BootstrapResult(
            activeDateKey: bootstrapDateKey,
            activeFileOffset: activeCompleteOffset,
            activeFileIdentifier: activeBoundary?.fileIdentifier
        )
    }

    private func drainNewLines() async {
        guard isRunning, !Task.isCancelled else {
            return
        }

        let todayKey = WorkflowStorage.dateKey(for: Date())
        if todayKey != activeDateKey {
            // 跨零点先读完旧文件尾部, 再切到新日期文件
            guard await readAppendedLines() else {
                // bootstrap 已经完成切日; 临时失败则保留旧日期, 下一轮继续重试
                return
            }
            activeDateKey = todayKey
            activeFileOffset = 0
            activeFileIdentifier = nil
        }

        _ = await readAppendedLines()
    }

    /// 返回是否读到当前文件上界; 触发重新 bootstrap 或读取中断时为 false
    private func readAppendedLines() async -> Bool {
        let url = activeFileURL
        let stat = WorkflowStorage.fileStat(at: url)
        if activeFileIdentifier != nil, stat?.identifier != activeFileIdentifier {
            await bootstrapRecentActivity()
            return false
        }
        if activeFileIdentifier == nil {
            activeFileIdentifier = stat?.identifier
        }

        let size = stat?.size ?? 0
        if size < activeFileOffset {
            await bootstrapRecentActivity()
            return false
        }

        guard size > activeFileOffset else {
            return true
        }

        let streamResult = await streamEvents(
            at: url,
            from: activeFileOffset,
            through: size,
            cutoff: nil,
            makeBatch: HookEventBatch.live
        )
        activeFileOffset = streamResult.completeOffset
        return streamResult.didReachUpperBound
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

        while readOffset < upperBound {
            guard isRunning, !Task.isCancelled else {
                return .interrupted(at: completeOffset)
            }

            let requestedCount = Int(min(
                UInt64(Self.readChunkByteCount),
                upperBound - readOffset
            ))
            guard let chunk = try? handle.read(upToCount: requestedCount),
                  !chunk.isEmpty else {
                return .interrupted(at: completeOffset)
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

            var events = JSONLines.decode(WorkflowHookEvent.self, from: completeData)
            if let cutoff {
                events.removeAll { $0.timestamp < cutoff }
            }
            if !events.isEmpty {
                await onBatch(makeBatch(events))
            }
            await Task.yield()
        }

        return .completed(at: completeOffset)
    }

    /// 从 24 小时窗口之前的事件文件中定向查找 Prompt 起点, 供 bootstrap 后回填恢复任务的开始时间
    func findPromptStartTimes(
        for references: [CodexActivityPromptReference]
    ) -> [CodexActivityPromptReference: Date] {
        let cutoff = Date().addingTimeInterval(-Self.activityRetention)
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
        return WorkflowStorage.eventLogDateKeys()
            .filter { $0 <= cutoffDateKey }
            .sorted(by: >)
            .map { WorkflowStorage.eventLogURL(for: $0) }
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
}

private nonisolated struct HookFileBoundary {
    let dateKey: String
    let url: URL
    let size: UInt64
    let fileIdentifier: UInt64?
}

private nonisolated struct BootstrapResult {
    let activeDateKey: String
    let activeFileOffset: UInt64
    let activeFileIdentifier: UInt64?
}

private nonisolated struct HookEventStreamResult {
    let completeOffset: UInt64
    let didReachUpperBound: Bool

    static func completed(at offset: UInt64) -> Self {
        Self(completeOffset: offset, didReachUpperBound: true)
    }

    static func interrupted(at offset: UInt64) -> Self {
        Self(completeOffset: offset, didReachUpperBound: false)
    }
}
