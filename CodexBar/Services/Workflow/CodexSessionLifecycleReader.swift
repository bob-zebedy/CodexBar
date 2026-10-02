import Foundation

/// 活跃轮次的线程定位信息, 用于关联 rollout 生命周期事件
nonisolated struct CodexActivityTurnReference: Hashable {
    let threadID: String
    let turnID: String
    let startedAt: Date
    var isTerminalUsageOnly = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.threadID == rhs.threadID && lhs.turnID == rhs.turnID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(threadID)
        hasher.combine(turnID)
    }
}

/// 文件读取结果包含覆盖状态, 缓存事实不能替代本轮读取成功
actor CodexSessionLifecycleReader {
    private let sessionsRootURL: URL
    private let archivedSessionsRootURL: URL
    private let fileManager: FileManager
    private var roundRobinOffset = 0
    private var cursorsByThread: [String: SessionFileCursor] = [:]
    private var lastResolutionAttemptByThread: [String: Date] = [:]
    private var lastRecursiveAttemptByThread: [String: Date] = [:]

    init(codexHomeURL: URL = CodexCLIResolver.codexHomeDirectory(), fileManager: FileManager = .default) {
        sessionsRootURL = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        archivedSessionsRootURL = codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    func lifecycleStates(for references: [CodexActivityTurnReference], now: Date = Date()) -> [CodexSessionTaskLifecycleState] {
        let grouped = Dictionary(grouping: references, by: \.threadID)
        let cutoff = now.addingTimeInterval(-CodexActivityRetention.window)
        cursorsByThread = cursorsByThread.filter { $0.value.lastReadAt > cutoff }
        lastResolutionAttemptByThread = lastResolutionAttemptByThread.filter { $0.value > cutoff }
        lastRecursiveAttemptByThread = lastRecursiveAttemptByThread.filter { $0.value > cutoff }
        var budget = Self.readByteLimit
        var states: [CodexSessionTaskLifecycleState] = []
        let threadIDs = grouped.keys.sorted()
        let start = threadIDs.isEmpty ? 0 : roundRobinOffset % threadIDs.count
        let ordered = Array(threadIDs.dropFirst(start)) + Array(threadIDs.prefix(start))
        roundRobinOffset = threadIDs.isEmpty ? 0 : (start + 1) % threadIDs.count
        for threadID in ordered {
            guard !Task.isCancelled else { return [] }
            guard let threadReferences = grouped[threadID],
                  let latest = threadReferences.max(by: { $0.startedAt < $1.startedAt }) else { continue }
            var status = CodexSessionReadStatus.notFound
            if var cursor = cursor(for: latest) {
                let needsHistory = threadReferences.contains { cursor.historyReadLimit(for: $0) > 0 }
                let tailLimit = needsHistory ? Self.readByteLimit / 2 : Self.readByteLimit
                status = scan(into: &cursor, limit: min(tailLimit, budget), now: now)
                budget -= min(budget, cursor.lastReadByteCount)
                if cursor.metadata?.id != threadID {
                    status = .unavailable
                }
                cursor.prepareSupplementalHistory(for: threadReferences, now: now)
                let historyLimit = threadReferences.map { cursor.historyReadLimit(for: $0) }.max() ?? 0
                if status != .unavailable, budget > 0, historyLimit > 0 {
                    if !backfillHistory(into: &cursor, limit: historyLimit, budget: &budget) {
                        status = .unavailable
                    }
                }
                guard !Task.isCancelled else { return [] }
                cursor.lastReadAt = now
                let referencedTurns = Set(threadReferences.map(\.turnID))
                cursor.lifecycleByTurnID = cursor.lifecycleByTurnID.filter {
                    referencedTurns.contains($0.key) || ($0.value.lastProgressAt ?? .distantPast) > cutoff
                        || (cursor.supplementalHistoryByTurn[$0.key]?.lastRequestedAt ?? .distantPast) > cutoff
                }
                cursor.supplementalHistoryByTurn = cursor.supplementalHistoryByTurn.filter {
                    $0.value.lastRequestedAt > cutoff
                }
                cursorsByThread[threadID] = cursor
            }
            let cursor = cursorsByThread[threadID]
            for reference in threadReferences {
                let known = cursor?.lifecycleByTurnID[reference.turnID]
                let hasReadGap = known?.hasReadGap ?? (cursor?.hasDecodeFailures == true)
                let hasHistoryGap = cursor?.hasHistoryGap(for: reference.turnID) == true
                let turnStatus: CodexSessionReadStatus = if status == .unavailable || status == .notFound {
                    status
                } else if known?.terminal != nil {
                    // 明确终态不依赖文件尾部另一条记录是否已写完
                    .complete
                } else {
                    hasReadGap || hasHistoryGap ? .incomplete : status
                }
                states.append(CodexSessionTaskLifecycleState(
                    requestedThreadID: threadID, turnID: reference.turnID, startedAt: known?.startedAt,
                    approvalReviewer: known?.approvalReviewer, effort: known?.effort,
                    lastProgressAt: known?.lastProgressAt, terminal: turnStatus == .complete ? known?.terminal : nil,
                    readStatus: turnStatus, hasContext: known?.hasContext == true,
                    contextObservedAt: known?.contextObservedAt,
                    rootTurnID: known?.rootTurnID,
                    recordedThreadID: cursor?.metadata?.id,
                    rootSessionID: cursor?.metadata?.sessionID,
                    parentThreadID: cursor?.metadata?.parentThreadID,
                    lastExecutionProgressAt: known?.lastExecutionProgressAt,
                    incompleteTailUnchangedSince: status == .incomplete && !hasReadGap && !hasHistoryGap && known?.hasContext == true && known?.terminal == nil
                        ? cursor?.incompleteTailUnchangedSince : nil,
                    tokenUsage: turnStatus == .complete && status == .complete ? known?.tokenUsage : nil,
                    isHistoricalTerminal: known?.isHistoricalTerminal == true
                ))
            }
        }
        return states
    }

    func resetResolutionFallbacks() {
        lastResolutionAttemptByThread.removeAll()
        lastRecursiveAttemptByThread.removeAll()
    }

    private func cursor(for reference: CodexActivityTurnReference) -> SessionFileCursor? {
        if let cursor = cursorsByThread[reference.threadID],
           matchingFile(in: cursor.url.deletingLastPathComponent(), threadID: reference.threadID) == cursor.url {
            return cursor
        }
        if cursorsByThread.removeValue(forKey: reference.threadID) != nil {
            lastResolutionAttemptByThread.removeValue(forKey: reference.threadID)
            lastRecursiveAttemptByThread.removeValue(forKey: reference.threadID)
        }
        let now = Date()
        if let last = lastResolutionAttemptByThread[reference.threadID], now.timeIntervalSince(last) < 10 {
            return nil
        }
        lastResolutionAttemptByThread[reference.threadID] = now
        for directory in [sessionDirectory(for: reference.startedAt), sessionDirectory(for: now), archivedSessionsRootURL] {
            if let url = matchingFile(in: directory, threadID: reference.threadID) {
                let cursor = initialCursor(for: url)
                if cursor.metadata?.id == reference.threadID {
                    return cursor
                }
            }
        }
        if let last = lastRecursiveAttemptByThread[reference.threadID], now.timeIntervalSince(last) < 60 {
            return nil
        }
        lastRecursiveAttemptByThread[reference.threadID] = now
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let matches = enumerator.compactMap { $0 as? URL }.filter { Self.matchesFile($0, threadID: reference.threadID) }
        guard matches.count == 1, let url = matches.first else { return nil }
        let cursor = initialCursor(for: url)
        return cursor.metadata?.id == reference.threadID ? cursor : nil
    }

    private func matchingFile(in directory: URL, threadID: String) -> URL? {
        let matches = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter { Self.matchesFile($0, threadID: threadID) } ?? []
        return matches.count == 1 ? matches.first : nil
    }

    private static func matchesFile(_ url: URL, threadID: String) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return false }
        let stem = String(name.dropLast(6))
        if stem.hasSuffix("-\(threadID)") {
            return true
        }
        guard let separator = stem.lastIndex(of: "_"), UUID(uuidString: String(stem[stem.index(after: separator)...])) != nil else { return false }
        return stem[..<separator].hasSuffix("-\(threadID)")
    }

    private func sessionDirectory(for date: Date) -> URL {
        let components = CodexDateFormat.localGregorianCalendar.dateComponents([.year, .month, .day], from: date)
        return sessionsRootURL.appendingPathComponent(String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0))
    }

    private func initialCursor(for url: URL) -> SessionFileCursor {
        let stat = WorkflowStorage.fileStat(at: url)
        let size = stat?.size ?? 0
        let offset = size > Self.bootstrapByteLimit ? size - Self.bootstrapByteLimit : 0
        return SessionFileCursor(
            url: url, fileIdentifier: stat?.identifier, offset: offset,
            isDiscardingLine: offset > 0,
            metadata: WorkflowRolloutMetadataReader.metadata(transcriptPath: url.path),
            history: offset > 0 ? SessionHistoryCursor(offset: size, contextLookupOffset: offset) : nil,
            initialContextOffset: offset > 0 ? offset : nil,
            bootstrapEnd: offset > 0 ? size : nil
        )
    }

    private func backfillHistory(into cursor: inout SessionFileCursor, limit: Int, budget: inout Int) -> Bool {
        guard var history = cursor.history, history.offset > 0 else { return true }
        guard let before = WorkflowStorage.fileStat(at: cursor.url),
              before.identifier == cursor.fileIdentifier, before.size >= cursor.offset,
              let handle = try? FileHandle(forReadingFrom: cursor.url) else { return false }
        defer { try? handle.close() }
        let count = min(limit, budget, Int(history.offset))
        let start = history.offset - UInt64(count)
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: count) else { return false }
        budget -= data.count
        // 短读或后置检查失败前实际读到的字节也计入补查预算
        cursor.totalHistoryBytesRead += UInt64(data.count)
        guard data.count == count else { return false }
        history.offset = start
        history.consume(data, file: cursor, maximumBufferedLineByteCount: Self.maximumBufferedLineByteCount)
        guard let after = WorkflowStorage.fileStat(at: cursor.url),
              after.identifier == before.identifier, after.size >= before.size else { return false }
        for (turnID, earlier) in history.lifecycleByTurnID {
            var latest = cursor.lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
            if latest.terminal == nil, earlier.terminal != nil {
                latest.isHistoricalTerminal = true
            }
            latest.mergeEarlier(earlier)
            cursor.lifecycleByTurnID[turnID] = latest
        }
        cursor.restoreInitialContext(from: history)
        // 已合并的事实留在主游标, 回读只保留跨块半行和待定位的进展
        history.lifecycleByTurnID.removeAll(keepingCapacity: true)
        cursor.history = history
        return true
    }

    private func scan(into cursor: inout SessionFileCursor, limit: Int, now: Date = Date()) -> CodexSessionReadStatus {
        cursor.lastReadByteCount = 0
        var previousTailUnchangedSince = cursor.incompleteTailUnchangedSince
        cursor.incompleteTailUnchangedSince = nil
        guard let stat = WorkflowStorage.fileStat(at: cursor.url) else { return .unavailable }
        if stat.size < cursor.offset || (cursor.fileIdentifier != nil && cursor.fileIdentifier != stat.identifier) {
            cursor = initialCursor(for: cursor.url)
            previousTailUnchangedSince = nil
        }
        let end = stat.size
        guard let handle = try? FileHandle(forReadingFrom: cursor.url) else { return .unavailable }
        defer { try? handle.close() }
        if end > cursor.offset {
            guard limit > 0 else { return .incomplete }
            guard (try? handle.seek(toOffset: cursor.offset)) != nil,
                  let data = try? handle.read(upToCount: min(limit, Int(end - cursor.offset))), !data.isEmpty else { return .unavailable }
            cursor.lastReadByteCount = data.count
            cursor.offset += UInt64(data.count)
            cursor.fileIdentifier = stat.identifier
            cursor.consume(data, maximumBufferedLineByteCount: Self.maximumBufferedLineByteCount)
        }
        guard let after = WorkflowStorage.fileStat(at: cursor.url), after.identifier == stat.identifier,
              after.size >= end else { return .unavailable }
        // 只有实际文件末尾的有界半行可以计时, 积压和跳过的大行不能作为静默依据
        if cursor.offset == after.size, cursor.hasPartialLine, !cursor.isDiscardingLine {
            cursor.incompleteTailUnchangedSince = cursor.lastReadByteCount > 0 ? now : previousTailUnchangedSince ?? now
        }
        return cursor.offset == end && !cursor.hasPartialLine ? .complete : .incomplete
    }

    private static let bootstrapByteLimit: UInt64 = 512 * 1024
    private static let readByteLimit = 8 * 1024 * 1024
    private static let maximumBufferedLineByteCount = 16 * 1024 * 1024
}

