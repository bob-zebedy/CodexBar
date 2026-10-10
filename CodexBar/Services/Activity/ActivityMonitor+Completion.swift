import Combine
import Foundation
import os

extension ActivityMonitor {
    func finishTask(from event: ActivityRecord, source: ActivityEventSource, into transitions: inout [ActivityTransition]) {
        guard let eventKey = ActivityTaskKey(event: event) else { return }
        guard recentEndedDate(for: eventKey) == nil else {
            discardStaleTerminalTask(for: eventKey)
            return
        }
        let key = eventKey
        var task = pendingTerminalTasks[key]?.task ?? tasks[key] ?? ActivityTask(
            displayID: UUID(), key: key, event: event, state: .running,
            startedAt: event.context?.turnStartedAt, progressGeneration: 0
        )
        // 服务端轮次时间可能只有整秒精度, 同秒内的工具事件不应阻止明确终态
        let timestampTolerance: TimeInterval = event.context?.turnCompletedAt == nil ? 0 : 1
        guard event.timestamp.addingTimeInterval(timestampTolerance) >= task.lastMainEventAt else { return }
        task.mergeMetadata(from: event)
        if task.startedAt == nil, let start = event.context?.turnStartedAt, start <= event.timestamp {
            task.startedAt = start
        }
        tasks.removeValue(forKey: key)
        pendingTerminalTasks.removeValue(forKey: key)
        let completedAt = event.context == nil ? event.timestamp : event.context?.turnCompletedAt
        let terminal: SessionTerminalState
        if event.eventKind == .turnCompleted {
            terminal = .completed(at: completedAt, duration: event.context?.duration)
        } else {
            task.terminalFailed = task.terminalFailed || event.context?.turnStatus == .failed
            terminal = .aborted(at: completedAt, duration: event.context?.duration)
        }
        resolveTerminal(
            terminal, task: task, key: key, abortFallback: event.timestamp,
            publishesEvents: source == .live, into: &transitions
        )
        recordEndedTask(eventKey, at: event.timestamp)
    }

    // MARK: - 终态判定与记录

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
        case let .aborted(reportedAt, duration):
            let terminatedAt = max(reportedAt ?? abortFallback, task.lastActivityAt)
            let termination = storeTermination(
                task, at: terminatedAt,
                duration: duration ?? reportedAt.flatMap { task.preciseDuration(until: $0) }
            )
            if publishesEvents {
                recordTerminalPresentationEvent(.terminated(termination))
            }
            recordEndedTask(key, at: terminatedAt)
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
            if canPublishActivityTransitions,
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
        if state.readStatus == .complete, let status = state.turnStatus {
            task.terminalFailed = status == .failed
        }
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
            taskID: task.displayID,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            completedAt: recordedCompletedAt,
            duration: reportedDuration ?? completedAt.flatMap { task.preciseDuration(until: $0) }
        )
        completions.append(completion)
        registerTerminalTokenUsage(id: completion.id, task: task)
        recordEndedTask(key, at: recordedCompletedAt)
        return completion
    }

    private func storeTermination(
        _ task: ActivityTask,
        at terminatedAt: Date,
        duration: TimeInterval?
    ) -> ActivityTermination {
        let termination = ActivityTermination(
            id: UUID(),
            taskID: task.displayID,
            projectName: task.projectName,
            modelName: task.modelName,
            effort: task.effort,
            terminatedAt: terminatedAt,
            duration: duration,
            isFailure: task.terminalFailed
        )
        terminations.append(termination)
        registerTerminalTokenUsage(id: termination.id, task: task)
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
        guard date > now.addingTimeInterval(-Self.endedTaskRetention) else {
            recentlyEndedTaskAt.removeValue(forKey: key)
            return nil
        }
        return date
    }

    func recordEndedTask(_ key: ActivityTaskKey, at date: Date) {
        recentlyEndedTaskAt[key] = max(recentlyEndedTaskAt[key] ?? .distantPast, date)
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
        terminalTokenUsageRequests.removeAll()
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
            guard lastWaitingIndexByKey[key] == index,
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
