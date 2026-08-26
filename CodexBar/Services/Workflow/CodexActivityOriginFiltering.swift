import Foundation
import os

extension CodexActivityMonitor {
    /// Auto-review 事件只影响实时活动链路, 原始事件仍由历史聚合完整消费
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

            let now = Date()
            let observedAt = min(event.timestamp, now)
            let wasAlreadyIgnored = ignoredAutoReviewTaskAt[exactKey] != nil
            ignoredAutoReviewTaskAt[exactKey] = max(
                ignoredAutoReviewTaskAt[exactKey] ?? .distantPast,
                observedAt
            )
            discardAutoReviewActivity(for: exactKey)
            if !wasAlreadyIgnored, source == .live {
                AppLog.activity.notice("Auto-review 任务已过滤")
            }
            return true
        case .main, .auxiliary:
            if let exactKey {
                ignoredAutoReviewTaskAt.removeValue(forKey: exactKey)
            }
            return false
        case .unknown:
            guard let exactKey,
                  let ignoredAt = ignoredAutoReviewTaskAt[exactKey] else {
                return false
            }
            let cutoff = Date().addingTimeInterval(-Self.activityRetention)
            guard ignoredAt > cutoff else {
                ignoredAutoReviewTaskAt.removeValue(forKey: exactKey)
                return false
            }
            return true
        }
    }

    private static func exactTurnKey(for event: WorkflowHookEvent) -> CodexActivityTaskKey? {
        guard let sessionId = event.sessionId,
              let turnId = event.turnId else {
            return nil
        }
        return .turn(session: sessionId, turn: turnId)
    }

    private func discardAutoReviewActivity(for key: CodexActivityTaskKey) {
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

        Self.removeTerminalMemory(for: key, storedIn: &recentlyCompletedTaskAt)
        Self.removeTerminalMemory(for: key, storedIn: &recentlyTerminatedTaskAt)
    }

    private static func removeTerminalMemory(
        for key: CodexActivityTaskKey,
        storedIn dates: inout [CodexActivityTaskKey: Date]
    ) {
        guard let removedAt = dates.removeValue(forKey: key),
              let sessionId = key.sessionId else {
            return
        }

        let sessionKey = CodexActivityTaskKey.session(sessionId)
        guard dates[sessionKey] == removedAt else {
            return
        }
        let remainingSessionDate = dates.compactMap { candidateKey, date -> Date? in
            guard candidateKey != sessionKey,
                  candidateKey.sessionId == sessionId else {
                return nil
            }
            return date
        }.max()
        if let remainingSessionDate {
            dates[sessionKey] = remainingSessionDate
        } else {
            dates.removeValue(forKey: sessionKey)
        }
    }
}
