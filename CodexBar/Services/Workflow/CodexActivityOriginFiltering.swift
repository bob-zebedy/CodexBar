import Foundation
import os

extension CodexActivityMonitor {
    /// 来源过滤只影响实时活动链路, 原始事件仍由历史聚合完整消费
    func shouldIgnoreForActivity(
        _ event: WorkflowHookEvent,
        source: CodexActivityEventSource
    ) -> Bool {
        let exactKey = Self.exactTurnKey(for: event)
        switch event.origin {
        case .autoReview:
            guard let exactKey else {
                return true
            }

            let wasAlreadyIgnored = activityTaskOrigins[exactKey]?.origin == .autoReview
            rememberActivityOrigin(event.origin, for: exactKey, at: event.timestamp)
            discardExcludedActivity(for: exactKey)
            if !wasAlreadyIgnored, source == .live {
                AppLog.activity.notice("Auto-review 任务已过滤")
            }
            return true
        case .main, .auxiliary:
            if let exactKey {
                rememberActivityOrigin(event.origin, for: exactKey, at: event.timestamp)
            }
            return false
        case .unknown:
            guard let exactKey,
                  let knownOrigin = activityTaskOrigins[exactKey] else {
                return true
            }
            guard knownOrigin.observedAt > Date().addingTimeInterval(-Self.activityRetention) else {
                activityTaskOrigins.removeValue(forKey: exactKey)
                return true
            }
            guard knownOrigin.origin == .main || knownOrigin.origin == .auxiliary else {
                return true
            }
            // 一次读取失败不推翻已确认来源, 迟到事件仍交给状态机检查时间顺序
            rememberActivityOrigin(knownOrigin.origin, for: exactKey, at: event.timestamp)
            return false
        }
    }

    private func rememberActivityOrigin(
        _ origin: WorkflowEventOrigin,
        for key: CodexActivityTaskKey,
        at timestamp: Date
    ) {
        activityTaskOrigins[key] = (
            origin: origin,
            observedAt: max(activityTaskOrigins[key]?.observedAt ?? .distantPast, min(timestamp, Date()))
        )
    }

    private static func exactTurnKey(for event: WorkflowHookEvent) -> CodexActivityTaskKey? {
        guard let sessionId = event.sessionId,
              let turnId = event.turnId else {
            return nil
        }
        return .turn(session: sessionId, turn: turnId)
    }

    private func discardExcludedActivity(for key: CodexActivityTaskKey) {
        var taskIDs = Set<UUID>()
        if let task = tasks.removeValue(forKey: key) {
            taskIDs.insert(task.displayID)
        }
        if let pending = pendingTerminalTasks.removeValue(forKey: key) {
            taskIDs.insert(pending.task.displayID)
        }

        if taskIDs.isEmpty {
            clearActivityProtection(for: key, taskID: nil, reason: .terminal)
        } else {
            for taskID in taskIDs {
                clearActivityProtection(for: key, taskID: taskID, reason: .terminal)
            }
        }

        completions.removeAll { terminalTaskKeyByID[$0.id] == key }
        terminations.removeAll { terminalTaskKeyByID[$0.id] == key }
        terminalTaskKeyByID = terminalTaskKeyByID.filter { $0.value != key }

        removeTerminalMemory(for: key)
    }

    private func removeTerminalMemory(for key: CodexActivityTaskKey) {
        guard let removedAt = recentlyEndedTaskAt.removeValue(forKey: key),
              let sessionId = key.sessionId else {
            return
        }

        let sessionKey = CodexActivityTaskKey.session(sessionId)
        guard recentlyEndedTaskAt[sessionKey] == removedAt else {
            return
        }
        let remainingSessionDate = recentlyEndedTaskAt.compactMap { candidateKey, date -> Date? in
            guard candidateKey != sessionKey,
                  candidateKey.sessionId == sessionId else {
                return nil
            }
            return date
        }.max()
        if let remainingSessionDate {
            recentlyEndedTaskAt[sessionKey] = remainingSessionDate
        } else {
            recentlyEndedTaskAt.removeValue(forKey: sessionKey)
        }
    }
}
