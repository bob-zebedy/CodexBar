import Foundation

/// 活跃 turn 的最小定位信息, 只在进程内用于关联 Codex session 生命周期事件
nonisolated struct CodexActivityTurnReference: Hashable {
    let sessionId: String
    let turnId: String
    let startedAt: Date
}

/// 文件读取结果包含覆盖状态, 缓存事实不能替代本轮读取成功
actor CodexSessionLifecycleReader {
    private let sessionsRootURL: URL
    private let archivedSessionsRootURL: URL
    private let fileManager: FileManager
    private var roundRobinOffset = 0
    private var cursorsBySession: [String: SessionFileCursor] = [:]
    private var lastResolutionAttemptBySession: [String: Date] = [:]
    private var lastRecursiveAttemptBySession: [String: Date] = [:]

    init(codexHomeURL: URL = CodexCLIResolver.codexHomeDirectory(), fileManager: FileManager = .default) {
        sessionsRootURL = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        archivedSessionsRootURL = codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        self.fileManager = fileManager
    }

    func lifecycleStates(for references: [CodexActivityTurnReference]) -> [CodexSessionTaskLifecycleState] {
        let grouped = Dictionary(grouping: references, by: \.sessionId)
        let cutoff = Date().addingTimeInterval(-CodexActivityRetention.window)
        cursorsBySession = cursorsBySession.filter { $0.value.lastReadAt > cutoff }
        lastResolutionAttemptBySession = lastResolutionAttemptBySession.filter { $0.value > cutoff }
        lastRecursiveAttemptBySession = lastRecursiveAttemptBySession.filter { $0.value > cutoff }
        var budget = Self.contextByteLimit
        var performedBackfill = false
        var states: [CodexSessionTaskLifecycleState] = []
        let sessions = grouped.keys.sorted()
        let start = sessions.isEmpty ? 0 : roundRobinOffset % sessions.count
        let ordered = Array(sessions.dropFirst(start)) + Array(sessions.prefix(start))
        roundRobinOffset = sessions.isEmpty ? 0 : (start + 1) % sessions.count
        for sessionId in ordered {
            guard let sessionReferences = grouped[sessionId],
                  let latest = sessionReferences.max(by: { $0.startedAt < $1.startedAt }) else { continue }
            var status = CodexSessionReadStatus.notFound
            if var cursor = cursor(for: latest) {
                status = scan(into: &cursor, limit: min(Self.incrementalByteLimit, budget))
                budget -= min(budget, cursor.lastReadByteCount)
                let needsContext = sessionReferences.contains {
                    let known = cursor.lifecycleByTurnId[$0.turnId]
                    return known?.terminal == nil && (known?.hasContext != true || known?.effort == nil || known?.approvalReviewer == nil)
                }
                if status == .complete, needsContext, cursor.historicalOffset > 0,
                   !cursor.didBackfill, !performedBackfill {
                    status = backfillContext(into: &cursor)
                    performedBackfill = true
                }
                cursor.lastReadAt = Date()
                let referencedTurns = Set(sessionReferences.map(\.turnId))
                cursor.lifecycleByTurnId = cursor.lifecycleByTurnId.filter {
                    referencedTurns.contains($0.key) || ($0.value.lastProgressAt ?? .distantPast) > cutoff
                }
                cursorsBySession[sessionId] = cursor
            }
            let cursor = cursorsBySession[sessionId]
            for reference in sessionReferences {
                let known = cursor?.lifecycleByTurnId[reference.turnId]
                let hasReadGap = known?.hasReadGap ?? (cursor?.hasDecodeFailures == true)
                let turnStatus: CodexSessionReadStatus = status == .complete && hasReadGap && known?.terminal == nil
                    ? .incomplete : status
                states.append(CodexSessionTaskLifecycleState(
                    sessionId: sessionId, turnId: reference.turnId, startedAt: known?.startedAt,
                    approvalReviewer: known?.approvalReviewer, effort: known?.effort,
                    lastProgressAt: known?.lastProgressAt, terminal: turnStatus == .complete ? known?.terminal : nil,
                    readStatus: turnStatus, hasContext: known?.hasContext == true,
                    contextObservedAt: known?.contextObservedAt
                ))
            }
        }
        return states
    }

    func resetResolutionFallbacks() {
        lastResolutionAttemptBySession.removeAll()
        lastRecursiveAttemptBySession.removeAll()
    }

    private func cursor(for reference: CodexActivityTurnReference) -> SessionFileCursor? {
        if let cursor = cursorsBySession[reference.sessionId], fileManager.fileExists(atPath: cursor.url.path) {
            return cursor
        }
        if cursorsBySession.removeValue(forKey: reference.sessionId) != nil {
            lastResolutionAttemptBySession.removeValue(forKey: reference.sessionId)
            lastRecursiveAttemptBySession.removeValue(forKey: reference.sessionId)
        }
        let now = Date()
        if let last = lastResolutionAttemptBySession[reference.sessionId], now.timeIntervalSince(last) < 10 {
            return nil
        }
        lastResolutionAttemptBySession[reference.sessionId] = now
        let suffix = "-\(reference.sessionId).jsonl"
        for directory in [sessionDirectory(for: reference.startedAt), sessionDirectory(for: now), archivedSessionsRootURL] {
            if let url = matchingFile(in: directory, suffix: suffix) {
                return initialCursor(for: url)
            }
        }
        if let last = lastRecursiveAttemptBySession[reference.sessionId], now.timeIntervalSince(last) < 60 {
            return nil
        }
        lastRecursiveAttemptBySession[reference.sessionId] = now
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            return initialCursor(for: url)
        }
        return nil
    }

    private func matchingFile(in directory: URL, suffix: String) -> URL? {
        (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .first { $0.lastPathComponent.hasSuffix(suffix) }
    }

    private func sessionDirectory(for date: Date) -> URL {
        let components = CodexDateFormat.localGregorianCalendar.dateComponents([.year, .month, .day], from: date)
        return sessionsRootURL.appendingPathComponent(String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0))
    }

    private func initialCursor(for url: URL) -> SessionFileCursor {
        let stat = WorkflowStorage.fileStat(at: url)
        let size = stat?.size ?? 0
        let offset = size > Self.bootstrapByteLimit ? size - Self.bootstrapByteLimit : 0
        return SessionFileCursor(url: url, fileIdentifier: stat?.identifier, offset: offset, historicalOffset: offset, discardsLeadingPartialLine: offset > 0)
    }

    private func backfillContext(into cursor: inout SessionFileCursor) -> CodexSessionReadStatus {
        let end = cursor.offset
        let start = end > UInt64(Self.contextByteLimit) ? end - UInt64(Self.contextByteLimit) : 0
        var restored = SessionFileCursor(
            url: cursor.url,
            fileIdentifier: cursor.fileIdentifier,
            offset: start,
            historicalOffset: start,
            discardsLeadingPartialLine: start > 0
        )
        let status = scan(into: &restored, limit: Self.contextByteLimit, through: end)
        guard status == .complete else { return status }
        restored.didBackfill = true
        cursor = restored
        return .complete
    }

    private func scan(into cursor: inout SessionFileCursor, limit: Int, through upperBound: UInt64? = nil) -> CodexSessionReadStatus {
        cursor.lastReadByteCount = 0
        guard let stat = WorkflowStorage.fileStat(at: cursor.url) else { return .unavailable }
        if stat.size < cursor.offset || (cursor.fileIdentifier != nil && cursor.fileIdentifier != stat.identifier) {
            cursor = initialCursor(for: cursor.url)
        }
        let end = min(stat.size, upperBound ?? stat.size)
        guard let handle = try? FileHandle(forReadingFrom: cursor.url) else { return .unavailable }
        defer { try? handle.close() }
        guard end > cursor.offset else { return .complete }
        guard limit > 0 else { return .incomplete }
        guard (try? handle.seek(toOffset: cursor.offset)) != nil,
              let data = try? handle.read(upToCount: min(limit, Int(end - cursor.offset))), !data.isEmpty else { return .unavailable }
        cursor.lastReadByteCount = data.count
        guard let newline = data.lastIndex(of: JSONLines.newlineByte) else { return .incomplete }
        let consumed = data.distance(from: data.startIndex, to: newline) + 1
        cursor.offset += UInt64(consumed)
        cursor.fileIdentifier = stat.identifier
        var complete = Data(data[...newline])
        if cursor.discardsLeadingPartialLine {
            complete = JSONLines.droppingLeadingPartialLine(complete)
            cursor.discardsLeadingPartialLine = false
        }
        for line in complete.split(separator: JSONLines.newlineByte) {
            let decoded = JSONLines.decodeWithFailures(CodexRolloutLineEnvelope.self, from: Data(line))
            if decoded.failedLineCount > 0 {
                cursor.markReadGap()
            }
            for envelope in decoded.values {
                cursor.apply(envelope)
            }
        }
        guard let after = WorkflowStorage.fileStat(at: cursor.url), after.identifier == stat.identifier,
              after.size >= end else { return .unavailable }
        return cursor.offset == end ? .complete : .incomplete
    }

    private static let bootstrapByteLimit: UInt64 = 512 * 1024
    private static let incrementalByteLimit = 8 * 1024 * 1024
    private static let contextByteLimit = 8 * 1024 * 1024
}

