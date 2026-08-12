import AppKit
import Combine
import Foundation
import os

/// 自动使用临期重置的本机状态机
/// 系统睡眠时不申请唤醒, 唤醒后经新鲜读取决定是否补试
@MainActor
final class ResetCreditAutomationController {
    private enum ScheduledKind: Equatable {
        case threshold
        case retry
    }

    private enum RetryCause: Equatable {
        case transient
        case detailsUnavailable
        case nothingToReset
        case noCredit
    }

    private enum BlockReason: Equatable {
        case authentication
        case permanent
    }

    private struct Target {
        let accountIdentity: String
        let candidate: ResetCreditAutomationCandidate
        let key: String

        var idempotencyKey: String {
            ResetCreditAutomationIdentity.idempotencyKey(forCreditID: candidate.id)
        }
    }

    private static let retryDelays: [TimeInterval] = [15, 30, 60, 120, 300]
    private static let finalNothingToResetWindow: TimeInterval = 10 * 60
    private static let finalNothingToResetDelay: TimeInterval = 60

    private let settings: ResetCreditAutomationSettings
    private let statusViewModel: CodexStatusViewModel
    private let service: CodexStatusService
    private let notificationService: CodexNotificationService

    private var cancellables = Set<AnyCancellable>()
    private var scheduledTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var settingsActivationTask: Task<Void, Never>?
    private var evaluationGeneration = 0
    private var pendingEvaluation = false
    private var latestSnapshot: CodexQuotaSnapshot?
    private var target: Target?
    private var retryIndex = 0
    private var consumedTargetKeys = Set<String>()
    private var expiredTargetDates: [String: Date] = [:]
    private var blockedTargets: [String: BlockReason] = [:]
    private var isStarted = false

    init(
        settings: ResetCreditAutomationSettings,
        statusViewModel: CodexStatusViewModel,
        service: CodexStatusService,
        notificationService: CodexNotificationService
    ) {
        self.settings = settings
        self.statusViewModel = statusViewModel
        self.service = service
        self.notificationService = notificationService
    }

    deinit {
        scheduledTask?.cancel()
        evaluationTask?.cancel()
        settingsActivationTask?.cancel()
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true

        statusViewModel.$snapshot
            .sink { [weak self] snapshot in
                self?.handleSnapshot(snapshot)
            }
            .store(in: &cancellables)

        settings.$isEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                self?.handleEnabledChange(enabled)
            }
            .store(in: &cancellables)

        settings.$leadTime
            .dropFirst()
            .sink { [weak self] leadTime in
                self?.handleLeadTimeChange(leadTime)
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.requestEvaluation(trigger: .wake)
            }
            .store(in: &cancellables)

