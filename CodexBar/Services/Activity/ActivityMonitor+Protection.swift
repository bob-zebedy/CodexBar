import Foundation
import os

extension ActivityMonitor {
    // MARK: - 异常任务保护

    private var canEvaluateProtection: Bool {
        isStarted
            && isProtectionEnabled
            && isProtectionStoreAvailable
            && activityReader != nil
            && !isBootstrapping
            && !isProtectionRecoveryInProgress
            && isActivitySourceHealthy
    }

    func setProtectionEnabled(_ enabled: Bool) {
        guard enabled != isProtectionEnabled else {
            return
        }
        isProtectionEnabled = enabled
        cancelInactivityCheck()
        cancelAllProtectionAttempts()

        guard isStarted else {
            return
        }

        let now = Date()
        guard enabled else {
            restoreAllSuppressedActivityTasks(restoredAt: now)
            refreshSnapshot(now: now)
            return
        }
        loadProtectionState()
        reconcileProtection(now: now, sendsNotification: false)
    }

    func handleProtectionTimingChange() {
        cancelAllProtectionAttempts()
        reconcileProtection(now: Date(), sendsNotification: false)
    }

    @discardableResult
    func beginProtectionRecovery() -> UInt64 {
        protectionRecoveryGeneration &+= 1
        isProtectionRecoveryInProgress = true
        sessionTransitionNotBefore = nil
        resetTerminalPresentationEvents()
        cancelInactivityCheck()
        cancelAllProtectionAttempts()
        return protectionRecoveryGeneration
    }

    func finishProtectionRecovery(generation: UInt64) {
        guard generation == protectionRecoveryGeneration else {
            return
        }
        resetTerminalPresentationEvents()
        isProtectionRecoveryInProgress = false
        sessionTransitionNotBefore = Date()
        reconcileProtection(now: Date(), sendsNotification: false)
    }

    func resetProtectionRecovery() {
        protectionRecoveryGeneration &+= 1
        isProtectionRecoveryInProgress = false
        cancelAllProtectionAttempts()
    }

    func applyPersistedProtection(now: Date) {
        removeExpiredProtectionRecords(now: now)

        guard canEvaluateProtection else {
            return
        }

        for (key, var task) in tasks {
            guard task.hasFreshLifecycle(at: now),
                  let record = protectionRecords[key.protectionIdentifier] else {
                continue
            }

            if task.state == .waitingApproval || task.lastProgressAt > record.lastProgressAt {
                clearProtection(
                    for: key,
                    taskID: task.displayID,
                    reason: .progress
                )
                continue
            }

            task.state = .suppressed
            task.stateChangedAt = record.markedAt
            tasks[key] = task
        }
    }

    func reconcileProtection(
        now: Date,
        sendsNotification: Bool
    ) {
        guard canEvaluateProtection else {
            cancelInactivityCheck()
            refreshSnapshot(now: now)
            return
        }

        if sendsNotification {
            beginDueInactivityChecks(now: now)
            return
        }

        let threshold = protectionSettings.inactivityDuration.timeInterval
        let restorableKeys = tasks.compactMap { key, task -> ActivityTaskKey? in
            guard task.state == .suppressed,
                  task.protectionReferenceAt.addingTimeInterval(threshold) > now else {
                return nil
            }
            return key
        }
        for key in restorableKeys {
            restoreActivityTaskForCurrentThreshold(key, restoredAt: now)
        }

        let overdueKeys = tasks.compactMap { key, task -> ActivityTaskKey? in
            guard task.state == .running,
                  let deadline = task.protectionDeadline(at: now, inactivityDuration: threshold),
                  deadline <= now else {
                return nil
            }
            return key
        }
        for key in overdueKeys {
            suppressActivityTaskSilently(key, markedAt: now)
        }
        refreshSnapshot(now: now)
    }