private nonisolated struct SessionSupplementalHistoryRead {
    let initialHistoryBytesRead: UInt64
    var lastRequestedAt: Date
}

private nonisolated struct SessionFileCursor {
    let url: URL
    var fileIdentifier: UInt64?
    var offset: UInt64
    var isDiscardingLine: Bool
    var metadata: WorkflowRolloutMetadataPayload?
    var currentTurnID: String?
    var hasTurnBoundary = false
    var lifecycleByTurnID: [String: SessionTurnLifecycle] = [:]
    var supplementalHistoryByTurn: [String: SessionSupplementalHistoryRead] = [:]
    var totalHistoryBytesRead: UInt64 = 0
    var partialLineData = Data()
    var history: SessionHistoryCursor?
    var initialContextOffset: UInt64?
    private var pendingInitialProgress = SessionTurnLifecycle()
    private var initialProgressBeforeTerminal: [String: SessionTurnLifecycle] = [:]
    var bootstrapEnd: UInt64?
    private(set) var lastReadGapOffset: UInt64?
    var lastReadAt = Date()
    var lastReadByteCount = 0
    var incompleteTailUnchangedSince: Date?

    var hasDecodeFailures: Bool {
        lastReadGapOffset != nil
    }

    var hasPartialLine: Bool {
        isDiscardingLine || !partialLineData.isEmpty
    }

    private var hasPendingInitialProgress: Bool {
        initialContextOffset != nil && pendingInitialProgress.lastProgressAt != nil
    }

    func hasHistoryGap(for turnID: String) -> Bool {
        let hasStart = lifecycleByTurnID[turnID]?.startedAt != nil
        return (hasPendingInitialProgress && !hasStart)
            || history.map { $0.requiresLeadingLineRecovery || ($0.offset > 0 && (!hasStart || hasPendingInitialProgress)) } == true
    }

    func historyReadLimit(for reference: CodexActivityTurnReference) -> Int {
        guard history.map({ $0.offset > 0 }) == true else { return 0 }
        let known = lifecycleByTurnID[reference.turnID]
        if known?.terminal == nil, !reference.isTerminalUsageOnly {
            let needsHistory = hasPendingInitialProgress || history?.requiresLeadingLineRecovery == true
                || known?.startedAt == nil || known?.hasContext != true
                || known?.effort == nil || known?.approvalReviewer == nil
            return needsHistory ? Int.max : 0
        }
        guard known?.terminal == nil || known?.rootTurnID == nil || known?.hasTokenUsageRecord != true else { return 0 }
        let initialBytes = supplementalHistoryByTurn[reference.turnID]?.initialHistoryBytesRead ?? totalHistoryBytesRead
        let consumedBytes = min(UInt64(Self.supplementalHistoryByteLimit), totalHistoryBytesRead - initialBytes)
        return Self.supplementalHistoryByteLimit - Int(consumedBytes)
    }

    mutating func prepareSupplementalHistory(for references: [CodexActivityTurnReference], now: Date) {
        let initial = SessionSupplementalHistoryRead(initialHistoryBytesRead: totalHistoryBytesRead, lastRequestedAt: now)
        for reference in references where reference.isTerminalUsageOnly || lifecycleByTurnID[reference.turnID]?.terminal != nil {
            supplementalHistoryByTurn[reference.turnID, default: initial].lastRequestedAt = now
        }
    }

    private static let supplementalHistoryByteLimit = 32 * 1024 * 1024

    mutating func restoreInitialContext(from history: SessionHistoryCursor) {
        guard initialContextOffset != nil, history.hasInitialTurnBoundary, !history.initialContextHasReadGap else { return }
        if let turnID = history.initialTurnID {
            var state = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
            state.mergeEarlier(initialProgressBeforeTerminal[turnID] ?? pendingInitialProgress)
            lifecycleByTurnID[turnID] = state
        }
        pendingInitialProgress = SessionTurnLifecycle()
        initialContextOffset = nil
        // 尾部可能已进入下一轮, 补查只给启动片段补归属, 不回退当前轮次
        if !hasTurnBoundary {
            currentTurnID = history.initialTurnID.flatMap { initialProgressBeforeTerminal[$0] == nil ? $0 : nil }
            hasTurnBoundary = true
        }
        initialProgressBeforeTerminal.removeAll()
    }

    /// 读取预算可以在一行中间结束, 游标仍需推进并在下一轮继续拼接
    /// 超过缓冲上限后只扫描到换行, 避免异常大行阻塞后续终态
    mutating func consume(_ data: Data, maximumBufferedLineByteCount: Int) {
        var fragmentStart = data.startIndex
        while let newline = data[fragmentStart...].firstIndex(of: JSONLines.newlineByte) {
            if isDiscardingLine, let bootstrapEnd {
                let lineEnd = offset - UInt64(data.count) + UInt64(newline + 1)
                self.bootstrapEnd = nil
                // 启动时跨过的半行后来才写完, 重新定位这一行以免正反两路都跳过它
                if lineEnd > bootstrapEnd {
                    history = SessionHistoryCursor(
                        offset: lineEnd, contextLookupOffset: initialContextOffset, requiresLeadingLineRecovery: true
                    )
                }
            }
            consumeLineFragment(
                data[fragmentStart ..< newline],
                completesLine: true,
                endingAt: offset - UInt64(data.count) + UInt64(newline + 1),
                maximumBufferedLineByteCount: maximumBufferedLineByteCount
            )
            fragmentStart = data.index(after: newline)
        }
        if fragmentStart < data.endIndex {
            consumeLineFragment(
                data[fragmentStart...],
                completesLine: false,
                endingAt: offset,
                maximumBufferedLineByteCount: maximumBufferedLineByteCount
            )
        }
    }

    private mutating func consumeLineFragment(
        _ fragment: Data.SubSequence,
        completesLine: Bool,
        endingAt: UInt64,
        maximumBufferedLineByteCount: Int
    ) {
        if isDiscardingLine {
            if completesLine {
                isDiscardingLine = false
            }
            return
        }

        guard fragment.count <= maximumBufferedLineByteCount - partialLineData.count else {
            partialLineData.removeAll(keepingCapacity: false)
            markReadGap(at: endingAt)
            isDiscardingLine = !completesLine
            return
        }

        partialLineData.append(contentsOf: fragment)
        guard completesLine else { return }
        let keepsCapacity = partialLineData.count <= Self.retainedLineCapacityByteLimit
        defer { partialLineData.removeAll(keepingCapacity: keepsCapacity) }

        applyCompleteLine(partialLineData, endingAt: endingAt)
    }

    @discardableResult
    mutating func applyCompleteLine(_ data: Data, endingAt: UInt64) -> CodexRolloutLineEnvelope? {
        guard !JSONLines.isBlankLine(data) else { return nil }
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(CodexRolloutLineEnvelope.self, from: data) else {
            markReadGap(at: endingAt)
            return nil
        }
        apply(envelope)
        if envelope.type == "token_usage_record", let turnID = envelope.payload?.turnID {
            // 用量字段损坏不能影响生命周期解码, 也不能沿用上一条累计值
            var state = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
            state.tokenUsage = nil
            state.hasTokenUsageRecord = true
            if let record = try? decoder.decode(CodexRolloutTokenUsageRecord.self, from: data).payload,
               record.threadID == metadata?.id,
               record.sessionID == (metadata?.sessionID ?? metadata?.id),
               !record.responseID.isEmpty, !record.rootTurnID.isEmpty,
               !turnID.isEmpty, record.turnTokenUsage.isValid {
                state.tokenUsage = record.turnTokenUsage
                state.rootTurnID = record.rootTurnID
            }
            lifecycleByTurnID[turnID] = state
        }
        return envelope
    }

    private static let retainedLineCapacityByteLimit = 512 * 1024

    /// 损坏可能遮住 turn 边界, 只保留已明确结束的事实, 后续新 turn 独立建立覆盖
    mutating func markReadGap(at offset: UInt64) {
        lastReadGapOffset = offset
        currentTurnID = nil
        hasTurnBoundary = true
        pendingInitialProgress = SessionTurnLifecycle()
        initialProgressBeforeTerminal.removeAll()
        for turnID in lifecycleByTurnID.keys {
            lifecycleByTurnID[turnID]?.tokenUsage = nil
            lifecycleByTurnID[turnID]?.hasTokenUsageRecord = true
            if lifecycleByTurnID[turnID]?.terminal == nil {
                lifecycleByTurnID[turnID]?.hasReadGap = true
            }
        }
    }

    mutating func apply(_ envelope: CodexRolloutLineEnvelope) {
        if envelope.endsTurnContext, !hasTurnBoundary, initialContextOffset != nil,
           let turnID = envelope.payload?.turnID, !turnID.isEmpty, initialProgressBeforeTerminal[turnID] == nil {
            // 起始归属尚未恢复, 先保留各轮次结束前的进展, 不让迟到终态截断其他轮次
            initialProgressBeforeTerminal[turnID] = pendingInitialProgress
        }
        if envelope.startsTurnContext {
            hasTurnBoundary = true
            currentTurnID = envelope.payload?.turnID.flatMap { $0.isEmpty ? nil : $0 }
            if let turnID = currentTurnID, let rootTurnID = envelope.payload?.rootTurnID, !rootTurnID.isEmpty {
                var state = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
                state.rootTurnID = rootTurnID
                lifecycleByTurnID[turnID] = state
            }
        }
        if let event = envelope.progressEvent(currentTurnID: currentTurnID) {
            apply(event)
        } else if !hasTurnBoundary, initialContextOffset != nil, let progress = envelope.unassignedProgress {
            // 只暂存启动片段的进展时间, 首个轮次边界之后按新上下文正常处理
            pendingInitialProgress.apply(progress)
        }
        if let event = envelope.lifecycleEvent {
            apply(event)
        }
        if envelope.type == "turn_context", let turnID = currentTurnID {
            var state = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
            state.hasContext = true
            lifecycleByTurnID[turnID] = state
        }
        if envelope.endsTurnContext, envelope.payload?.turnID == currentTurnID {
            currentTurnID = nil
        }
    }

    mutating func apply(_ event: SessionLifecycleEvent) {
        var state = lifecycleByTurnID[event.turnID] ?? SessionTurnLifecycle()
        state.apply(event.change)
        lifecycleByTurnID[event.turnID] = state
    }
}

