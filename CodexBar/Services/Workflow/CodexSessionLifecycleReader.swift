import Foundation

/// 活跃 turn 的最小定位信息, 只在进程内用于关联 Codex session 生命周期事件
nonisolated struct CodexActivityTurnReference: Hashable {
    let sessionId: String
    let turnId: String
    let startedAt: Date
}

/// 增量读取活跃 Codex session 的 rollout JSONL, 只提取 turn 生命周期字段
actor CodexSessionLifecycleReader {
    private let sessionsRootURL: URL
    private let archivedSessionsRootURL: URL
    private let fileManager: FileManager
    private var cursorsBySession: [String: SessionFileCursor] = [:]
    private var lastResolutionAttemptBySession: [String: Date] = [:]
    private var recursiveFallbackSessionIds = Set<String>()

    init(
        codexHomeURL: URL = CodexCLIResolver.codexHomeDirectory(),
        fileManager: FileManager = .default
    ) {
        sessionsRootURL = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        archivedSessionsRootURL = codexHomeURL.appendingPathComponent(
            "archived_sessions",
            isDirectory: true
        )
        self.fileManager = fileManager
    }

    /// 返回 rollout 中已知的起点和终态, 不解码会话或工具内容
    func lifecycleStates(
        for references: [CodexActivityTurnReference]
    ) -> [CodexSessionTaskLifecycleState] {
        let referencesBySession = Dictionary(grouping: references, by: \CodexActivityTurnReference.sessionId)
        let activeSessionIds = Set(referencesBySession.keys)
        cursorsBySession = cursorsBySession.filter { activeSessionIds.contains($0.key) }
        lastResolutionAttemptBySession = lastResolutionAttemptBySession.filter {
            activeSessionIds.contains($0.key)
        }
        recursiveFallbackSessionIds.formIntersection(activeSessionIds)

        var states: [CodexSessionTaskLifecycleState] = []
        var performedEffortBackfill = false
        let now = Date()
        for (sessionId, sessionReferences) in referencesBySession {
            guard let reference = sessionReferences.max(by: { $0.startedAt < $1.startedAt }),
                  var cursor = cursor(for: reference) else {
                continue
            }

            scanNewLifecycleEvents(into: &cursor)
            pruneEffortBackfillState(
                in: &cursor,
                activeTurnIds: Set(sessionReferences.map(\.turnId))
            )
            if !performedEffortBackfill,
               let reference = effortBackfillReference(
                   from: sessionReferences,
                   cursor: cursor,
                   now: now
               ) {
                performedEffortBackfill = true
                cursor.lastEffortBackfillAttemptByTurnId[reference.turnId] = now
                switch backfilledEffort(
                    from: cursor.url,
                    turnId: reference.turnId
                ) {
                case let .found(effort):
                    var lifecycle = cursor.lifecycleByTurnId[reference.turnId]
                        ?? SessionTurnLifecycle()
                    lifecycle.apply(
                        .context(approvalReviewer: nil, effort: effort)
                    )
                    cursor.lifecycleByTurnId[reference.turnId] = lifecycle
                    cursor.completedEffortBackfillTurnIds.insert(reference.turnId)
                    cursor.lastEffortBackfillAttemptByTurnId.removeValue(
                        forKey: reference.turnId
                    )
                case .notFound:
                    cursor.completedEffortBackfillTurnIds.insert(reference.turnId)
                    cursor.lastEffortBackfillAttemptByTurnId.removeValue(
                        forKey: reference.turnId
                    )
                case .unavailable:
                    break
                }
            }
            cursorsBySession[sessionId] = cursor
            for reference in sessionReferences {
                guard let lifecycle = cursor.lifecycleByTurnId[reference.turnId] else {
                    continue
                }
                states.append(
                    CodexSessionTaskLifecycleState(
                        sessionId: reference.sessionId,
                        turnId: reference.turnId,
                        startedAt: lifecycle.startedAt,
                        approvalReviewer: lifecycle.approvalReviewer,
                        effort: lifecycle.effort,
                        terminal: lifecycle.terminal
                    )
                )
            }
        }
        return states
    }

    private func pruneEffortBackfillState(
        in cursor: inout SessionFileCursor,
        activeTurnIds: Set<String>
    ) {
        cursor.completedEffortBackfillTurnIds.formIntersection(activeTurnIds)
        cursor.lastEffortBackfillAttemptByTurnId = cursor
            .lastEffortBackfillAttemptByTurnId
            .filter { activeTurnIds.contains($0.key) }
    }

    private func effortBackfillReference(
        from references: [CodexActivityTurnReference],
        cursor: SessionFileCursor,
        now: Date
    ) -> CodexActivityTurnReference? {
        guard cursor.hasUnscannedHistoricalPrefix else {
            return nil
        }

        return references
            .filter { reference in
                guard now.timeIntervalSince(reference.startedAt)
                    >= Self.effortBackfillMinimumTaskAge,
                    cursor.lifecycleByTurnId[reference.turnId]?.effort == nil,
                    cursor.lifecycleByTurnId[reference.turnId]?.terminal == nil,
                    !cursor.completedEffortBackfillTurnIds.contains(reference.turnId) else {
                    return false
                }
                guard let lastAttempt = cursor
                    .lastEffortBackfillAttemptByTurnId[reference.turnId] else {
                    return true
                }
                return now.timeIntervalSince(lastAttempt)
                    >= Self.effortBackfillRetryInterval
            }
            .max(by: { $0.startedAt < $1.startedAt })
    }

    /// 唤醒后允许仍未定位到文件的活跃 session 重新执行一次递归兜底
    func resetResolutionFallbacks() {
        lastResolutionAttemptBySession.removeAll()
        recursiveFallbackSessionIds.removeAll()
    }

    // MARK: - 会话文件定位

    private func cursor(for reference: CodexActivityTurnReference) -> SessionFileCursor? {
        if let cursor = cursorsBySession[reference.sessionId],
           fileManager.fileExists(atPath: cursor.url.path) {
            return cursor
        }
        if cursorsBySession.removeValue(forKey: reference.sessionId) != nil {
            // 缓存文件可能被移动到 archived_sessions, 允许重新完整定位一次
            recursiveFallbackSessionIds.remove(reference.sessionId)
        }

        let now = Date()
        if let lastAttempt = lastResolutionAttemptBySession[reference.sessionId],
           now.timeIntervalSince(lastAttempt) < Self.fileResolutionRetryInterval {
            return nil
        }
        lastResolutionAttemptBySession[reference.sessionId] = now

        let url = locateLikelySessionFile(for: reference)
            ?? recursiveSessionFileIfNeeded(for: reference)
        guard let url else {
            return nil
        }
        lastResolutionAttemptBySession.removeValue(forKey: reference.sessionId)
        return initialCursor(for: url)
    }

    private func locateLikelySessionFile(for reference: CodexActivityTurnReference) -> URL? {
        let suffix = "-\(reference.sessionId).jsonl"
        let likelyDirectories = [
            sessionDirectory(for: reference.startedAt),
            sessionDirectory(for: Date()),
            archivedSessionsRootURL
        ]

        for directory in likelyDirectories {
            if let match = matchingFile(in: directory, suffix: suffix) {
                return match
            }
        }
        return nil
    }

    private func recursiveSessionFileIfNeeded(
        for reference: CodexActivityTurnReference
    ) -> URL? {
        guard recursiveFallbackSessionIds.insert(reference.sessionId).inserted else {
            return nil
        }

        // resume 可能继续很早以前创建的 session; 每次活跃生命周期最多递归一次
        let suffix = "-\(reference.sessionId).jsonl"
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(suffix) {
            return url
        }
        return nil
    }

    private func matchingFile(in directory: URL, suffix: String) -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls.first { $0.lastPathComponent.hasSuffix(suffix) }
    }

    private func sessionDirectory(for date: Date) -> URL {
        // Codex 的 sessions 目录名是公历, 必须固定公历日历
        let components = CodexDateFormat.localGregorianCalendar
            .dateComponents([.year, .month, .day], from: date)
        return sessionsRootURL
            .appendingPathComponent(String(format: "%04d", components.year ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 0), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 0), isDirectory: true)
    }

    private func initialCursor(for url: URL) -> SessionFileCursor {
        let stat = WorkflowStorage.fileStat(at: url)
        let size = stat?.size ?? 0
        let offset = size > Self.bootstrapByteLimit ? size - Self.bootstrapByteLimit : 0
        return SessionFileCursor(
            url: url,
            fileIdentifier: stat?.identifier,
            offset: offset,
            discardsLeadingPartialLine: offset > 0,
            lifecycleByTurnId: [:],
            hasUnscannedHistoricalPrefix: offset > 0,
            completedEffortBackfillTurnIds: [],
            lastEffortBackfillAttemptByTurnId: [:]
        )
    }

    private func backfilledEffort(
        from url: URL,
        turnId: String
    ) -> EffortBackfillResult {
        let size = WorkflowStorage.fileSize(at: url)
        guard size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return .unavailable
        }
        defer {
            try? handle.close()
        }

        let offset = size > Self.effortBackfillByteLimit
            ? size - Self.effortBackfillByteLimit
            : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty else {
            return .unavailable
        }

        let completeData = offset > 0
            ? JSONLines.droppingLeadingPartialLine(data)
            : data
        for envelope in JSONLines.decode(
            CodexRolloutLineEnvelope.self,
            from: completeData
        ).reversed() where envelope.type == "turn_context"
            && envelope.payload?.turnId == turnId {
            if let effort = envelope.payload?.normalizedEffort {
                return .found(effort)
            }
        }
        return .notFound
    }

    // MARK: - 增量扫描

    private func scanNewLifecycleEvents(into cursor: inout SessionFileCursor) {
        let stat = WorkflowStorage.fileStat(at: cursor.url)
        let size = stat?.size ?? 0
        let identifier = stat?.identifier
        if size < cursor.offset
            || (cursor.fileIdentifier != nil && identifier != nil && cursor.fileIdentifier != identifier) {
            cursor = initialCursor(for: cursor.url)
        }

        guard size > cursor.offset,
              let handle = try? FileHandle(forReadingFrom: cursor.url) else {
            return
        }
        defer {
            try? handle.close()
        }

        guard (try? handle.seek(toOffset: cursor.offset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty,
              let lastNewlineIndex = data.lastIndex(of: JSONLines.newlineByte) else {
            return
        }

        let consumedCount = data.distance(from: data.startIndex, to: lastNewlineIndex) + 1
        cursor.offset += UInt64(consumedCount)
        cursor.fileIdentifier = identifier

        var completeData = Data(data[data.startIndex ... lastNewlineIndex])
        if cursor.discardsLeadingPartialLine {
            completeData = JSONLines.droppingLeadingPartialLine(completeData)
            cursor.discardsLeadingPartialLine = false
        }

        guard !completeData.isEmpty else {
            return
        }

        for envelope in JSONLines.decode(CodexRolloutLineEnvelope.self, from: completeData) {
            guard let event = envelope.lifecycleEvent else {
                continue
            }
            var lifecycle = cursor.lifecycleByTurnId[event.turnId] ?? SessionTurnLifecycle()
            lifecycle.apply(event.change)
            cursor.lifecycleByTurnId[event.turnId] = lifecycle
        }
    }

    private static let bootstrapByteLimit: UInt64 = 512 * 1024
    private static let effortBackfillByteLimit: UInt64 = 8 * 1024 * 1024
    private static let effortBackfillMinimumTaskAge: TimeInterval = 2
    private static let effortBackfillRetryInterval: TimeInterval = 10
    private static let fileResolutionRetryInterval: TimeInterval = 10
}

private nonisolated struct SessionFileCursor {
    let url: URL
    var fileIdentifier: UInt64?
    var offset: UInt64
    var discardsLeadingPartialLine: Bool
    var lifecycleByTurnId: [String: SessionTurnLifecycle]
    let hasUnscannedHistoricalPrefix: Bool
    var completedEffortBackfillTurnIds: Set<String>
    var lastEffortBackfillAttemptByTurnId: [String: Date]
}

private nonisolated enum EffortBackfillResult {
    case found(String)
    case notFound
    case unavailable
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
                    effort: effort
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
    case started(at: Date)
    case context(approvalReviewer: CodexApprovalReviewer?, effort: String?)
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}

private nonisolated struct SessionTurnLifecycle {
    var startedAt: Date?
    var approvalReviewer: CodexApprovalReviewer?
    var effort: String?
    var terminal: CodexSessionTaskTerminalState?

    mutating func apply(_ change: SessionLifecycleChange) {
        switch change {
        case let .started(at):
            if let currentStartedAt = startedAt {
                startedAt = min(currentStartedAt, at)
            } else {
                startedAt = at
            }
        case let .context(reviewer, reasoningEffort):
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
    let terminal: CodexSessionTaskTerminalState?
}

nonisolated enum CodexSessionTaskTerminalState {
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}
