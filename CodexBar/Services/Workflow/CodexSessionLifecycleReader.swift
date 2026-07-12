import Foundation

/// 活跃 turn 的最小定位信息，只在进程内用于关联 Codex session 生命周期事件。
nonisolated struct CodexActivityTurnReference: Hashable, Sendable {
    let sessionId: String
    let turnId: String
    let startedAt: Date
}

/// 增量读取活跃 Codex session 的 rollout JSONL，只提取 turn 生命周期字段。
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

    /// 返回 rollout 中已知的起点和终态，不解码会话或工具内容。
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
        for (sessionId, sessionReferences) in referencesBySession {
            guard let reference = sessionReferences.max(by: { $0.startedAt < $1.startedAt }),
                  var cursor = cursor(for: reference) else {
                continue
            }

            scanNewLifecycleEvents(into: &cursor)
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
                        terminal: lifecycle.terminal
                    )
                )
            }
        }
        return states
    }

    /// 唤醒后允许仍未定位到文件的活跃 session 重新执行一次递归兜底。
    func resetResolutionFallbacks() {
        lastResolutionAttemptBySession.removeAll()
        recursiveFallbackSessionIds.removeAll()
    }

    private func cursor(for reference: CodexActivityTurnReference) -> SessionFileCursor? {
        if let cursor = cursorsBySession[reference.sessionId],
           fileManager.fileExists(atPath: cursor.url.path) {
            return cursor
        }
        if cursorsBySession.removeValue(forKey: reference.sessionId) != nil {
            // 缓存文件可能被移动到 archived_sessions，允许重新完整定位一次。
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

        // resume 可能继续很早以前创建的 session；每次活跃生命周期最多递归一次。
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
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
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
            lifecycleByTurnId: [:]
        )
    }

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
              let lastNewlineIndex = data.lastIndex(of: Self.newlineByte) else {
            return
        }

        let consumedCount = data.distance(from: data.startIndex, to: lastNewlineIndex) + 1
        cursor.offset += UInt64(consumedCount)
        cursor.fileIdentifier = identifier

        var firstCompleteIndex = data.startIndex
        if cursor.discardsLeadingPartialLine {
            firstCompleteIndex = data.index(after: data.firstIndex(of: Self.newlineByte) ?? lastNewlineIndex)
            cursor.discardsLeadingPartialLine = false
        }

        guard firstCompleteIndex <= lastNewlineIndex else {
            return
        }

        let completeData = Data(data[firstCompleteIndex ... lastNewlineIndex])
        for envelope in JSONLines.decode(CodexSessionLifecycleEnvelope.self, from: completeData) {
            guard let event = envelope.lifecycleEvent else {
                continue
            }
            var lifecycle = cursor.lifecycleByTurnId[event.turnId] ?? SessionTurnLifecycle()
            lifecycle.apply(event.change)
            cursor.lifecycleByTurnId[event.turnId] = lifecycle
        }
    }

    private static let bootstrapByteLimit: UInt64 = 512 * 1024
    private static let fileResolutionRetryInterval: TimeInterval = 10
    private static let newlineByte: UInt8 = 0x0A
}

private nonisolated struct SessionFileCursor {
    let url: URL
    var fileIdentifier: UInt64?
    var offset: UInt64
    var discardsLeadingPartialLine: Bool
    var lifecycleByTurnId: [String: SessionTurnLifecycle]
}

private nonisolated struct CodexSessionLifecycleEnvelope: Decodable {
    let timestamp: String?
    let type: String
    let payload: CodexSessionLifecyclePayload?

    var lifecycleEvent: SessionLifecycleEvent? {
        guard type == "event_msg",
              let payload,
              let turnId = payload.turnId,
              !turnId.isEmpty else {
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

private nonisolated struct CodexSessionLifecyclePayload: Decodable {
    let type: String?
    let turnId: String?
    let startedAt: Double?
    let completedAt: Double?
    let durationMilliseconds: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case turnId = "turn_id"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMilliseconds = "duration_ms"
    }
}

private nonisolated struct SessionLifecycleEvent {
    let turnId: String
    let change: SessionLifecycleChange
}

private nonisolated enum SessionLifecycleChange {
    case started(at: Date)
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}

private nonisolated struct SessionTurnLifecycle {
    var startedAt: Date?
    var terminal: CodexSessionTaskTerminalState?

    mutating func apply(_ change: SessionLifecycleChange) {
        switch change {
        case let .started(at):
            if let currentStartedAt = startedAt {
                startedAt = min(currentStartedAt, at)
            } else {
                startedAt = at
            }
        case let .completed(at, duration):
            terminal = .completed(at: at, duration: duration)
        case let .aborted(at):
            terminal = .aborted(at: at)
        }
    }
}

nonisolated struct CodexSessionTaskLifecycleState: Sendable {
    let sessionId: String
    let turnId: String
    let startedAt: Date?
    let terminal: CodexSessionTaskTerminalState?
}

nonisolated enum CodexSessionTaskTerminalState: Sendable {
    case completed(at: Date, duration: TimeInterval?)
    case aborted(at: Date?)
}