/// 从启动时的文件末尾向前读, 每个完整行只在回读链路中解析一次
private nonisolated struct SessionHistoryCursor {
    var offset: UInt64
    var contextLookupOffset: UInt64?
    var requiresLeadingLineRecovery = false
    private var hasSkippedTail = false
    var lifecycleByTurnID: [String: SessionTurnLifecycle] = [:]
    private var partialLineData = Data()
    // 第一段可能是尚未落盘完整的尾行, 由正向游标继续跟踪
    private var isDiscardingLine = true
    private var hasDecodeFailures = false
    private var pendingProgress = SessionTurnLifecycle()
    private var progressAfterTerminals: [(turnID: String, progress: SessionTurnLifecycle)] = []
    private var initialEndedTurnIDs: Set<String> = []
    private(set) var hasInitialTurnBoundary = false
    private(set) var initialTurnID: String?
    private(set) var initialContextHasReadGap = false

    mutating func consume(_ data: Data, file: SessionFileCursor, maximumBufferedLineByteCount: Int) {
        var end = data.endIndex
        while let newline = data[..<end].lastIndex(of: JSONLines.newlineByte) {
            prepend(data[(newline + 1) ..< end], maximumBufferedLineByteCount: maximumBufferedLineByteCount)
            finishLine(file: file, lineStart: offset + UInt64(newline + 1))
            end = newline
        }
        prepend(data[..<end], maximumBufferedLineByteCount: maximumBufferedLineByteCount)
        if offset == 0 {
            finishLine(file: file, lineStart: 0)
        }
    }

    private mutating func prepend(_ fragment: Data.SubSequence, maximumBufferedLineByteCount: Int) {
        guard !isDiscardingLine else { return }
        guard fragment.count <= maximumBufferedLineByteCount - partialLineData.count else {
            partialLineData.removeAll(keepingCapacity: false)
            isDiscardingLine = true
            hasDecodeFailures = true
            pendingProgress = SessionTurnLifecycle()
            progressAfterTerminals.removeAll()
            return
        }
        partialLineData = Data(fragment) + partialLineData
    }

    private mutating func finishLine(file: SessionFileCursor, lineStart: UInt64) {
        if hasSkippedTail {
            requiresLeadingLineRecovery = false
        }
        hasSkippedTail = true
        defer {
            partialLineData.removeAll(keepingCapacity: false)
            isDiscardingLine = false
        }
        guard !isDiscardingLine, !partialLineData.isEmpty else { return }
        var earlier = SessionFileCursor(
            url: file.url, fileIdentifier: file.fileIdentifier, offset: 0,
            isDiscardingLine: false, metadata: file.metadata
        )
        let envelope = earlier.applyCompleteLine(partialLineData, endingAt: lineStart + UInt64(partialLineData.count))
        if earlier.hasDecodeFailures {
            hasDecodeFailures = true
            pendingProgress = SessionTurnLifecycle()
            progressAfterTerminals.removeAll()
        }
        if let envelope {
            if !hasInitialTurnBoundary, let contextLookupOffset, lineStart <= contextLookupOffset {
                if envelope.endsTurnContext, let turnID = envelope.payload?.turnID, !turnID.isEmpty {
                    initialEndedTurnIDs.insert(turnID)
                }
                if envelope.startsTurnContext {
                    hasInitialTurnBoundary = true
                    initialContextHasReadGap = hasDecodeFailures
                    initialTurnID = envelope.payload?.turnID.flatMap { $0.isEmpty || initialEndedTurnIDs.contains($0) ? nil : $0 }
                    initialEndedTurnIDs.removeAll()
                }
            }
            if envelope.endsTurnContext, let turnID = envelope.payload?.turnID, !turnID.isEmpty {
                progressAfterTerminals.append((turnID, pendingProgress))
                pendingProgress = SessionTurnLifecycle()
            }
            if envelope.startsTurnContext {
                if let turnID = envelope.payload?.turnID, !turnID.isEmpty {
                    var state = earlier.lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
                    state.mergeEarlier(pendingProgress)
                    // 反向读到开始边界后才确定归属, 只排除该轮次自身结束后的进展
                    for segment in progressAfterTerminals.reversed() {
                        guard segment.turnID != turnID else { break }
                        state.mergeEarlier(segment.progress)
                    }
                    earlier.lifecycleByTurnID[turnID] = state
                }
                pendingProgress = SessionTurnLifecycle()
                progressAfterTerminals.removeAll()
            }
            // 没有显式轮次的进展, 遇到更早的上下文边界后才能确定归属
            if let progress = envelope.unassignedProgress {
                pendingProgress.apply(progress)
            }
        }
        for (turnID, var state) in earlier.lifecycleByTurnID {
            // 正向新增的坏行可能不在历史快照中, 按位置保留跨过该缺口的轮次状态
            if hasDecodeFailures || file.lastReadGapOffset.map({ lineStart < $0 }) == true {
                state.hasReadGap = true
                state.tokenUsage = nil
                state.hasTokenUsageRecord = true
            }
            var latest = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
            latest.mergeEarlier(state)
            lifecycleByTurnID[turnID] = latest
        }
    }
}

