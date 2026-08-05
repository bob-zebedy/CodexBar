import Foundation
import os

extension CodexActivityMonitor {
    // MARK: - 异常任务保护

    private var canEvaluateActivityProtection: Bool {
        isStarted
            && isActivityProtectionEnabled
            && tailReader != nil
            && !isBootstrapping
            && !isActivityProtectionRecoveryInProgress
            && isActivitySourceHealthy
    }

    func setActivityProtectionEnabled(_ enabled: Bool) {
        guard enabled != isActivityProtectionEnabled else {
            return
        }
        isActivityProtectionEnabled = enabled
        cancelInactivityCheck()
        cancelAllActivityProtectionAttempts()

        guard isStarted else {
            return
        }

        let now = Date()
        guard enabled else {
            restoreAllSuppressedActivityTasks(restoredAt: now)
            refreshSnapshot(now: now)
            return
        }
        reconcileActivityProtection(now: now, sendsNotification: false)
    }

    func handleActivityProtectionTimingChange() {
        cancelAllActivityProtectionAttempts()
        reconcileActivityProtection(now: Date(), sendsNotification: false)
    }

    @discardableResult
    func beginActivityProtectionRecovery() -> UInt64 {
        activityProtectionRecoveryGeneration &+= 1
        isActivityProtectionRecoveryInProgress = true
        cancelInactivityCheck()
        cancelAllActivityProtectionAttempts()
        return activityProtectionRecoveryGeneration
    }

    func finishActivityProtectionRecovery(generation: UInt64) {
        guard generation == activityProtectionRecoveryGeneration else {
            return
        }
        isActivityProtectionRecoveryInProgress = false
        reconcileActivityProtection(now: Date(), sendsNotification: false)
    }

    func resetActivityProtectionRecovery() {
        activityProtectionRecoveryGeneration &+= 1
        isActivityProtectionRecoveryInProgress = false
        cancelAllActivityProtectionAttempts()
    }

