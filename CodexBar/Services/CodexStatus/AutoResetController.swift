import AppKit
import Combine
import Foundation
import IOKit
import os

/// 自动重置的本机状态机
/// 计划执行前通过 helper 预约系统唤醒, 唤醒后仍经新鲜读取决定是否使用
@MainActor
final class AutoResetController {
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
        let candidate: AutoResetCandidate
        let key: String

        var idempotencyKey: String {
            AutoResetIdentity.idempotencyKey(forCreditID: candidate.id)
        }
    }

    private struct RetryWindow {
        let targetKey: String
        let deadline: Date
    }

    private static let retryDelays: [TimeInterval] = [15, 30, 60, 120, 300]
    private static let retryWindowDuration: TimeInterval = 5 * 60
    private static let finalNothingToResetWindow: TimeInterval = 10 * 60
    private static let finalNothingToResetDelay: TimeInterval = 60

    private let settings: AutoResetSettings
    private let statusViewModel: CodexStatusViewModel
    private let service: CodexStatusService
    private let notificationService: CodexNotificationService
    private let keepAliveController: KeepAliveController
    private let wakeActivity = SystemSleepService(
        sleepAssertionName: "CodexBar - Automatic Reset"
    )

    private var cancellables = Set<AnyCancellable>()
    private var scheduledTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var settingsActivationTask: Task<Void, Never>?
    private var evaluationGeneration = 0
    private var pendingEvaluation = false
    private var latestSnapshot: CodexQuotaSnapshot?
    private var target: Target?
    private var retryWindow: RetryWindow?
    private var retryIndex = 0
    private var consumedTargetKeys = Set<String>()
    private var expiredTargetDates: [String: Date] = [:]
    private var blockedTargets: [String: BlockReason] = [:]
    private var isStarted = false

    init(
        settings: AutoResetSettings,
        statusViewModel: CodexStatusViewModel,
        service: CodexStatusService,
        notificationService: CodexNotificationService,
        keepAliveController: KeepAliveController
    ) {
        self.settings = settings
        self.statusViewModel = statusViewModel
        self.service = service
        self.notificationService = notificationService
        self.keepAliveController = keepAliveController
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
        keepAliveController.setAutoResetRequested(
            settings.isEnabled,
            opensSystemSettings: false
        )

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
        keepAliveController.setAutoResetRequested(
            false,
            opensSystemSettings: false
        )
        cancellables.removeAll()
        cancelWork()
        target = nil
    }

    private func handleEnabledChange(_ enabled: Bool) {
        keepAliveController.setAutoResetRequested(
            enabled,
            opensSystemSettings: enabled
        )
        guard enabled else {
            cancelWork()
            target = nil
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

    private func handleLeadTimeChange(_: AutoResetLeadTime) {
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
            accountIdentity: AutoResetIdentity.accountIdentity(for: snapshot.account),
            availableCount: snapshot.resetCreditsAvailableCount,
            candidates: snapshot.autoResetCandidates,
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

        let startedAt = Date()
        if let retryWindow,
           retryWindow.deadline <= startedAt {
            finishRetryWindow(ifMatching: retryWindow.targetKey)
            if trigger == .retry {
                cancelScheduledTask()
                return
            }
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
                expectedTargetKey: expectedTargetKey,
                startedAt: startedAt
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
        expectedTargetKey: String?,
        startedAt: Date
    ) async {
        let holdsWakeActivity = beginWakeActivityIfNeeded(trigger: trigger)
        defer {
            endWakeActivityIfNeeded(holdsWakeActivity)
        }

        if let target,
           expectedTargetKey == nil || expectedTargetKey == target.key,
           thresholdDate(for: target) <= startedAt {
            startRetryWindowIfNeeded(for: target, startedAt: startedAt)
        }

        let freshRead: AutoResetRead
        do {
            freshRead = try await service.readCreditsForAutoReset()
        } catch {
            guard !Task.isCancelled, settings.isEnabled else {
                return
            }
            handleRequestFailure(error, windowStartedAt: startedAt)
            return
        }

        guard !Task.isCancelled, settings.isEnabled else {
            return
        }

        let now = Date()
        reconcile(freshRead, now: now)

        guard freshRead.candidates != nil else {
            if target != nil || (freshRead.availableCount ?? 0) > 0 {
                scheduleRetry(cause: .detailsUnavailable, windowStartedAt: startedAt)
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

        let thresholdDate = thresholdDate(for: target)
        guard thresholdDate <= now else {
            scheduleCurrentTargetIfNeeded()
            return
        }

        startRetryWindowIfNeeded(for: target, startedAt: startedAt)

        AppLog.app.notice(
            "自动重置开始: trigger=\(trigger.rawValue, privacy: .public)"
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
            handleConsumeFailure(
                error,
                attemptedTarget: attemptedTarget,
                windowStartedAt: startedAt
            )
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
            notificationService.notifyAutoResetSucceeded(
                remainingCount: remainingCount,
                dedupToken: attemptedTarget.key
            )
            AppLog.app.notice(
                "自动重置完成: outcome=\(result.outcome.rawValue, privacy: .public)"
            )

            if settings.isEnabled,
               let refreshedRead,
               refreshedRead.accountIdentity == attemptedTarget.accountIdentity {
                reconcile(refreshedRead)
                scheduleCurrentTargetIfNeeded()
            }
            statusViewModel.refreshAfterCurrent(trigger: .autoReset)

        case .nothingToReset, .noCredit:
            if let refreshedRead = result.refreshedRead {
                reconcile(refreshedRead)
            }

            guard settings.isEnabled,
                  target?.key == attemptedTarget.key else {
                statusViewModel.refreshAfterCurrent(trigger: .autoReset)
                return
            }

            let cause: RetryCause = result.outcome == .nothingToReset
                ? .nothingToReset
                : .noCredit
            AppLog.app.notice(
                "自动重置未完成: outcome=\(result.outcome.rawValue, privacy: .public)"
            )
            scheduleRetry(cause: cause)

            if result.outcome == .noCredit {
                statusViewModel.refreshAfterCurrent(trigger: .autoReset)
            }
        }
    }

    private func handleConsumeFailure(
        _ error: Error,
        attemptedTarget: Target,
        windowStartedAt: Date
    ) {
        guard !Task.isCancelled,
              settings.isEnabled,
              target?.key == attemptedTarget.key else {
            return
        }
        handleRequestFailure(error, windowStartedAt: windowStartedAt)
    }

    private func handleRequestFailure(_ error: Error, windowStartedAt: Date) {
        if error is AutoResetServiceError {
            clearTarget()
            statusViewModel.refreshAfterCurrent(trigger: .autoReset)
            return
        }

        if let error = error as? CodexStatusError {
            if error.isAuthenticationRequired {
                blockCurrentTarget(reason: .authentication)
                statusViewModel.refreshAfterCurrent(trigger: .autoReset)
                return
            }
            if error.isProtocolOrParameterFailure {
                blockCurrentTarget(reason: .permanent)
                return
            }

            if scheduleRetry(cause: .transient, windowStartedAt: windowStartedAt) {
                AppLog.app.notice("自动重置稍后重试: reason=requestFailed")
            }
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
        resetRetryWindow(ifMatching: target.key)
        switch reason {
        case .authentication:
            notificationService.notifyAutoResetFailed(
                reason: .authentication,
                dedupToken: target.key
            )
            AppLog.app.error("自动重置已暂停: reason=authentication")
        case .permanent:
            notificationService.notifyAutoResetFailed(
                reason: .permanent,
                dedupToken: target.key
            )
            AppLog.app.error("自动重置已停止: reason=permanentFailure")
        }
    }

    @discardableResult
    private func scheduleRetry(
        cause: RetryCause,
        windowStartedAt: Date = Date()
    ) -> Bool {
        guard settings.isEnabled,
              let target,
              thresholdDate(for: target) <= windowStartedAt else {
            return false
        }
        guard blockedTargets[target.key] == nil else {
            return false
        }

        let now = Date()
        let remaining = target.candidate.expirationDate.timeIntervalSince(now)
        guard remaining > 0 else {
            finishExpiredTarget(target)
            return false
        }

        let retryWindow = startRetryWindowIfNeeded(
            for: target,
            startedAt: windowStartedAt
        )
        guard retryWindow.deadline > now else {
            scheduleRetryWindowEnd(
                at: now,
                expectedTargetKey: target.key
            )
            return false
        }

        var delay = nextRetryDelay()
        if cause == .nothingToReset, remaining <= Self.finalNothingToResetWindow {
            delay = Self.finalNothingToResetDelay
        }
        delay = min(delay, remaining)
        let retryDate = now.addingTimeInterval(delay)
        guard retryDate < retryWindow.deadline else {
            scheduleRetryWindowEnd(
                at: retryWindow.deadline,
                expectedTargetKey: target.key
            )
            return false
        }
        schedule(
            at: retryDate,
            kind: .retry,
            expectedTargetKey: target.key
        )
        return true
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

        let thresholdDate = thresholdDate(for: target)
        if thresholdDate > Date() {
            // 回到正常阈值等待后开始新的重试周期, 避免旧故障影响正式执行
            resetRetryWindow()
        }
        schedule(
            at: thresholdDate,
            kind: .threshold,
            expectedTargetKey: target.key
        )
    }

    private func schedule(
        at date: Date,
        kind: ScheduledKind,
        expectedTargetKey: String
    ) {
        cancelScheduledTask(clearsWakeSchedule: false)
        keepAliveController.setAutoResetWakeDate(date)
        scheduledTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
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

    private func scheduleRetryWindowEnd(
        at date: Date,
        expectedTargetKey: String
    ) {
        cancelScheduledTask()
        // 截止任务占住 scheduledTask, 防止当前评估返回后立即重排已经过去的阈值
        // 系统唤醒已由 cancelScheduledTask 清除
        scheduledTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }

            scheduledTask = nil
            finishRetryWindow(ifMatching: expectedTargetKey)
        }
    }

    private func reconcile(
        accountIdentity: String,
        availableCount: Int?,
        candidates: [AutoResetCandidate]?,
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
                        "自动重置计划已更新: reason=expirationChanged direction=\(direction, privacy: .public)"
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
                // 因此只停止本机任务, 不发送自动重置通知
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
            AppLog.app.notice("自动重置计划已恢复: reason=expirationExtended")
        }
        if target?.key == nextTarget.key {
            return
        }

        cancelScheduledTask()
        resetRetryWindow()
        target = nextTarget
        if blockedTargets[nextTarget.key] == .authentication {
            blockedTargets.removeValue(forKey: nextTarget.key)
        }
    }

    private func reconcile(
        _ read: AutoResetRead,
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
        _ candidate: AutoResetCandidate,
        accountIdentity: String,
        now: Date
    ) -> Bool {
        guard candidate.expirationDate > now else {
            return false
        }

        let key = AutoResetIdentity.notificationToken(
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
        candidate: AutoResetCandidate
    ) -> Target {
        Target(
            accountIdentity: accountIdentity,
            candidate: candidate,
            key: AutoResetIdentity.notificationToken(
                accountIdentity: accountIdentity,
                creditID: candidate.id
            )
        )
    }

    private func thresholdDate(for target: Target) -> Date {
        target.candidate.expirationDate
            .addingTimeInterval(-settings.leadTime.duration)
    }

    @discardableResult
    private func startRetryWindowIfNeeded(
        for target: Target,
        startedAt: Date
    ) -> RetryWindow {
        if let retryWindow,
           retryWindow.targetKey == target.key {
            return retryWindow
        }

        let retryWindow = RetryWindow(
            targetKey: target.key,
            deadline: startedAt.addingTimeInterval(Self.retryWindowDuration)
        )
        self.retryWindow = retryWindow
        retryIndex = 0
        AppLog.app.notice("自动重置重试窗口已开始")
        return retryWindow
    }

    private func finishRetryWindow(ifMatching targetKey: String) {
        guard retryWindow?.targetKey == targetKey else {
            return
        }

        retryWindow = nil
        retryIndex = 0
        AppLog.app.notice("自动重置重试窗口已结束: reason=deadline")
    }

    private func resetRetryWindow(ifMatching targetKey: String? = nil) {
        if let targetKey,
           retryWindow?.targetKey != targetKey {
            return
        }

        retryWindow = nil
        retryIndex = 0
    }

    private func finishExpiredTarget(_ expiredTarget: Target) {
        expiredTargetDates[expiredTarget.key] = expiredTarget.candidate.expirationDate
        clearTarget(ifMatching: expiredTarget.key)
        notificationService.notifyAutoResetFailed(
            reason: .expired,
            dedupToken: expiredTarget.key
        )
        AppLog.app.error("自动重置失败: reason=expired")
        statusViewModel.refreshAfterCurrent(trigger: .autoReset)
    }

    private func clearTarget(ifMatching key: String? = nil) {
        if let key, target?.key != key {
            return
        }
        cancelScheduledTask()
        target = nil
        resetRetryWindow()
    }

    private func cancelScheduledTask(clearsWakeSchedule: Bool = true) {
        scheduledTask?.cancel()
        scheduledTask = nil
        if clearsWakeSchedule {
            keepAliveController.setAutoResetWakeDate(nil)
        }
    }

    private func beginWakeActivityIfNeeded(trigger: LogTrigger) -> Bool {
        guard trigger == .auto || trigger == .retry || trigger == .wake else {
            return false
        }

        let result = wakeActivity.beginPreventingIdleSleep()
        guard result == kIOReturnSuccess else {
            AppLog.app.error("自动重置短时防睡眠失败: code=\(result)")
            return false
        }
        return true
    }

    private func endWakeActivityIfNeeded(_ isActive: Bool) {
        guard isActive else {
            return
        }

        let result = wakeActivity.endPreventingIdleSleep()
        if result != kIOReturnSuccess {
            AppLog.app.error("自动重置短时防睡眠释放失败: code=\(result)")
        }
    }

    private func cancelWork() {
        cancelScheduledTask()
        resetRetryWindow()
        settingsActivationTask?.cancel()
        settingsActivationTask = nil
        evaluationGeneration += 1
        evaluationTask?.cancel()
        evaluationTask = nil
        pendingEvaluation = false
    }
}