// MARK: - rollout 行解码

/// Codex rollout JSONL 单行的共享解码模型
/// Hook 子进程 (WorkflowTurnContextReader) 与 lifecycle reader 共用同一份 schema
nonisolated struct CodexRolloutLineEnvelope: Decodable {
    let timestamp: String?
    let type: String
    let payload: CodexRolloutLinePayload?
}

nonisolated struct CodexRolloutLinePayload: Decodable {
    let type: String?
    let turnID: String?
    let rootTurnID: String?
    let messageMetadata: CodexRolloutMessageMetadata?
    let role: String?
    let startedAt: Double?
    let completedAt: Double?
    let durationMilliseconds: Double?
    let approvalReviewer: CodexApprovalReviewer?
    let effort: String?

    var normalizedEffort: String? {
        guard let effort else {
            return nil
        }
        let value = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private enum CodingKeys: String, CodingKey {
        case type, role
        case turnID = "turn_id"
        case rootTurnID = "root_turn_id"
        case messageMetadata = "internal_chat_message_metadata_passthrough"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMilliseconds = "duration_ms"
        case approvalReviewer = "approvals_reviewer"
        case effort
    }
}

nonisolated struct CodexRolloutMessageMetadata: Decodable {
    let turnID: String?

    private enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
    }
}

