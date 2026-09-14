import Combine
import Foundation
import os

extension CodexActivityMonitor {
    /// Interrupt 只结束匹配的 turn, 不清空同 session 的新任务
    func interruptTask(from event: WorkflowHookEvent, source: CodexActivityEventSource) {
        let eventKey = CodexActivityTaskKey(event: event)
        if recentEndedDate(for: eventKey) != nil {
            discardStaleTerminalTask(for: eventKey)
            return
        }

        let match = matchingTerminalTask(for: event, allowsAnonymousFallback: event.sessionId == nil)
        let key: CodexActivityTaskKey
        let task: CodexActivityTask?
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
        guard task.map({ event.timestamp >= $0.lastActivityAt }) ?? true else {
            return
        }
        if recentEndedDate(for: key) != nil {
            discardStaleTerminalTask(for: key)
            return
        }

        tasks.removeValue(forKey: key)
        pendingTerminalTasks.removeValue(forKey: key)
        clearActivityProtection(for: key, taskID: task?.displayID, reason: .terminal)
        storeTermination(
            for: key,
            projectName: event.projectDisplayName ?? task?.projectName,
            modelName: event.modelName ?? task?.modelName,
            effort: event.effort ?? task?.effort,
            terminatedAt: event.timestamp,
            duration: task?.preciseDuration(until: event.timestamp)
        )
        recordEndedTask(key, at: event.timestamp)
        recordEndedTask(eventKey, at: event.timestamp)
        if source == .live {
            AppLog.activity.notice("任务已终止: source=interruptHook")
        }
    }

    // MARK: - 终态判定与记录

    /// PermissionRequest 表示进入审批流程; 只有 rollout 明确把审批路由给 user 时才是 UI 等待
    func resolvePendingApprovalIfPossible(
        for task: inout CodexActivityTask,
        into transitions: inout [CodexActivityTransition]
    ) -> Bool {
        guard let requestedAt = task.pendingApprovalRequestedAt,
              let approvalReviewer = task.approvalReviewer else {
            return false
        }

        switch approvalReviewer {
        case .user:
            let wasWaiting = task.state == .waitingApproval
            task.confirmPendingApproval()
            if !wasWaiting,
               !task.key.isAnonymous,
               let sessionTransitionNotBefore,
               requestedAt >= sessionTransitionNotBefore {
                transitions.append(.waitingApproval(task.snapshot))
            }
        case .autoReview, .guardianSubagent:
            task.pendingApprovalRequestedAt = nil
        }
        return true
    }

    /// rollout 终态归类的唯一入口; 活动任务和等待终态确认任务只有 abort 兜底时间不同
    /// 终止记录供任务中心和流光展示, 不发布通知 transition
    func resolveTerminal(
        _ terminal: CodexSessionTaskTerminalState,
        task: CodexActivityTask,
        key: CodexActivityTaskKey,
        abortFallback: Date,
        into transitions: inout [CodexActivityTransition]
    ) {
        clearActivityProtection(
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
            storeTermination(task, at: terminatedAt, includesDuration: reportedAt != nil)
            recordEndedTask(key, at: terminatedAt)
        case let .completed(completedAt, duration):
            let completion = storeResolvedCompletion(
                task,
                key: key,
                completedAt: completedAt,
                reportedDuration: duration
            )
            if !completion.isAnonymous,
               let sessionTransitionNotBefore,
               completion.completedAt >= sessionTransitionNotBefore {
                transitions.append(.completed(completion))
            }
        }
    }

    static func backfilledStartedAt(
        for task: CodexActivityTask,
        state: CodexSessionTaskLifecycleState
    ) -> Date? {
        guard task.startedAt == nil,
              let startedAt = state.startedAt,
              startedAt <= task.lastActivityAt.addingTimeInterval(1) else {
            return nil
        }
        return startedAt
    }

