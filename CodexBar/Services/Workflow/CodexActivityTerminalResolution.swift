import Combine
import Foundation

extension CodexActivityMonitor {
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
    /// 终止记录只供任务中心展示, 不发布 transition, 也不产生绿色状态或通知
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
        switch terminal {
        case let .aborted(reportedAt):
            let terminatedAt = max(reportedAt ?? abortFallback, task.lastActivityAt)
            storeTermination(task, at: terminatedAt, includesDuration: reportedAt != nil)
            recordTerminatedTask(key, at: terminatedAt)
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

    func storeResolvedCompletion(
        _ task: CodexActivityTask,
        key: CodexActivityTaskKey,
        completedAt: Date,
        reportedDuration: TimeInterval?,
        projectName: String? = nil,
        modelName: String? = nil,
        effort: String? = nil
    ) -> CodexActivityCompletion {
        // rollout 时间戳是整秒, 避免因为同一秒内的 Hook 毫秒时间戳而把完成时间记在最后活动之前
        let recordedCompletedAt = max(completedAt, task.lastActivityAt)
        let completion = storeCompletion(
            for: key,
            projectName: projectName ?? task.projectName,
            modelName: modelName ?? task.modelName,
            effort: effort ?? task.effort,
            completedAt: recordedCompletedAt,
            duration: reportedDuration ?? task.preciseDuration(until: recordedCompletedAt)
        )
        recordCompletedTask(key, at: recordedCompletedAt)
        return completion
    }

    func storeCompletion(
        for key: CodexActivityTaskKey,
        projectName: String?,
        modelName: String?,
        effort: String?,
        completedAt: Date,
        duration: TimeInterval?
    ) -> CodexActivityCompletion {
        let completion = CodexActivityCompletion(
            id: UUID(),
            isAnonymous: key.isAnonymous,
            projectName: projectName,
            modelName: modelName,
            effort: effort,
            completedAt: completedAt,
            duration: duration
        )
        completions.append(completion)
        terminalTaskKeyByID[completion.id] = key
        return completion
    }

    func storeTermination(
        _ task: CodexActivityTask,
        at terminatedAt: Date,
        includesDuration: Bool
    ) {
        let termination = CodexActivityTermination(
            id: UUID(),
            isAnonymous: task.key.isAnonymous,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            terminatedAt: terminatedAt,
            duration: includesDuration ? task.preciseDuration(until: terminatedAt) : nil
        )
        terminations.append(termination)
        terminalTaskKeyByID[termination.id] = task.key
    }

    func recentCompletionDate(
        for key: CodexActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        Self.recentTerminalDate(
            for: key,
            storedIn: &recentlyCompletedTaskAt,
            now: now
        )
    }

    func recentTerminationDate(
        for key: CodexActivityTaskKey,
        now: Date = Date()
    ) -> Date? {
        Self.recentTerminalDate(
            for: key,
            storedIn: &recentlyTerminatedTaskAt,
            now: now
        )
    }

    func recordCompletedTask(_ key: CodexActivityTaskKey, at completedAt: Date) {
        Self.recordTerminalTask(
            key,
            at: completedAt,
            storedIn: &recentlyCompletedTaskAt
        )
    }

    func recordTerminatedTask(_ key: CodexActivityTaskKey, at terminatedAt: Date) {
        Self.recordTerminalTask(
            key,
            at: terminatedAt,
            storedIn: &recentlyTerminatedTaskAt
        )
    }

    func clearCollectedActivityState() {
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
        recentlyCompletedTaskAt.removeAll()
        recentlyTerminatedTaskAt.removeAll()
        terminalTaskKeyByID.removeAll()
        ignoredAutoReviewTaskAt.removeAll()
    }

    static func recentTerminalDate(
        for key: CodexActivityTaskKey,
        storedIn dates: inout [CodexActivityTaskKey: Date],
        now: Date
    ) -> Date? {
        guard let date = dates[key] else {
            return nil
        }
        guard date > now.addingTimeInterval(-completedTaskRetention) else {
            dates.removeValue(forKey: key)
            return nil
        }
        return date
    }

    static func recordTerminalTask(
        _ key: CodexActivityTaskKey,
        at date: Date,
        storedIn dates: inout [CodexActivityTaskKey: Date]
    ) {
        dates[key] = max(dates[key] ?? .distantPast, date)
        if let sessionId = key.sessionId {
            let sessionKey = CodexActivityTaskKey.session(sessionId)
            dates[sessionKey] = max(dates[sessionKey] ?? .distantPast, date)
        }
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
            recordTerminatedTask(key, at: terminatedAt)
            clearActivityProtection(
                for: key,
                taskID: pending.task.displayID,
                reason: .terminal
            )
        }
    }

    func publishLiveTransitions(_ transitions: [CodexActivityLiveTransition]) {
        var lastWaitingIndexByKey: [CodexActivityTaskKey: Int] = [:]
        for (index, transition) in transitions.enumerated() {
            if case let .waitingApproval(key) = transition {
                lastWaitingIndexByKey[key] = index
            }
        }

        var publishedCompletionIDs = Set<UUID>()
        for (index, transition) in transitions.enumerated() {
            switch transition {
            case let .waitingApproval(key):
                guard !key.isAnonymous,
                      lastWaitingIndexByKey[key] == index,
                      let task = tasks[key],
                      task.state == .waitingApproval else {
                    continue
                }
                transitionSubject.send(.waitingApproval(task.snapshot))
            case let .completed(completion):
                guard !completion.isAnonymous,
                      terminalTaskKeyByID[completion.id] != nil,
                      publishedCompletionIDs.insert(completion.id).inserted else {
                    continue
                }
                transitionSubject.send(.completed(completion))
            }
        }
    }
}