private nonisolated extension CodexRolloutLineEnvelope {
    var startsTurnContext: Bool {
        type == "turn_context" || (type == "event_msg" && ["task_started", "turn_started"].contains(payload?.type ?? ""))
    }

    var endsTurnContext: Bool {
        type == "event_msg" && ["task_complete", "turn_complete", "turn_aborted"].contains(payload?.type ?? "")
    }

    func progressEvent(currentTurnID: String?) -> SessionLifecycleEvent? {
        guard let turnID = explicitProgressTurnID ?? currentTurnID, !turnID.isEmpty,
              let change = progressChange else { return nil }
        return SessionLifecycleEvent(turnID: turnID, change: change)
    }

    var unassignedProgress: SessionLifecycleChange? {
        explicitProgressTurnID == nil ? progressChange : nil
    }

    private var explicitProgressTurnID: String? {
        type == "response_item" ? payload?.messageMetadata?.turnID : payload?.turnID
    }

    private var progressChange: SessionLifecycleChange? {
        let progressTypes: Set = [
            "token_count", "item_completed", "agent_message", "agent_reasoning",
            "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted"
        ]
        guard type == "response_item" || type == "token_usage_record"
            || (type == "event_msg" && payload?.type.map(progressTypes.contains) == true) else {
            return nil
        }
        let eventDate = timestamp.flatMap(CodexDateFormat.iso8601Date)
            ?? payload?.completedAt.flatMap(Self.date)
            ?? payload?.startedAt.flatMap(Self.date)
        guard let eventDate else {
            return nil
        }

        let isExecutionProgress = if type == "response_item" {
            payload?.role == "assistant" || ["function_call_output", "custom_tool_call_output", "tool_search_output"].contains(payload?.type ?? "")
        } else {
            type == "event_msg" && ["agent_message", "agent_reasoning"].contains(payload?.type ?? "")
        }
        return .progress(at: eventDate, resumesApproval: isExecutionProgress)
    }

    var lifecycleEvent: SessionLifecycleEvent? {
        guard let payload,
              let turnID = payload.turnID,
              !turnID.isEmpty else {
            return nil
        }

        if type == "turn_context" {
            let effort = payload.normalizedEffort
            guard payload.approvalReviewer != nil || effort != nil else {
                return nil
            }
            return SessionLifecycleEvent(
                turnID: turnID,
                change: .context(
                    approvalReviewer: payload.approvalReviewer,
                    effort: effort,
                    observedAt: timestamp.flatMap(CodexDateFormat.iso8601Date)
                )
            )
        }

        guard type == "event_msg" else {
            return nil
        }

        switch payload.type {
        case "task_started", "turn_started":
            guard let startedAt = payload.startedAt.flatMap(Self.date) else {
                return nil
            }
            return SessionLifecycleEvent(turnID: turnID, change: .started(at: startedAt))
        case "task_complete", "turn_complete":
            guard let completedAt = payload.completedAt.flatMap(Self.date) ?? timestamp.flatMap(CodexDateFormat.iso8601Date) else {
                return nil
            }
            let duration = payload.durationMilliseconds.flatMap { milliseconds in
                milliseconds.isFinite && milliseconds >= 0 ? milliseconds / 1000 : nil
            }
            return SessionLifecycleEvent(turnID: turnID, change: .completed(at: completedAt, duration: duration))
        case "turn_aborted":
            return SessionLifecycleEvent(
                turnID: turnID,
                change: .aborted(at: timestamp.flatMap(CodexDateFormat.iso8601Date))
            )
        default:
            return nil
        }
    }

    private static func date(from seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}

private nonisolated struct SessionLifecycleEvent {
    let turnID: String
    let change: SessionLifecycleChange
}

private nonisolated enum SessionLifecycleChange {
    case progress(at: Date, resumesApproval: Bool)
    case started(at: Date)
    case context(approvalReviewer: CodexApprovalReviewer?, effort: String?, observedAt: Date?)
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}

private nonisolated struct SessionTurnLifecycle {
    var tokenUsage: CodexTokenUsage?
    var hasTokenUsageRecord = false
    var isHistoricalTerminal = false
    var rootTurnID: String?
    var hasReadGap = false
    var contextObservedAt: Date?
    var hasContext = false
    var startedAt: Date?
    var approvalReviewer: CodexApprovalReviewer?
    var effort: String?
    var lastProgressAt: Date?
    var lastExecutionProgressAt: Date?
    var terminal: CodexSessionTaskTerminalState?

    mutating func mergeEarlier(_ earlier: Self) {
        hasReadGap = hasReadGap || earlier.hasReadGap
        hasContext = hasContext || earlier.hasContext
        if let start = earlier.startedAt {
            startedAt = min(startedAt ?? start, start)
        }
        approvalReviewer = approvalReviewer ?? earlier.approvalReviewer
        effort = effort ?? earlier.effort
        contextObservedAt = contextObservedAt ?? earlier.contextObservedAt
        rootTurnID = rootTurnID ?? earlier.rootTurnID
        terminal = terminal ?? earlier.terminal
        if let progress = earlier.lastProgressAt {
            lastProgressAt = max(lastProgressAt ?? progress, progress)
        }
        if let progress = earlier.lastExecutionProgressAt {
            lastExecutionProgressAt = max(lastExecutionProgressAt ?? progress, progress)
        }
        if !hasTokenUsageRecord {
            tokenUsage = earlier.tokenUsage
            hasTokenUsageRecord = earlier.hasTokenUsageRecord
        }
    }

    mutating func apply(_ change: SessionLifecycleChange) {
        switch change {
        case let .progress(at, resumesApproval):
            lastProgressAt = max(lastProgressAt ?? .distantPast, at)
            if resumesApproval {
                lastExecutionProgressAt = max(lastExecutionProgressAt ?? .distantPast, at)
            }
        case let .started(at):
            if let currentStartedAt = startedAt {
                startedAt = min(currentStartedAt, at)
            } else {
                startedAt = at
            }
        case let .context(reviewer, reasoningEffort, observedAt):
            hasContext = true
            contextObservedAt = observedAt ?? contextObservedAt
            approvalReviewer = reviewer ?? approvalReviewer
            effort = reasoningEffort ?? effort
        case let .completed(at, duration):
            terminal = .completed(at: at, duration: duration)
        case let .aborted(at):
            terminal = .aborted(at: at)
        }
    }
}

nonisolated struct CodexSessionTaskLifecycleState {
    let requestedThreadID: String
    let turnID: String
    let startedAt: Date?
    let approvalReviewer: CodexApprovalReviewer?
    let effort: String?
    let lastProgressAt: Date?
    let terminal: CodexSessionTaskTerminalState?
    var readStatus: CodexSessionReadStatus = .complete
    var hasContext = false
    var contextObservedAt: Date?
    var rootTurnID: String?
    var recordedThreadID: String?
    var rootSessionID: String?
    var parentThreadID: String?
    var lastExecutionProgressAt: Date?
    var incompleteTailUnchangedSince: Date?
    var tokenUsage: CodexTokenUsage?
    var isHistoricalTerminal = false
}

nonisolated enum CodexSessionReadStatus {
    case complete
    case incomplete
    case unavailable
    case notFound
}

nonisolated enum CodexSessionTaskTerminalState {
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}