    func scheduleNextInactivityCheck(now: Date) {
        guard canEvaluateProtection else {
            cancelInactivityCheck()
            return
        }

        let threshold = protectionSettings.inactivityDuration.timeInterval
        let nextDeadline = tasks.compactMap { key, task -> Date? in
            guard task.state == .running,
                  protectionAttempts[key] == nil else {
                return nil
            }
            return task.protectionDeadline(at: now, inactivityDuration: threshold)
        }.min()

        guard let nextDeadline else {
            cancelInactivityCheck()
            return
        }
        guard inactivityCheckTask == nil || inactivityCheckDeadline != nextDeadline else {
            return
        }

        cancelInactivityCheck()
        inactivityCheckDeadline = nextDeadline
        let remaining = max(0, nextDeadline.timeIntervalSince(now))
        let deadline = SuspendingClock.Instant.now.advanced(by: .seconds(remaining))
        inactivityCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: SuspendingClock())
            guard let self, !Task.isCancelled else {
                return
            }
            inactivityCheckTask = nil
            inactivityCheckDeadline = nil
            reconcileProtection(now: Date(), sendsNotification: true)
        }
    }

    func cancelInactivityCheck() {
        inactivityCheckTask?.cancel()
        inactivityCheckTask = nil
        inactivityCheckDeadline = nil
    }

    func beginDueInactivityChecks(now: Date) {
        guard canEvaluateProtection else {
            refreshSnapshot(now: now)
            return
        }

        let threshold = protectionSettings.inactivityDuration.timeInterval
        let candidates = tasks.compactMap { key, task -> ProtectionCandidate? in
            guard task.state == .running,
                  protectionAttempts[key] == nil,
                  let deadline = task.protectionDeadline(at: now, inactivityDuration: threshold),
                  deadline <= now else {
                return nil
            }
            return ProtectionCandidate(
                key: key,
                taskID: task.displayID,
                projectName: task.projectName,
                lastProgressAt: task.lastProgressAt,
                progressGeneration: task.progressGeneration,
                inactivityDuration: protectionSettings.inactivityDuration
            )
        }

        for candidate in candidates {
            beginProtectionAttempt(candidate)
        }
        refreshSnapshot(now: now)
    }

    func beginProtectionAttempt(_ candidate: ProtectionCandidate) {
        guard isProtectionCandidateRelevant(candidate, now: Date()) else {
            return
        }

        invalidateProtectionNotification(for: candidate.taskID)

        let attemptID = UUID()
        let markedAt = Date()
        persistProtectionRecord(
            for: candidate.key,
            lastProgressAt: candidate.lastProgressAt,
            markedAt: markedAt
        )

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.protectionNotificationSubmissionGrace)
            guard let self, !Task.isCancelled else {
                return
            }
            finishProtectionAttempt(
                candidate.key,
                attemptID: attemptID,
                taskID: candidate.taskID,
                notificationWasSubmitted: false
            )
        }
        protectionAttempts[candidate.key] = ProtectionAttempt(
            id: attemptID,
            candidate: candidate,
            markedAt: markedAt,
            timeoutTask: timeoutTask
        )
        protectionNoticeAttemptIDs[candidate.taskID] = attemptID

        let notice = ProtectionNotice(
            taskID: candidate.taskID,
            attemptID: attemptID,
            projectName: candidate.projectName,
            inactivityDurationText: candidate.inactivityDuration.title
        )
        let notificationHandler = onProtectionTriggered
        Task { @MainActor [weak self] in
            let notificationWasSubmitted = await notificationHandler?(notice) ?? false
            self?.finishProtectionAttempt(
                candidate.key,
                attemptID: attemptID,
                taskID: candidate.taskID,
                notificationWasSubmitted: notificationWasSubmitted
            )
        }
    }

    func finishProtectionAttempt(
        _ key: ActivityTaskKey,
        attemptID: UUID,
        taskID: UUID,
        notificationWasSubmitted: Bool
    ) {
        guard let attempt = protectionAttempts[key],
              attempt.id == attemptID else {
            if notificationWasSubmitted {
                onProtectionInvalidated?(taskID, attemptID)
            }
            return
        }

        guard isProtectionCandidateRelevant(attempt.candidate, now: Date()) else {
            cancelProtectionAttempt(for: key, matching: attemptID)
            refreshSnapshot(now: Date())
            return
        }

        attempt.timeoutTask.cancel()
        protectionAttempts.removeValue(forKey: key)
        if !notificationWasSubmitted {
            invalidateProtectionNotification(
                for: attempt.candidate.taskID,
                matching: attemptID
            )
        }

        guard var task = tasks[key] else {
            return
        }
        task.state = .suppressed
        task.stateChangedAt = attempt.markedAt
        tasks[key] = task
        AppLog.activity.notice(
            "异常任务已隐藏: thresholdMinutes=\(attempt.candidate.inactivityDuration.loggedMinutes)"
        )
        refreshSnapshot(now: Date())
    }

    func suppressActivityTaskSilently(
        _ key: ActivityTaskKey,
        markedAt: Date
    ) {
        cancelProtectionAttempt(for: key)
        guard var task = tasks[key],
              task.state == .running else {
            return
        }

        persistProtectionRecord(
            for: key,
            lastProgressAt: task.lastProgressAt,
            markedAt: markedAt
        )
        task.state = .suppressed
        task.stateChangedAt = markedAt
        tasks[key] = task
        AppLog.activity.notice("异常任务已静默隐藏: reason=reconcile")
    }

    func suppressBackfilledActivityTaskIfOverdue(
        _ key: ActivityTaskKey,
        now: Date
    ) {
        guard canEvaluateProtection,
              let task = tasks[key],
              task.state == .running,
              let deadline = task.protectionDeadline(at: now, inactivityDuration: protectionSettings.inactivityDuration.timeInterval),
              deadline <= now else {
            return
        }
        suppressActivityTaskSilently(key, markedAt: now)
    }

    func restoreActivityTaskForCurrentThreshold(
        _ key: ActivityTaskKey,
        restoredAt: Date
    ) {
        guard var task = tasks[key], task.state == .suppressed else {
            return
        }

        task.state = .running
        task.stateChangedAt = restoredAt
        tasks[key] = task
        clearProtection(
            for: key,
            taskID: task.displayID,
            reason: .thresholdChange
        )
        AppLog.activity.notice("异常任务已静默恢复: reason=thresholdChange")
    }

    func restoreAllSuppressedActivityTasks(restoredAt: Date) {
        let suppressedKeys = tasks.compactMap { key, task in
            task.state == .suppressed ? key : nil
        }
        for key in suppressedKeys {
            guard var task = tasks[key] else {
                continue
            }
            task.state = .running
            task.stateChangedAt = restoredAt
            tasks[key] = task
            invalidateProtectionNotification(for: task.displayID)
        }
        for (taskID, attemptID) in Array(protectionNoticeAttemptIDs) {
            invalidateProtectionNotification(for: taskID, matching: attemptID)
        }
        if !suppressedKeys.isEmpty {
            AppLog.activity.notice(
                "异常任务已全部恢复: reason=keepAliveDisabled; count=\(suppressedKeys.count)"
            )
        }
    }

    func isProtectionCandidateRelevant(
        _ candidate: ProtectionCandidate,
        now: Date
    ) -> Bool {
        guard canEvaluateProtection,
              protectionSettings.inactivityDuration == candidate.inactivityDuration,
              let task = tasks[candidate.key],
              task.displayID == candidate.taskID,
              task.state == .running,
              task.lastProgressAt == candidate.lastProgressAt,
              task.progressGeneration == candidate.progressGeneration else {
            return false
        }
        return task.protectionDeadline(at: now, inactivityDuration: candidate.inactivityDuration.timeInterval)
            .map { $0 <= now } == true
    }

    func isProtectionNoticeRelevant(
        taskID: UUID,
        attemptID: UUID
    ) -> Bool {
        guard protectionNoticeAttemptIDs[taskID] == attemptID,
              let attempt = protectionAttempts.values.first(where: {
                  $0.id == attemptID && $0.candidate.taskID == taskID
              }) else {
            return false
        }

        return isProtectionCandidateRelevant(attempt.candidate, now: Date())
    }

    func shouldRestoreProtection(
        for key: ActivityTaskKey,
        progressAt: Date
    ) -> Bool {
        guard let record = protectionRecords[key.protectionIdentifier] else {
            return true
        }
        return progressAt > record.lastProgressAt
    }

    func clearProtection(
        for key: ActivityTaskKey,
        taskID: UUID?,
        reason: ProtectionClearReason
    ) {
        cancelProtectionAttempt(for: key)
        let identifier = key.protectionIdentifier
        if let record = protectionRecords.removeValue(forKey: identifier) {
            let matchingMarkedAt: Date? = switch reason {
            case .progress, .thresholdChange: record.markedAt
            case .terminal: nil
            }
            enqueueProtectionPersistence(
                removals: [
                    ProtectionRemoval(
                        taskIdentifier: identifier,
                        matchingMarkedAt: matchingMarkedAt
                    )
                ]
            )
        }
        if let taskID {
            invalidateProtectionNotification(for: taskID)
        }
    }

    func invalidateProtectionNotification(for taskID: UUID) {
        guard let attemptID = protectionNoticeAttemptIDs[taskID] else {
            return
        }
        invalidateProtectionNotification(for: taskID, matching: attemptID)
    }

    func invalidateProtectionNotification(
        for taskID: UUID,
        matching attemptID: UUID
    ) {
        guard protectionNoticeAttemptIDs[taskID] == attemptID else {
            return
        }
        protectionNoticeAttemptIDs.removeValue(forKey: taskID)
        onProtectionInvalidated?(taskID, attemptID)
    }

    func cancelProtectionAttempt(
        for key: ActivityTaskKey,
        matching attemptID: UUID? = nil
    ) {
        guard let attempt = protectionAttempts[key],
              attemptID == nil || attempt.id == attemptID else {
            return
        }

        attempt.timeoutTask.cancel()
        protectionAttempts.removeValue(forKey: key)

        let identifier = key.protectionIdentifier
        if let record = protectionRecords[identifier],
           record.markedAt == attempt.markedAt {
            protectionRecords.removeValue(forKey: identifier)
            enqueueProtectionPersistence(
                removals: [
                    ProtectionRemoval(
                        taskIdentifier: identifier,
                        matchingMarkedAt: attempt.markedAt
                    )
                ]
            )
        }
        invalidateProtectionNotification(
            for: attempt.candidate.taskID,
            matching: attempt.id
        )
    }

    func cancelAllProtectionAttempts() {
        for key in Array(protectionAttempts.keys) {
            cancelProtectionAttempt(for: key)
        }
    }

    func removeExpiredProtectionRecords(now: Date) {
        let expiredIdentifiers = protectionRecords.compactMap { identifier, record in
            record.expiresAt <= now ? identifier : nil
        }
        guard !expiredIdentifiers.isEmpty else {
            return
        }

        for identifier in expiredIdentifiers {
            protectionRecords.removeValue(forKey: identifier)
        }
        enqueueProtectionPersistence(
            removals: expiredIdentifiers.map {
                ProtectionRemoval(taskIdentifier: $0)
            }
        )
    }

    func persistProtectionRecord(
        for key: ActivityTaskKey,
        lastProgressAt: Date,
        markedAt: Date
    ) {
        let record = ProtectionRecord(
            taskIdentifier: key.protectionIdentifier,
            lastProgressAt: lastProgressAt,
            markedAt: markedAt,
            expiresAt: lastProgressAt.addingTimeInterval(ActivityRetention.window)
        )
        protectionRecords[record.taskIdentifier] = record
        enqueueProtectionPersistence(upserts: [record])
    }

    func enqueueProtectionPersistence(
        upserts: [ProtectionRecord] = [],
        removals: [ProtectionRemoval] = []
    ) {
        let previousTask = protectionPersistenceTask
        let stateStore = protectionStore
        let task = Task { @MainActor in
            await previousTask?.value
            do {
                try await stateStore.apply(
                    upserts: upserts,
                    removals: removals
                )
            } catch {
                AppLog.activity.error(
                    "异常任务状态写入失败: reason=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        protectionPersistenceTask = task
    }
}
