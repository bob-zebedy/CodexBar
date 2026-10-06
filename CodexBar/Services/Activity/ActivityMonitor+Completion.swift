import Combine
import Foundation
import os

extension ActivityMonitor {
    /// Interrupt 只结束匹配的 turn, 不清空同 session 的新任务
    func interruptTask(from event: ActivityRecord, source: ActivityEventSource) {
        let eventKey = ActivityTaskKey(event: event)
        if recentEndedDate(for: eventKey) != nil {
            discardStaleTerminalTask(for: eventKey)
            return
        }

        let match = matchingTerminalTask(for: event, allowsAnonymousFallback: event.sessionID == nil)
        let key: ActivityTaskKey
        let task: ActivityTask?
        switch match {
        case let .active(matchedKey):
            key = matchedKey
            task = tasks[key]
        case let .pending(matchedKey):
            key = matchedKey
            task = pendingTerminalTasks[key]?.task
        case .ambiguous:
            AppLog.activity.error("任务中断未关联: reason=ambiguousInterrupt")
            return
        case .none:
            key = eventKey
            task = nil
        }
        guard task.map({ event.timestamp >= $0.lastMainEventAt }) ?? true else {
            return
        }
        if recentEndedDate(for: key) != nil {
            discardStaleTerminalTask(for: key)
            return
        }

        tasks.removeValue(forKey: key)
        pendingTerminalTasks.removeValue(forKey: key)
        clearProtection(for: key, taskID: task?.displayID, reason: .terminal)
        let termination = storeTermination(
            for: key,
            projectName: event.projectDisplayName ?? task?.projectName,
            modelName: event.model ?? task?.modelName,
            effort: event.effort ?? task?.effort,
            terminatedAt: event.timestamp,
            duration: event.source == nil || event.source?.turnCompletedAt != nil ? task?.preciseDuration(until: event.timestamp) : nil,
            task: task
        )
        recordTerminalPresentationEvent(.terminated(termination))
        recordEndedTask(key, at: event.timestamp)
        if let resolved = task?.resolvedTurnKey {
            recordEndedTask(resolved, at: event.timestamp)
        }
        recordEndedTask(eventKey, at: event.timestamp)
        if source == .live {
            AppLog.activity.notice("任务已终止: source=turnInterrupted")
        }
    }

    // MARK: - 终态判定与记录

    /// PermissionRequest 表示进入审批流程; 只有 服务端明确把审批路由给 user 时才是 UI 等待
    func resolvePendingApprovalIfPossible(
        for task: inout ActivityTask,
        into transitions: inout [ActivityTransition]
    ) -> Bool {
        let wasWaiting = task.state == .waitingApproval
        guard task.resolvePendingApprovals() else { return false }
        if !wasWaiting, task.state == .waitingApproval, canPublishActivityTransitions,
           !task.key.isAnonymous, let sessionTransitionNotBefore,
           task.stateChangedAt >= sessionTransitionNotBefore,
           Date().timeIntervalSince(task.stateChangedAt) <= 10 {
            transitions.append(.waitingApproval(task.snapshot))
        }
        return true
    }

    /// app-server 终态归类的唯一入口; 活动任务和等待终态确认任务只有 abort 兜底时间不同
    /// 终止记录供任务中心和流光展示, 不发布通知 transition
    func resolveTerminal(
        _ terminal: SessionTerminalState,
        task: ActivityTask,
        key: ActivityTaskKey,
        abortFallback: Date,
        publishesEvents: Bool = true,
        into transitions: inout [ActivityTransition]
    ) {
        clearProtection(
            for: key,
            taskID: task.displayID,
            reason: .terminal
        )
        guard recentEndedDate(for: key) == nil else {
            return
        }
        switch terminal {
        case let .aborted(reportedAt):
            let terminatedAt = max(reportedAt ?? abortFallback, task.lastActivityAt)
            let termination = storeTermination(task, at: terminatedAt, includesDuration: reportedAt != nil)
            if publishesEvents {
                recordTerminalPresentationEvent(.terminated(termination))
            }
            recordEndedTask(key, at: terminatedAt)
            if let resolved = task.resolvedTurnKey {
                recordEndedTask(resolved, at: terminatedAt)
            }
        case let .completed(completedAt, duration):
            let completion = storeResolvedCompletion(
                task,
                key: key,
                completedAt: completedAt,
                observedAt: abortFallback,
                reportedDuration: duration
            )
            guard publishesEvents else { return }
            recordTerminalPresentationEvent(.completed(completion))
            if canPublishActivityTransitions, !completion.isAnonymous,
               Date().timeIntervalSince(completion.completedAt) <= 10,
               let sessionTransitionNotBefore,
               completion.completedAt >= sessionTransitionNotBefore {
                transitions.append(.completed(completion))
            }
        }
    }

    static func backfilledStartedAt(
        for task: ActivityTask,
        state: SessionLifecycleState
    ) -> Date? {
        guard task.startedAt == nil,
              let startedAt = state.startedAt,
              startedAt <= task.lastActivityAt.addingTimeInterval(1) else {
            return nil
        }
        return startedAt
    }

    static func mergeLifecycleBackfill(
        from state: SessionLifecycleState,
        into task: inout ActivityTask
    ) -> Bool {
        var didChange = false
        if let startedAt = backfilledStartedAt(for: task, state: state) {
            task.startedAt = startedAt
            didChange = true
        }
        if task.mergeEffort(state.effort) {
            didChange = true
        }
        return didChange
    }