    func applyPersistedActivityProtection(now: Date) {
        removeExpiredActivityProtectionRecords(now: now)

        guard isActivityProtectionEnabled else {
            return
        }

        for (key, var task) in tasks {
            let identifier = key.activityProtectionIdentifier
            guard let record = activityProtectionRecords[identifier] else {
                continue
            }

            if task.state == .waitingApproval || task.lastProgressAt > record.lastProgressAt {
                clearActivityProtection(
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

    func reconcileActivityProtection(
        now: Date,
        sendsNotification: Bool
    ) {
        guard canEvaluateActivityProtection else {
            cancelInactivityCheck()
            refreshSnapshot(now: now)
            return
        }

        if sendsNotification {
            beginDueInactivityChecks(now: now)
            return
        }

        let threshold = activityProtectionSettings.inactivityDuration.timeInterval
        let restorableKeys = tasks.compactMap { key, task -> CodexActivityTaskKey? in
            guard task.state == .suppressed,
                  task.lastProgressAt.addingTimeInterval(threshold) > now else {
                return nil
            }
            return key
        }
        for key in restorableKeys {
            restoreActivityTaskForCurrentThreshold(key, restoredAt: now)
        }

        let overdueKeys = tasks.compactMap { key, task -> CodexActivityTaskKey? in
            guard task.state == .running,
                  task.lastProgressAt.addingTimeInterval(threshold) <= now else {
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
        guard canEvaluateActivityProtection else {
            cancelInactivityCheck()
            return
        }

        let threshold = activityProtectionSettings.inactivityDuration.timeInterval
        let nextDeadline = tasks.compactMap { key, task -> Date? in
            guard task.state == .running,
                  activityProtectionAttempts[key] == nil else {
                return nil
            }
            return task.lastProgressAt.addingTimeInterval(threshold)
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
            reconcileActivityProtection(now: Date(), sendsNotification: true)
        }
    }

    func cancelInactivityCheck() {
        inactivityCheckTask?.cancel()
        inactivityCheckTask = nil
        inactivityCheckDeadline = nil
    }

    func beginDueInactivityChecks(now: Date) {
        guard isActivityProtectionEnabled,
              !isActivityProtectionRecoveryInProgress else {
            refreshSnapshot(now: now)
            return
        }

        let threshold = activityProtectionSettings.inactivityDuration.timeInterval
        let candidates = tasks.compactMap { key, task -> ActivityProtectionCandidate? in
            guard task.state == .running,
                  activityProtectionAttempts[key] == nil,
                  task.lastProgressAt.addingTimeInterval(threshold) <= now else {
                return nil
            }
            return ActivityProtectionCandidate(
                key: key,
                taskID: task.displayID,
                projectName: task.projectName,
                lastProgressAt: task.lastProgressAt,
                progressGeneration: task.progressGeneration,
                inactivityDuration: activityProtectionSettings.inactivityDuration
            )
        }

        for candidate in candidates {
            beginActivityProtectionAttempt(candidate)
        }
        refreshSnapshot(now: now)
    }

    func beginActivityProtectionAttempt(_ candidate: ActivityProtectionCandidate) {
        guard isActivityProtectionCandidateRelevant(candidate, now: Date()) else {
            return
        }

        invalidateActivityProtectionNotification(for: candidate.taskID)

        let attemptID = UUID()
        let markedAt = Date()
        persistActivityProtectionRecord(
            for: candidate.key,
            lastProgressAt: candidate.lastProgressAt,
            markedAt: markedAt
        )

        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.activityProtectionNotificationSubmissionGrace)
            guard let self, !Task.isCancelled else {
                return
            }
            finishActivityProtectionAttempt(
                candidate.key,
                attemptID: attemptID,
                taskID: candidate.taskID,
                notificationWasSubmitted: false
            )
        }
        activityProtectionAttempts[candidate.key] = ActivityProtectionAttempt(
            id: attemptID,
            candidate: candidate,
            markedAt: markedAt,
            timeoutTask: timeoutTask
        )
        activityProtectionNoticeAttemptIDs[candidate.taskID] = attemptID

        let notice = CodexActivityProtectionNotice(
            taskID: candidate.taskID,
            attemptID: attemptID,
            projectName: candidate.projectName,
            inactivityDurationText: candidate.inactivityDuration.title,
            inactivityDurationSeconds: candidate.inactivityDuration.rawValue,
            progressGeneration: candidate.progressGeneration
        )
        let notificationHandler = onInactivityProtectionTriggered
        Task { @MainActor [weak self] in
            let notificationWasSubmitted = await notificationHandler?(notice) ?? false
            self?.finishActivityProtectionAttempt(
                candidate.key,
                attemptID: attemptID,
                taskID: candidate.taskID,
                notificationWasSubmitted: notificationWasSubmitted
            )
        }
    }

    func finishActivityProtectionAttempt(
        _ key: CodexActivityTaskKey,
        attemptID: UUID,
        taskID: UUID,
        notificationWasSubmitted: Bool
    ) {
        guard let attempt = activityProtectionAttempts[key],
              attempt.id == attemptID else {
            if notificationWasSubmitted {
                onInactivityProtectionInvalidated?(taskID, attemptID)
            }
            return
        }

        guard isActivityProtectionCandidateRelevant(attempt.candidate, now: Date()) else {
            cancelActivityProtectionAttempt(for: key, matching: attemptID)
            refreshSnapshot(now: Date())
            return
        }

        attempt.timeoutTask.cancel()
        activityProtectionAttempts.removeValue(forKey: key)
        if !notificationWasSubmitted {
            invalidateActivityProtectionNotification(
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
        _ key: CodexActivityTaskKey,
        markedAt: Date
    ) {
        cancelActivityProtectionAttempt(for: key)
        guard var task = tasks[key], task.state == .running else {
            return
        }

        persistActivityProtectionRecord(
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
        _ key: CodexActivityTaskKey,
        now: Date
    ) {
        guard isStarted,
              isActivityProtectionEnabled,
              tailReader != nil,
              !isBootstrapping,
              isActivitySourceHealthy,
              let task = tasks[key],
              task.state == .running,
              task.lastProgressAt.addingTimeInterval(
                  activityProtectionSettings.inactivityDuration.timeInterval
              ) <= now else {
            return
        }
        suppressActivityTaskSilently(key, markedAt: now)
    }

    func restoreActivityTaskForCurrentThreshold(
        _ key: CodexActivityTaskKey,
        restoredAt: Date
    ) {
        guard var task = tasks[key], task.state == .suppressed else {
            return
        }

        task.state = .running
        task.stateChangedAt = restoredAt
        tasks[key] = task
        clearActivityProtection(
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
            invalidateActivityProtectionNotification(for: task.displayID)
        }
        for (taskID, attemptID) in Array(activityProtectionNoticeAttemptIDs) {
            invalidateActivityProtectionNotification(for: taskID, matching: attemptID)
        }
        if !suppressedKeys.isEmpty {
            AppLog.activity.notice(
                "异常任务已全部恢复: reason=keepAliveDisabled; count=\(suppressedKeys.count)"
            )
        }
    }

    func isActivityProtectionCandidateRelevant(
        _ candidate: ActivityProtectionCandidate,
        now: Date
    ) -> Bool {
        guard canEvaluateActivityProtection,
              activityProtectionSettings.inactivityDuration == candidate.inactivityDuration,
              let task = tasks[candidate.key],
              task.displayID == candidate.taskID,
              task.state == .running,
              task.lastProgressAt == candidate.lastProgressAt,
              task.progressGeneration == candidate.progressGeneration else {
            return false
        }
        return task.lastProgressAt
            .addingTimeInterval(candidate.inactivityDuration.timeInterval) <= now
    }

    func isInactivityProtectionNoticeRelevant(
        taskID: UUID,
        attemptID: UUID,
        progressGeneration: UInt64,
        inactivityDurationSeconds: Int
    ) -> Bool {
        guard canEvaluateActivityProtection,
              activityProtectionSettings.inactivityDuration.rawValue == inactivityDurationSeconds,
              activityProtectionNoticeAttemptIDs[taskID] == attemptID,
              let attempt = activityProtectionAttempts.values.first(where: {
                  $0.id == attemptID && $0.candidate.taskID == taskID
              }) else {
            return false
        }

        let now = Date()
        guard let task = tasks[attempt.candidate.key] else {
            return false
        }
        return task.displayID == taskID
            && task.state == .running
            && task.progressGeneration == progressGeneration
            && task.lastProgressAt.addingTimeInterval(
                activityProtectionSettings.inactivityDuration.timeInterval
            ) <= now
    }

    func shouldRestoreActivityProtection(
        for key: CodexActivityTaskKey,
        progressAt: Date
    ) -> Bool {
        guard let record = activityProtectionRecords[key.activityProtectionIdentifier] else {
            return true
        }
        return progressAt > record.lastProgressAt
    }

    func clearActivityProtection(
        for key: CodexActivityTaskKey,
        taskID: UUID?,
        reason: ActivityProtectionClearReason
    ) {
        cancelActivityProtectionAttempt(for: key)
        let identifier = key.activityProtectionIdentifier
        let record = activityProtectionRecords.removeValue(forKey: identifier)
        if let record {
            let matchingMarkedAt: Date? = switch reason {
            case .progress, .thresholdChange: record.markedAt
            case .terminal, .retention: nil
            }
            enqueueActivityProtectionPersistence(
                removals: [
                    ActivityProtectionRemoval(
                        taskIdentifier: identifier,
                        matchingMarkedAt: matchingMarkedAt
                    )
                ]
            )
        }
        if let taskID {
            invalidateActivityProtectionNotification(for: taskID)
        }
    }

    func invalidateActivityProtectionNotification(for taskID: UUID) {
        guard let attemptID = activityProtectionNoticeAttemptIDs[taskID] else {
            return
        }
        invalidateActivityProtectionNotification(for: taskID, matching: attemptID)
    }

    func invalidateActivityProtectionNotification(
        for taskID: UUID,
        matching attemptID: UUID
    ) {
        guard activityProtectionNoticeAttemptIDs[taskID] == attemptID else {
            return
        }
        activityProtectionNoticeAttemptIDs.removeValue(forKey: taskID)
        onInactivityProtectionInvalidated?(taskID, attemptID)
    }

    func cancelActivityProtectionAttempt(
        for key: CodexActivityTaskKey,
        matching attemptID: UUID? = nil
    ) {
        guard let attempt = activityProtectionAttempts[key],
              attemptID == nil || attempt.id == attemptID else {
            return
        }

        attempt.timeoutTask.cancel()
        activityProtectionAttempts.removeValue(forKey: key)

        let identifier = key.activityProtectionIdentifier
        if let record = activityProtectionRecords[identifier],
           record.markedAt == attempt.markedAt {
            activityProtectionRecords.removeValue(forKey: identifier)
            enqueueActivityProtectionPersistence(
                removals: [
                    ActivityProtectionRemoval(
                        taskIdentifier: identifier,
                        matchingMarkedAt: attempt.markedAt
                    )
                ]
            )
        }
        invalidateActivityProtectionNotification(
            for: attempt.candidate.taskID,
            matching: attempt.id
        )
    }

    func cancelAllActivityProtectionAttempts() {
        for key in Array(activityProtectionAttempts.keys) {
            cancelActivityProtectionAttempt(for: key)
        }
    }

    func removeExpiredActivityProtectionRecords(now: Date) {
        let expiredIdentifiers = activityProtectionRecords.compactMap { identifier, record in
            record.expiresAt <= now ? identifier : nil
        }
        guard !expiredIdentifiers.isEmpty else {
            return
        }

        for identifier in expiredIdentifiers {
            activityProtectionRecords.removeValue(forKey: identifier)
        }
        enqueueActivityProtectionPersistence(
            removals: expiredIdentifiers.map {
                ActivityProtectionRemoval(taskIdentifier: $0)
            }
        )
    }

    func persistActivityProtectionRecord(
        for key: CodexActivityTaskKey,
        lastProgressAt: Date,
        markedAt: Date
    ) {
        let record = ActivityProtectionRecord(
            taskIdentifier: key.activityProtectionIdentifier,
            lastProgressAt: lastProgressAt,
            markedAt: markedAt,
            expiresAt: lastProgressAt.addingTimeInterval(Self.activityRetention)
        )
        activityProtectionRecords[record.taskIdentifier] = record
        enqueueActivityProtectionPersistence(upserts: [record])
    }

    func enqueueActivityProtectionPersistence(
        upserts: [ActivityProtectionRecord] = [],
        removals: [ActivityProtectionRemoval] = []
    ) {
        let previousTask = activityProtectionPersistenceTask
        let stateStore = activityProtectionStateStore
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
        activityProtectionPersistenceTask = task
    }
}