    static func mergeLifecycleBackfill(
        from state: CodexSessionTaskLifecycleState,
        into task: inout CodexActivityTask
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
        _ task: CodexActivityTask,
        key: CodexActivityTaskKey,
        completedAt: Date,
        reportedDuration: TimeInterval?
    ) -> CodexActivityCompletion {
        // rollout 时间戳是整秒, 避免因为同一秒内的 Hook 毫秒时间戳而把完成时间记在最后活动之前
        let recordedCompletedAt = max(completedAt, task.lastActivityAt)
        let completion = CodexActivityCompletion(
            id: UUID(),
            isAnonymous: key.isAnonymous,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            completedAt: recordedCompletedAt,
            duration: reportedDuration ?? task.preciseDuration(until: recordedCompletedAt)
        )
        completions.append(completion)
        terminalTaskKeyByID[completion.id] = key
        recordTerminalPresentationEvent(.completed(completion))
        recordEndedTask(key, at: recordedCompletedAt)
        return completion
    }

    func storeTermination(
        _ task: CodexActivityTask,
        at terminatedAt: Date,
        includesDuration: Bool
    ) {
        storeTermination(
            for: task.key,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            terminatedAt: terminatedAt,
            duration: includesDuration ? task.preciseDuration(until: terminatedAt) : nil
        )
    }

    private func storeTermination(
        for key: CodexActivityTaskKey,
        projectName: String?,
        modelName: String?,
        effort: String?,
        terminatedAt: Date,
        duration: TimeInterval?
    ) {
        let termination = CodexActivityTermination(
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
        recordTerminalPresentationEvent(.terminated(termination))
    }

    func recordTerminalPresentationEvent(_ event: CodexActivityTerminalEvent) {
        guard !isBootstrapping, !isActivityProtectionRecoveryInProgress, isActivitySourceHealthy,
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
        for key: CodexActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        guard let date = recentlyEndedTaskAt[key] else {
            return nil
        }
        guard date > now.addingTimeInterval(-Self.endedTaskRetention) else {
            recentlyEndedTaskAt.removeValue(forKey: key)
            return nil
        }
        return date
    }

    func recordEndedTask(_ key: CodexActivityTaskKey, at date: Date) {
        recentlyEndedTaskAt[key] = max(recentlyEndedTaskAt[key] ?? .distantPast, date)
        if let sessionId = key.sessionId {
            let sessionKey = CodexActivityTaskKey.session(sessionId)
            recentlyEndedTaskAt[sessionKey] = max(recentlyEndedTaskAt[sessionKey] ?? .distantPast, date)
        }
    }

    func clearCollectedActivityState() {
        resetTerminalPresentationEvents()
        cancelAllActivityProtectionAttempts()
        let taskIDs = Set(tasks.values.map(\.displayID))
            .union(pendingTerminalTasks.values.map(\.task.displayID))
        for taskID in taskIDs {
            invalidateActivityProtectionNotification(for: taskID)
        }
        tasks.removeAll()
        pendingTerminalTasks.removeAll()
        completions.removeAll()
        terminations.removeAll()
        recentlyEndedTaskAt.removeAll()
        terminalTaskKeyByID.removeAll()
        activityTaskOrigins.removeAll()
    }

    func finalizeExpiredPendingTerminalTasks(now: Date) {
        let expiredKeys = pendingTerminalTasks.compactMap { key, pending in
            pending.deadline <= now ? key : nil
        }
        for key in expiredKeys {
            guard let pending = pendingTerminalTasks.removeValue(forKey: key) else {
                continue
            }
            let terminatedAt = max(pending.supersededAt, pending.task.lastActivityAt)
            if pending.task.state != .suppressed {
                storeTermination(pending.task, at: terminatedAt, includesDuration: true)
            }
            recordEndedTask(key, at: terminatedAt)
            clearActivityProtection(
                for: key,
                taskID: pending.task.displayID,
                reason: .terminal
            )
        }
    }

    func publishWaitingApprovalTransitions(_ taskKeys: [CodexActivityTaskKey]) {
        var lastWaitingIndexByKey: [CodexActivityTaskKey: Int] = [:]
        for (index, key) in taskKeys.enumerated() {
            lastWaitingIndexByKey[key] = index
        }

        for (index, key) in taskKeys.enumerated() {
            guard !key.isAnonymous,
                  lastWaitingIndexByKey[key] == index,
                  let task = tasks[key],
                  task.state == .waitingApproval else {
                continue
            }
            transitionSubject.send(.waitingApproval(task.snapshot))
        }
    }
}