        if settings.isEnabled {
            requestEvaluation(trigger: .launch)
        }
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        cancellables.removeAll()
        cancelWork()
        target = nil
        retryIndex = 0
    }

    private func handleEnabledChange(_ enabled: Bool) {
        guard enabled else {
            cancelWork()
            target = nil
            retryIndex = 0
            return
        }

        settingsActivationTask?.cancel()
        settingsActivationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  settings.isEnabled else {
                return
            }

            settingsActivationTask = nil
            if let latestSnapshot {
                handleSnapshot(latestSnapshot)
            }
            requestEvaluation(trigger: .settings)
        }
    }

    private func handleLeadTimeChange(_: ResetCreditAutomationLeadTime) {
        guard settings.isEnabled else {
            return
        }
        requestEvaluation(trigger: .settings)
    }

    private func handleSnapshot(_ snapshot: CodexQuotaSnapshot?) {
        latestSnapshot = snapshot
        guard settings.isEnabled,
              let snapshot,
              !snapshot.isRateLimitsStale else {
            return
        }

        reconcile(
            accountIdentity: ResetCreditAutomationIdentity.accountIdentity(for: snapshot.account),
            availableCount: snapshot.resetCreditsAvailableCount,
            candidates: snapshot.resetCreditAutomationCandidates,
            now: Date()
        )
        scheduleCurrentTargetIfNeeded()
    }

    private func requestEvaluation(
        trigger: LogTrigger,
        expectedTargetKey: String? = nil
    ) {
        guard isStarted, settings.isEnabled else {
            return
        }
        guard evaluationTask == nil else {
            pendingEvaluation = true
            return
        }

        cancelScheduledTask()
        evaluationGeneration += 1
        let generation = evaluationGeneration
        evaluationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await performEvaluation(
                trigger: trigger,
                expectedTargetKey: expectedTargetKey
            )
            finishEvaluation(generation: generation)
        }
    }

    private func finishEvaluation(generation: Int) {
        guard generation == evaluationGeneration else {
            return
        }

        evaluationTask = nil
        guard pendingEvaluation else {
            scheduleCurrentTargetIfNeeded()
            return
        }

        pendingEvaluation = false
        requestEvaluation(trigger: .retry)
    }

    private func performEvaluation(
        trigger: LogTrigger,
        expectedTargetKey: String?
    ) async {
        let freshRead: ResetCreditAutomationRead
        do {
            freshRead = try await service.readResetCreditsForAutomation()
        } catch {
            guard !Task.isCancelled, settings.isEnabled else {
                return
            }
            handleRequestFailure(error)
            return
        }

        guard !Task.isCancelled, settings.isEnabled else {
            return
        }

        let now = Date()
        reconcile(freshRead, now: now)

        guard freshRead.candidates != nil else {
            if target != nil || (freshRead.availableCount ?? 0) > 0 {
                scheduleRetry(cause: .detailsUnavailable)
            }
            return
        }
        guard let target else {
            return
        }
        if let expectedTargetKey, expectedTargetKey != target.key {
            scheduleCurrentTargetIfNeeded()
            return
        }
        guard blockedTargets[target.key] == nil else {
            return
        }
        guard target.candidate.expirationDate > now else {
            finishExpiredTarget(target)
            return
        }

        let thresholdDate = target.candidate.expirationDate
            .addingTimeInterval(-settings.leadTime.duration)
        guard thresholdDate <= now else {
            scheduleCurrentTargetIfNeeded()
            return
        }

        AppLog.app.notice(
            "自动使用重置开始: trigger=\(trigger.rawValue, privacy: .public)"
        )
        let attemptedTarget = target
        do {
            let result = try await service.consumeResetCredit(
                id: attemptedTarget.candidate.id,
                idempotencyKey: attemptedTarget.idempotencyKey,
                expectedAccountIdentity: attemptedTarget.accountIdentity
            )
            handleConsumeResult(result, attemptedTarget: attemptedTarget)
        } catch {
            handleConsumeFailure(error, attemptedTarget: attemptedTarget)
        }
    }

    private func handleConsumeResult(
        _ result: ResetCreditConsumeResult,
        attemptedTarget: Target
    ) {
        switch result.outcome {
        case .reset, .alreadyRedeemed:
            consumedTargetKeys.insert(attemptedTarget.key)
            expiredTargetDates.removeValue(forKey: attemptedTarget.key)
            blockedTargets.removeValue(forKey: attemptedTarget.key)
            clearTarget(ifMatching: attemptedTarget.key)

            let refreshedRead = result.refreshedRead
            let remainingCount = refreshedRead?.accountIdentity == attemptedTarget.accountIdentity
                ? refreshedRead?.availableCount
                : nil
            notificationService.notifyResetCreditAutoUseSucceeded(
                remainingCount: remainingCount,
                dedupToken: attemptedTarget.key
            )
            AppLog.app.notice(
                "自动使用重置完成: outcome=\(result.outcome.rawValue, privacy: .public)"
            )

            if settings.isEnabled,
               let refreshedRead,
               refreshedRead.accountIdentity == attemptedTarget.accountIdentity {
                reconcile(refreshedRead)
                scheduleCurrentTargetIfNeeded()
            }
            statusViewModel.refreshAfterCurrent(trigger: .resetCreditAutoUse)

        case .nothingToReset, .noCredit:
            if let refreshedRead = result.refreshedRead {
                reconcile(refreshedRead)
            }

            guard settings.isEnabled,
                  target?.key == attemptedTarget.key else {
                statusViewModel.refreshAfterCurrent(trigger: .resetCreditAutoUse)
                return
            }

            let cause: RetryCause = result.outcome == .nothingToReset
                ? .nothingToReset
                : .noCredit
            AppLog.app.notice(
                "自动使用重置未完成: outcome=\(result.outcome.rawValue, privacy: .public)"
            )
            scheduleRetry(cause: cause)

            if result.outcome == .noCredit {
                statusViewModel.refreshAfterCurrent(trigger: .resetCreditAutoUse)
            }
        }
    }

    private func handleConsumeFailure(_ error: Error, attemptedTarget: Target) {
        guard !Task.isCancelled,
              settings.isEnabled,
              target?.key == attemptedTarget.key else {
            return
        }
        handleRequestFailure(error)
    }

    private func handleRequestFailure(_ error: Error) {
        if error is ResetCreditAutomationServiceError {
            clearTarget()
            statusViewModel.refreshAfterCurrent(trigger: .resetCreditAutoUse)
            return
        }

        if let error = error as? CodexStatusError {
            if error.isAuthenticationRequired {
                blockCurrentTarget(reason: .authentication)
                statusViewModel.refreshAfterCurrent(trigger: .resetCreditAutoUse)
                return
            }
            if error.isProtocolOrParameterFailure {
                blockCurrentTarget(reason: .permanent)
                return
            }

            AppLog.app.notice("自动使用重置稍后重试: reason=requestFailed")
            scheduleRetry(cause: .transient)
            return
        }

        blockCurrentTarget(reason: .permanent)
    }

    private func blockCurrentTarget(reason: BlockReason) {
        guard let target else {
            return
        }

        blockedTargets[target.key] = reason
        cancelScheduledTask()
        switch reason {
        case .authentication:
            notificationService.notifyResetCreditAutoUseFailed(
                reason: .authentication,
                dedupToken: target.key
            )
            AppLog.app.error("自动使用重置已暂停: reason=authentication")
        case .permanent:
            notificationService.notifyResetCreditAutoUseFailed(
                reason: .permanent,
                dedupToken: target.key
            )
            AppLog.app.error("自动使用重置已停止: reason=permanentFailure")
        }
    }

    private func scheduleRetry(cause: RetryCause) {
        guard settings.isEnabled else {
            return
        }
        guard let target else {
            schedule(after: nextRetryDelay(), kind: .retry, expectedTargetKey: nil)
            return
        }
        guard blockedTargets[target.key] == nil else {
            return
        }

        let remaining = target.candidate.expirationDate.timeIntervalSinceNow
        guard remaining > 0 else {
            finishExpiredTarget(target)
            return
        }

        var delay = nextRetryDelay()
        if cause == .nothingToReset, remaining <= Self.finalNothingToResetWindow {
            delay = Self.finalNothingToResetDelay
        }
        delay = min(delay, remaining)
        schedule(
            after: delay,
            kind: .retry,
            expectedTargetKey: target.key
        )
    }

    private func nextRetryDelay() -> TimeInterval {
        let index = min(retryIndex, Self.retryDelays.count - 1)
        retryIndex += 1
        return Self.retryDelays[index]
    }

    private func scheduleCurrentTargetIfNeeded() {
        guard isStarted,
              settings.isEnabled,
              evaluationTask == nil,
              scheduledTask == nil,
              let target,
              blockedTargets[target.key] == nil else {
            return
        }

        let delay = target.candidate.expirationDate
            .addingTimeInterval(-settings.leadTime.duration)
            .timeIntervalSinceNow
        schedule(
            after: delay,
            kind: .threshold,
            expectedTargetKey: target.key
        )
    }

    private func schedule(
        after delay: TimeInterval,
        kind: ScheduledKind,
        expectedTargetKey: String?
    ) {
        cancelScheduledTask()
        scheduledTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, delay)))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }

            scheduledTask = nil
            requestEvaluation(
                trigger: kind == .threshold ? .auto : .retry,
                expectedTargetKey: expectedTargetKey
            )
        }
    }

    private func reconcile(
        accountIdentity: String,
        availableCount: Int?,
        candidates: [ResetCreditAutomationCandidate]?,
        now: Date
    ) {
        if let target, target.accountIdentity != accountIdentity {
            clearTarget()
        }

        if availableCount == 0 {
            clearTarget()
            return
        }

        guard let candidates else {
            return
        }

        if let currentTarget = target,
           currentTarget.accountIdentity == accountIdentity {
            if let matchingCandidate = candidates.first(where: {
                $0.id == currentTarget.candidate.id
            }) {
                let expirationChanged = matchingCandidate.expirationDate
                    != currentTarget.candidate.expirationDate
                let updatedTarget = makeTarget(
                    accountIdentity: accountIdentity,
                    candidate: matchingCandidate
                )
                target = updatedTarget
                if expirationChanged {
                    // creditId 决定幂等身份, expiresAt 是可变调度数据
                    // 取消阈值或重试任务, 由当前调用链按新时间重建
                    cancelScheduledTask()
                    let direction = matchingCandidate.expirationDate
                        < currentTarget.candidate.expirationDate ? "earlier" : "later"
                    AppLog.app.notice(
                        "自动使用重置计划已更新: reason=expirationChanged direction=\(direction, privacy: .public)"
                    )
                }
                if blockedTargets[currentTarget.key] == .authentication {
                    blockedTargets.removeValue(forKey: currentTarget.key)
                }
                if matchingCandidate.expirationDate <= now {
                    finishExpiredTarget(updatedTarget)
                    return
                }
            } else {
                // 凭证消失无法区分手动使用 其他设备使用或服务端过期
                // 因此只停止本机任务, 不发送自动使用通知
                clearTarget()
            }
        }

        let nextCandidate = candidates
            .filter { candidate in
                isCandidateEligible(
                    candidate,
                    accountIdentity: accountIdentity,
                    now: now
                )
            }
            .sorted { lhs, rhs in
                if lhs.expirationDate != rhs.expirationDate {
                    return lhs.expirationDate < rhs.expirationDate
                }
                return lhs.id < rhs.id
            }
            .first

        guard let nextCandidate else {
            return
        }

        let nextTarget = makeTarget(
            accountIdentity: accountIdentity,
            candidate: nextCandidate
        )
        if expiredTargetDates.removeValue(forKey: nextTarget.key) != nil {
            AppLog.app.notice("自动使用重置计划已恢复: reason=expirationExtended")
        }
        if target?.key == nextTarget.key {
            return
        }

        cancelScheduledTask()
        target = nextTarget
        retryIndex = 0
        if blockedTargets[nextTarget.key] == .authentication {
            blockedTargets.removeValue(forKey: nextTarget.key)
        }
    }

    private func reconcile(
        _ read: ResetCreditAutomationRead,
        now: Date = Date()
    ) {
        reconcile(
            accountIdentity: read.accountIdentity,
            availableCount: read.availableCount,
            candidates: read.candidates,
            now: now
        )
    }

    private func isCandidateEligible(
        _ candidate: ResetCreditAutomationCandidate,
        accountIdentity: String,
        now: Date
    ) -> Bool {
        guard candidate.expirationDate > now else {
            return false
        }

        let key = ResetCreditAutomationIdentity.notificationToken(
            accountIdentity: accountIdentity,
            creditID: candidate.id
        )
        guard !consumedTargetKeys.contains(key) else {
            return false
        }
        guard let expiredDate = expiredTargetDates[key] else {
            return true
        }
        return candidate.expirationDate > expiredDate
    }

    private func makeTarget(
        accountIdentity: String,
        candidate: ResetCreditAutomationCandidate
    ) -> Target {
        Target(
            accountIdentity: accountIdentity,
            candidate: candidate,
            key: ResetCreditAutomationIdentity.notificationToken(
                accountIdentity: accountIdentity,
                creditID: candidate.id
            )
        )
    }

    private func finishExpiredTarget(_ expiredTarget: Target) {
        expiredTargetDates[expiredTarget.key] = expiredTarget.candidate.expirationDate
        clearTarget(ifMatching: expiredTarget.key)
        notificationService.notifyResetCreditAutoUseFailed(
            reason: .expired,
            dedupToken: expiredTarget.key
        )
        AppLog.app.error("自动使用重置失败: reason=expired")
        statusViewModel.refreshAfterCurrent(trigger: .resetCreditAutoUse)
    }

    private func clearTarget(ifMatching key: String? = nil) {
        if let key, target?.key != key {
            return
        }
        cancelScheduledTask()
        target = nil
        retryIndex = 0
    }

    private func cancelScheduledTask() {
        scheduledTask?.cancel()
        scheduledTask = nil
    }

    private func cancelWork() {
        cancelScheduledTask()
        settingsActivationTask?.cancel()
        settingsActivationTask = nil
        evaluationGeneration += 1
        evaluationTask?.cancel()
        evaluationTask = nil
        pendingEvaluation = false
    }
}
