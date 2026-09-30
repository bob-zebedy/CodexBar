import Foundation

/// 活跃轮次的线程定位信息, 用于关联 rollout 生命周期事件
nonisolated struct CodexActivityTurnReference: Hashable {
    let threadID: String
    let turnID: String
    let startedAt: Date

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
        var budget = Self.contextByteLimit
        var performedBackfill = false
        var states: [CodexSessionTaskLifecycleState] = []
        let threadIDs = grouped.keys.sorted()
        let start = threadIDs.isEmpty ? 0 : roundRobinOffset % threadIDs.count
        let ordered = Array(threadIDs.dropFirst(start)) + Array(threadIDs.prefix(start))
        roundRobinOffset = threadIDs.isEmpty ? 0 : (start + 1) % threadIDs.count
        for threadID in ordered {
            guard let threadReferences = grouped[threadID],
                  let latest = threadReferences.max(by: { $0.startedAt < $1.startedAt }) else { continue }
            var status = CodexSessionReadStatus.notFound
            if var cursor = cursor(for: latest) {
                status = scan(into: &cursor, limit: min(Self.incrementalByteLimit, budget), now: now)
                if cursor.metadata?.id != threadID {
                    status = .unavailable
                }
                budget -= min(budget, cursor.lastReadByteCount)
                let needsContext = threadReferences.contains {
                    let known = cursor.lifecycleByTurnID[$0.turnID]
                    return known?.terminal == nil && (known?.hasContext != true || known?.effort == nil || known?.approvalReviewer == nil)
                }
                if status == .complete, needsContext, cursor.historicalOffset > 0,
                   !cursor.didBackfill, !performedBackfill {
                    status = backfillContext(into: &cursor)
                    performedBackfill = true
                }
                cursor.lastReadAt = now
                let referencedTurns = Set(threadReferences.map(\.turnID))
                cursor.lifecycleByTurnID = cursor.lifecycleByTurnID.filter {
                    referencedTurns.contains($0.key) || ($0.value.lastProgressAt ?? .distantPast) > cutoff
                }
                cursorsByThread[threadID] = cursor
            }
            let cursor = cursorsByThread[threadID]
            for reference in threadReferences {
                let known = cursor?.lifecycleByTurnID[reference.turnID]
                let hasReadGap = known?.hasReadGap ?? (cursor?.hasDecodeFailures == true)
                let turnStatus: CodexSessionReadStatus = status == .complete && hasReadGap && known?.terminal == nil
                    ? .incomplete : status
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
                    incompleteTailUnchangedSince: status == .incomplete && !hasReadGap && known?.hasContext == true && known?.terminal == nil
                        ? cursor?.incompleteTailUnchangedSince : nil,
                    tokenUsage: turnStatus == .complete ? known?.tokenUsage : nil
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
            url: url, fileIdentifier: stat?.identifier, offset: offset, historicalOffset: offset,
            isDiscardingLine: offset > 0,
            metadata: WorkflowRolloutMetadataReader.metadata(transcriptPath: url.path)
        )
    }

    private func backfillContext(into cursor: inout SessionFileCursor) -> CodexSessionReadStatus {
        let end = cursor.offset
        let start = end > UInt64(Self.contextByteLimit) ? end - UInt64(Self.contextByteLimit) : 0
        var restored = SessionFileCursor(
            url: cursor.url,
            fileIdentifier: cursor.fileIdentifier,
            offset: start,
            historicalOffset: start,
            isDiscardingLine: start > 0,
            metadata: cursor.metadata
        )
        let status = scan(into: &restored, limit: Self.contextByteLimit, through: end)
        guard status == .complete else { return status }
        restored.didBackfill = true
        cursor = restored
        return .complete
    }

    private func scan(into cursor: inout SessionFileCursor, limit: Int, through upperBound: UInt64? = nil, now: Date = Date()) -> CodexSessionReadStatus {
        cursor.lastReadByteCount = 0
        var previousTailUnchangedSince = cursor.incompleteTailUnchangedSince
        cursor.incompleteTailUnchangedSince = nil
        guard let stat = WorkflowStorage.fileStat(at: cursor.url) else { return .unavailable }
        if stat.size < cursor.offset || (cursor.fileIdentifier != nil && cursor.fileIdentifier != stat.identifier) {
            cursor = initialCursor(for: cursor.url)
            previousTailUnchangedSince = nil
        }
        let end = min(stat.size, upperBound ?? stat.size)
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
    private static let incrementalByteLimit = 8 * 1024 * 1024
    private static let contextByteLimit = 8 * 1024 * 1024
    private static let maximumBufferedLineByteCount = 16 * 1024 * 1024
}

private nonisolated struct SessionFileCursor {
    let url: URL
    var fileIdentifier: UInt64?
    var offset: UInt64
    let historicalOffset: UInt64
    var isDiscardingLine: Bool
    var metadata: WorkflowRolloutMetadataPayload?
    var currentTurnID: String?
    var lifecycleByTurnID: [String: SessionTurnLifecycle] = [:]
    var partialLineData = Data()
    var didBackfill = false
    var hasDecodeFailures = false
    var lastReadAt = Date()
    var lastReadByteCount = 0
    var incompleteTailUnchangedSince: Date?

    var hasPartialLine: Bool {
        isDiscardingLine || !partialLineData.isEmpty
    }

    /// 读取预算可以在一行中间结束, 游标仍需推进并在下一轮继续拼接
    /// 超过缓冲上限后只扫描到换行, 避免异常大行阻塞后续终态
    mutating func consume(_ data: Data, maximumBufferedLineByteCount: Int) {
        var fragmentStart = data.startIndex
        while let newline = data[fragmentStart...].firstIndex(of: JSONLines.newlineByte) {
            consumeLineFragment(
                data[fragmentStart ..< newline],
                completesLine: true,
                maximumBufferedLineByteCount: maximumBufferedLineByteCount
            )
            fragmentStart = data.index(after: newline)
        }
        if fragmentStart < data.endIndex {
            consumeLineFragment(
                data[fragmentStart...],
                completesLine: false,
                maximumBufferedLineByteCount: maximumBufferedLineByteCount
            )
        }
    }

    private mutating func consumeLineFragment(
        _ fragment: Data.SubSequence,
        completesLine: Bool,
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
            markReadGap()
            isDiscardingLine = !completesLine
            return
        }

        partialLineData.append(contentsOf: fragment)
        guard completesLine else { return }
        let keepsCapacity = partialLineData.count <= Self.retainedLineCapacityByteLimit
        defer { partialLineData.removeAll(keepingCapacity: keepsCapacity) }

        let decoded = JSONLines.decodeWithFailures(CodexRolloutLineEnvelope.self, from: partialLineData)
        if decoded.failedLineCount > 0 {
            markReadGap()
        }
        for envelope in decoded.values {
            apply(envelope)
            if envelope.type == "token_usage_record", let turnID = envelope.payload?.turnID {
                // 用量字段损坏不能影响生命周期解码, 也不能沿用上一条累计值
                var state = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
                state.tokenUsage = nil
                if let record = try? JSONDecoder().decode(CodexRolloutTokenUsageRecord.self, from: partialLineData).payload,
                   record.threadID == metadata?.id,
                   record.sessionID == (metadata?.sessionID ?? metadata?.id),
                   !record.responseID.isEmpty, !record.rootTurnID.isEmpty,
                   !turnID.isEmpty, record.turnTokenUsage.isValid {
                    state.tokenUsage = record.turnTokenUsage
                    state.rootTurnID = record.rootTurnID
                }
                lifecycleByTurnID[turnID] = state
            }
        }
    }

    private static let retainedLineCapacityByteLimit = 512 * 1024

    /// 损坏可能遮住 turn 边界, 只保留已明确结束的事实, 后续新 turn 独立建立覆盖
    mutating func markReadGap() {
        hasDecodeFailures = true
        currentTurnID = nil
        for turnID in lifecycleByTurnID.keys {
            lifecycleByTurnID[turnID]?.tokenUsage = nil
            if lifecycleByTurnID[turnID]?.terminal == nil {
                lifecycleByTurnID[turnID]?.hasReadGap = true
            }
        }
    }

    mutating func apply(_ envelope: CodexRolloutLineEnvelope) {
        if envelope.startsTurnContext {
            currentTurnID = envelope.payload?.turnID.flatMap { $0.isEmpty ? nil : $0 }
            if let turnID = currentTurnID, let rootTurnID = envelope.payload?.rootTurnID, !rootTurnID.isEmpty {
                var state = lifecycleByTurnID[turnID] ?? SessionTurnLifecycle()
                state.rootTurnID = rootTurnID
                lifecycleByTurnID[turnID] = state
            }
        }
        if let event = envelope.progressEvent(currentTurnID: currentTurnID) {
            apply(event)
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

        let explicitTurnID = type == "response_item" ? payload?.messageMetadata?.turnID : payload?.turnID
        guard let turnID = explicitTurnID ?? currentTurnID, !turnID.isEmpty else {
            return nil
        }
        let isExecutionProgress = if type == "response_item" {
            payload?.role == "assistant" || ["function_call_output", "custom_tool_call_output", "tool_search_output"].contains(payload?.type ?? "")
        } else {
            type == "event_msg" && ["agent_message", "agent_reasoning"].contains(payload?.type ?? "")
        }
        return SessionLifecycleEvent(turnID: turnID, change: .progress(at: eventDate, resumesApproval: isExecutionProgress))
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
