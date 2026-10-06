import Foundation
import os

extension ActivityMonitor {
    /// 仅为实时链路归一化事件副本, 来源过滤和执行身份使用同一判断
    func activityEvent(from event: ActivityRecord, source: ActivityEventSource) -> ActivityRecord? {
        guard let origin = activityOrigin(for: event, source: source) else { return nil }
        guard origin != event.origin else { return event }
        var resolved = ActivityRecord(
            timestamp: event.timestamp, name: event.name, origin: origin,
            cwd: event.cwd, tool: event.tool, model: event.model,
            effort: event.effort, approvalReviewer: event.approvalReviewer,
            sessionID: event.sessionID, turnID: event.turnID, agentID: event.agentID, id: event.id
        )
        resolved.source = event.source
        return resolved
    }

    private func activityOrigin(
        for event: ActivityRecord,
        source: ActivityEventSource
    ) -> ActivityOrigin? {
        let exactKey = Self.exactTurnKey(for: event)
        switch event.origin {
        case .autoReview:
            guard let exactKey else {
                return nil
            }

            let wasAlreadyIgnored = activityTaskOrigins[exactKey]?.origin == .autoReview
            rememberActivityOrigin(event.origin, for: exactKey, at: event.timestamp)
            discardExcludedActivity(for: exactKey)
            if !wasAlreadyIgnored, source == .live {
                AppLog.activity.notice("Auto-review 任务已过滤")
            }
            return nil
        case .main, .auxiliary:
            if let exactKey {
                rememberActivityOrigin(event.origin, for: exactKey, at: event.timestamp)
            }
            return event.origin
        case .unknown:
            guard let exactKey,
                  let knownOrigin = activityTaskOrigins[exactKey] else {
                return nil
            }
            guard knownOrigin.observedAt > Date().addingTimeInterval(-Self.activityRetention) else {
                activityTaskOrigins.removeValue(forKey: exactKey)
                return nil
            }
            guard knownOrigin.origin == .main || knownOrigin.origin == .auxiliary else {
                return nil
            }
            // 一次读取失败不推翻已确认来源, 迟到事件仍交给状态机检查时间顺序
            rememberActivityOrigin(knownOrigin.origin, for: exactKey, at: event.timestamp)
            return knownOrigin.origin
        }
    }

    private func rememberActivityOrigin(
        _ origin: ActivityOrigin,
        for key: ActivityTaskKey,
        at timestamp: Date
    ) {
        activityTaskOrigins[key] = (
            origin: origin,
            observedAt: max(activityTaskOrigins[key]?.observedAt ?? .distantPast, min(timestamp, Date()))
        )
    }

    private static func exactTurnKey(for event: ActivityRecord) -> ActivityTaskKey? {
        guard let sessionID = event.sessionID,
              let turnID = event.turnID else {
            return nil
        }
        return .turn(session: sessionID, turn: turnID)
    }

    private func discardExcludedActivity(for key: ActivityTaskKey) {
        var taskIDs = Set<UUID>()
        if let task = tasks.removeValue(forKey: key) {
            taskIDs.insert(task.displayID)
        }
        if let pending = pendingTerminalTasks.removeValue(forKey: key) {
            taskIDs.insert(pending.task.displayID)
        }

        if taskIDs.isEmpty {
            clearProtection(for: key, taskID: nil, reason: .terminal)
        } else {
            for taskID in taskIDs {
                clearProtection(for: key, taskID: taskID, reason: .terminal)
            }
        }

        completions.removeAll { terminalTaskKeyByID[$0.id] == key }
        terminations.removeAll { terminalTaskKeyByID[$0.id] == key }
        terminalTaskKeyByID = terminalTaskKeyByID.filter { $0.value != key }

        removeTerminalMemory(for: key)
    }

    private func removeTerminalMemory(for key: ActivityTaskKey) {
        guard let removedAt = recentlyEndedTaskAt.removeValue(forKey: key),
              let sessionID = key.sessionID else {
            return
        }

        let sessionKey = ActivityTaskKey.session(sessionID)
        guard recentlyEndedTaskAt[sessionKey] == removedAt else {
            return
        }
        let remainingSessionDate = recentlyEndedTaskAt.compactMap { candidateKey, date -> Date? in
            guard candidateKey != sessionKey,
                  candidateKey.sessionID == sessionID else {
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