    private func storeResolvedCompletion(
        _ task: ActivityTask,
        key: ActivityTaskKey,
        completedAt: Date?,
        observedAt: Date,
        reportedDuration: TimeInterval?
    ) -> ActivityCompletion {
        // 轮次时间戳可能是整秒, 避免将完成时间记在同秒的最后活动之前
        let recordedCompletedAt = max(completedAt ?? observedAt, task.lastActivityAt)
        let completion = ActivityCompletion(
            id: UUID(),
            isAnonymous: key.isAnonymous,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            completedAt: recordedCompletedAt,
            duration: reportedDuration ?? completedAt.flatMap { task.preciseDuration(until: $0) }
        )
        completions.append(completion)
        terminalTaskKeyByID[completion.id] = key
        registerTerminalTokenUsage(id: completion.id, key: key, task: task, endedAt: recordedCompletedAt)
        recordEndedTask(key, at: recordedCompletedAt)
        if let resolved = task.resolvedTurnKey {
            recordEndedTask(resolved, at: recordedCompletedAt)
        }
        return completion
    }

    private func storeTermination(
        _ task: ActivityTask,
        at terminatedAt: Date,
        includesDuration: Bool
    ) -> ActivityTermination {
        storeTermination(
            for: task.key,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            terminatedAt: terminatedAt,
            duration: includesDuration ? task.preciseDuration(until: terminatedAt) : nil,
            task: task
        )
    }

    private func storeTermination(
        for key: ActivityTaskKey,
        projectName: String?,
        modelName: String?,
        effort: String?,
        terminatedAt: Date,
        duration: TimeInterval?,
        task: ActivityTask? = nil
    ) -> ActivityTermination {
        let termination = ActivityTermination(
            id: UUID(),
            isAnonymous: key.isAnonymous,
            projectName: projectName,
            modelName: modelName,
            effort: effort,
            terminatedAt: terminatedAt,
            duration: duration
        )
        terminations.append(termination)
        terminalTaskKeyByID[termination.id] = key
        registerTerminalTokenUsage(id: termination.id, key: key, task: task, endedAt: terminatedAt)
        return termination
    }

    func recordTerminalPresentationEvent(_ event: ActivityTerminalEvent) {
        guard canPublishActivityTransitions, Date().timeIntervalSince(event.endedAt) <= 10,
              event.endedAt >= terminalPresentationNotBefore else {
            return
        }
        pendingTerminalPresentationEvents.append(event)
    }

    func resetTerminalPresentationEvents() {
        pendingTerminalPresentationEvents.removeAll()
        // 延迟确认仍使用原始结束时间, 恢复前的旧终态不能在恢复后补播
        terminalPresentationNotBefore = Date()
    }

    func recentEndedDate(
        for key: ActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        guard let date = recentlyEndedTaskAt[key] else {
            return nil
        }
        if key.isSessionOnly, let startedAt = tasks[key]?.startedAt, startedAt > date {
            return nil
        }
        guard date > now.addingTimeInterval(-Self.endedTaskRetention) else {
            recentlyEndedTaskAt.removeValue(forKey: key)
            return nil
        }
        return date
    }

    func recordEndedTask(_ key: ActivityTaskKey, at date: Date) {
        recentlyEndedTaskAt[key] = max(recentlyEndedTaskAt[key] ?? .distantPast, date)
        if let sessionID = key.sessionID {
            let sessionKey = ActivityTaskKey.session(sessionID)
            recentlyEndedTaskAt[sessionKey] = max(recentlyEndedTaskAt[sessionKey] ?? .distantPast, date)
        }
    }

    func clearCollectedActivityState() {
        resetTerminalPresentationEvents()
        cancelAllProtectionAttempts()
        let taskIDs = Set(tasks.values.map(\.displayID))
            .union(pendingTerminalTasks.values.map(\.task.displayID))
        for taskID in taskIDs {
            invalidateProtectionNotification(for: taskID)
        }
        tasks.removeAll()
        pendingTerminalTasks.removeAll()
        completions.removeAll()
        terminations.removeAll()
        recentlyEndedTaskAt.removeAll()
        terminalTaskKeyByID.removeAll()
        terminalTokenUsageRequests.removeAll()
        activityTaskOrigins.removeAll()
        pendingSubagentEvents.removeAll()
        subagentTurnLinks.removeAll()
    }

    func finalizeExpiredPendingTerminalTasks(now: Date) {
        let expiredKeys = pendingTerminalTasks.compactMap { key, pending in
            pending.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            guard let pending = pendingTerminalTasks.removeValue(forKey: key) else {
                continue
            }
            clearProtection(
                for: key,
                taskID: pending.task.displayID,
                reason: .terminal
            )
        }
    }

    func publishWaitingApprovalTransitions(_ taskKeys: [ActivityTaskKey]) {
        for transition in waitingApprovalTransitions(taskKeys) {
            transitionSubject.send(transition)
        }
    }

    func waitingApprovalTransitions(_ taskKeys: [ActivityTaskKey]) -> [ActivityTransition] {
        guard canPublishActivityTransitions else { return [] }
        var transitions: [ActivityTransition] = []
        var lastWaitingIndexByKey: [ActivityTaskKey: Int] = [:]
        for (index, key) in taskKeys.enumerated() {
            lastWaitingIndexByKey[key] = index
        }

        for (index, key) in taskKeys.enumerated() {
            guard !key.isAnonymous,
                  lastWaitingIndexByKey[key] == index,
                  let task = tasks[key],
                  task.state == .waitingApproval,
                  let sessionTransitionNotBefore,
                  task.stateChangedAt >= sessionTransitionNotBefore,
                  Date().timeIntervalSince(task.stateChangedAt) <= 10 else {
                continue
            }
            transitions.append(.waitingApproval(task.snapshot))
        }
        return transitions
    }
}