private nonisolated struct SessionFileCursor {
    let url: URL
    var fileIdentifier: UInt64?
    var offset: UInt64
    let historicalOffset: UInt64
    var discardsLeadingPartialLine: Bool
    var currentTurnId: String?
    var lifecycleByTurnId: [String: SessionTurnLifecycle] = [:]
    var didBackfill = false
    var hasDecodeFailures = false
    var lastReadAt = Date()
    var lastReadByteCount = 0

    /// 损坏可能遮住 turn 边界, 只保留已明确结束的事实, 后续新 turn 独立建立覆盖
    mutating func markReadGap() {
        hasDecodeFailures = true
        currentTurnId = nil
        for turnId in lifecycleByTurnId.keys where lifecycleByTurnId[turnId]?.terminal == nil {
            lifecycleByTurnId[turnId]?.hasReadGap = true
        }
    }

    mutating func apply(_ envelope: CodexRolloutLineEnvelope) {
        if envelope.startsTurnContext {
            currentTurnId = envelope.payload?.turnId.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let event = envelope.progressEvent(currentTurnId: currentTurnId) {
            apply(event)
        }
        if let event = envelope.lifecycleEvent {
            apply(event)
        }
        if envelope.type == "turn_context", let turnId = currentTurnId {
            var state = lifecycleByTurnId[turnId] ?? SessionTurnLifecycle()
            state.hasContext = true
            lifecycleByTurnId[turnId] = state
        }
        if envelope.endsTurnContext, envelope.payload?.turnId == currentTurnId {
            currentTurnId = nil
        }
    }

    mutating func apply(_ event: SessionLifecycleEvent) {
        var state = lifecycleByTurnId[event.turnId] ?? SessionTurnLifecycle()
        state.apply(event.change)
        lifecycleByTurnId[event.turnId] = state
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
    let turnId: String?
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
        case type
        case turnId = "turn_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMilliseconds = "duration_ms"
        case approvalReviewer = "approvals_reviewer"
        case effort
    }
}

private nonisolated extension CodexRolloutLineEnvelope {
    var startsTurnContext: Bool {
        type == "turn_context" || (type == "event_msg" && payload?.type == "task_started")
    }

    var endsTurnContext: Bool {
        type == "event_msg" && (payload?.type == "task_complete" || payload?.type == "turn_aborted")
    }

    func progressEvent(currentTurnId: String?) -> SessionLifecycleEvent? {
        let progressTypes: Set = ["token_count", "item_completed", "agent_message", "agent_reasoning", "task_started", "task_complete", "turn_aborted"]
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

        guard let turnId = payload?.turnId ?? currentTurnId, !turnId.isEmpty else {
            return nil
        }
        return SessionLifecycleEvent(turnId: turnId, change: .progress(at: eventDate))
    }

    var lifecycleEvent: SessionLifecycleEvent? {
        guard let payload,
              let turnId = payload.turnId,
              !turnId.isEmpty else {
            return nil
        }

        if type == "turn_context" {
            let effort = payload.normalizedEffort
            guard payload.approvalReviewer != nil || effort != nil else {
                return nil
            }
            return SessionLifecycleEvent(
                turnId: turnId,
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
        case "task_started":
            guard let startedAt = payload.startedAt.flatMap(Self.date) else {
                return nil
            }
            return SessionLifecycleEvent(turnId: turnId, change: .started(at: startedAt))
        case "task_complete":
            guard let completedAt = payload.completedAt.flatMap(Self.date) else {
                return nil
            }
            let duration = payload.durationMilliseconds.flatMap { milliseconds in
                milliseconds.isFinite && milliseconds >= 0 ? milliseconds / 1000 : nil
            }
            return SessionLifecycleEvent(turnId: turnId, change: .completed(at: completedAt, duration: duration))
        case "turn_aborted":
            return SessionLifecycleEvent(
                turnId: turnId,
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
    let turnId: String
    let change: SessionLifecycleChange
}

private nonisolated enum SessionLifecycleChange {
    case progress(at: Date)
    case started(at: Date)
    case context(approvalReviewer: CodexApprovalReviewer?, effort: String?, observedAt: Date?)
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}

private nonisolated struct SessionTurnLifecycle {
    var hasReadGap = false
    var contextObservedAt: Date?
    var hasContext = false
    var startedAt: Date?
    var approvalReviewer: CodexApprovalReviewer?
    var effort: String?
    var lastProgressAt: Date?
    var terminal: CodexSessionTaskTerminalState?

    mutating func apply(_ change: SessionLifecycleChange) {
        switch change {
        case let .progress(at):
            lastProgressAt = max(lastProgressAt ?? .distantPast, at)
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
    let sessionId: String
    let turnId: String
    let startedAt: Date?
    let approvalReviewer: CodexApprovalReviewer?
    let effort: String?
    let lastProgressAt: Date?
    let terminal: CodexSessionTaskTerminalState?
    var readStatus: CodexSessionReadStatus = .complete
    var hasContext = false
    var contextObservedAt: Date?
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
