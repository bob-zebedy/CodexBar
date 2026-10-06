import AppKit
import Combine
import Foundation
import IOKit
import os

@MainActor
protocol AutoResetWakeActivity: AnyObject {
    func beginPreventingIdleSleep() -> IOReturn
    func endPreventingIdleSleep() -> IOReturn
}

extension SystemSleepService: AutoResetWakeActivity {}

/// 定时器只负责触发, 凭证预算和执行结果由控制器拥有
@MainActor
final class AutoResetController {
    struct Dependencies {
        var read: (AppServerRequestBudget) async throws -> AutoResetRead
        var consume: (AutoResetCandidate, String, AppServerRequestBudget) async throws -> ResetCreditConsumeResult
        var setRequested: (Bool) -> Void
        var setWakeDate: (Date?) -> Void
        var succeeded: (Int?, String) -> Void
        var failed: (AutoResetFailureNotice, String) -> Void
        var refresh: () -> Void
        var makeWakeActivity: () -> any AutoResetWakeActivity = {
            SystemSleepService(sleepAssertionName: "CodexBar - Automatic Reset")
        }

        var now: () -> Date = Date.init
        var sleep: (Date) async throws -> Void = { date in
            try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
        }
    }

    private enum BlockReason { case authentication, permanent }

    private struct Record {
        var schedule = AutoResetSchedule()
        var expirationDate: Date
        var block: BlockReason?
        var consumed = false
        var notifiedExpiration: Date?
    }

    private struct Target {
        let accountIdentity: String
        let candidate: AutoResetCandidate
        var key: String {
            AutoResetIdentity.notificationToken(accountIdentity: accountIdentity, creditID: candidate.id)
        }
    }

    private struct Evaluation {
        let target: Target
        let attempt: AutoResetSchedule.Attempt
    }

    private let settings: AutoResetSettings
    private let snapshots: AnyPublisher<CodexQuotaSnapshot?, Never>
    private let dependencies: Dependencies
    private var cancellables = Set<AnyCancellable>()
    private var scheduledTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var generation = 0
    private var pendingTrigger: LogTrigger?
    private var target: Target?
    private var accountIdentity: String?
    private var records: [String: Record] = [:]
    private var isStarted = false
    private var isSleeping = false
    private var isPreparingForTermination = false
    private(set) var scheduledDate: Date?
    private(set) var wakeDate: Date?

    convenience init(
        settings: AutoResetSettings,
        statusViewModel: CodexStatusViewModel,
        service: CodexStatusService,
        notificationService: NotificationService,
        keepAliveController: KeepAliveController
    ) {
        self.init(settings: settings, snapshots: statusViewModel.$snapshot.eraseToAnyPublisher(), dependencies: Dependencies(
            read: { try await service.readCreditsForAutoReset(budget: $0) },
            consume: { candidate, account, budget in
                try await service.consumeResetCredit(
                    id: candidate.id,
                    idempotencyKey: AutoResetIdentity.idempotencyKey(forCreditID: candidate.id),
                    expectedAccountIdentity: account,
                    expirationDate: candidate.expirationDate,
                    budget: budget
                )
            },
            setRequested: { keepAliveController.setAutoResetRequested($0) },
            setWakeDate: { keepAliveController.setAutoResetWakeDate($0) },
            succeeded: { notificationService.notifyAutoResetSucceeded(remainingCount: $0, dedupToken: $1) },
            failed: { notificationService.notifyAutoResetFailed(reason: $0, dedupToken: $1) },
            refresh: { statusViewModel.refreshAfterCurrent(trigger: .autoReset) }
        ))
    }

    init(settings: AutoResetSettings, snapshots: AnyPublisher<CodexQuotaSnapshot?, Never>, dependencies: Dependencies) {
        self.settings = settings
        self.snapshots = snapshots
        self.dependencies = dependencies
    }

    deinit {
        scheduledTask?.cancel()
        evaluationTask?.cancel()
        activationTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        dependencies.setRequested(settings.isEnabled)
        snapshots.sink { [weak self] in self?.handleSnapshot($0) }.store(in: &cancellables)
        settings.$isEnabled.dropFirst().sink { [weak self] in self?.handleEnabledChange($0) }.store(in: &cancellables)
        settings.$leadTime.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, settings.isEnabled else { return }
            invalidateEvaluation()
            requestEvaluation(trigger: .settings)
        }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.handleSleep() }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.handleWake() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .NSSystemClockDidChange)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.handleClockChange() }.store(in: &cancellables)
        requestEvaluation(trigger: .launch)
    }

    func stop() {
        isStarted = false
        dependencies.setRequested(false)
        cancellables.removeAll()
        cancelWork()
        target = nil
    }

    func prepareForTermination() {
        isPreparingForTermination = true
        cancelWork()
    }

    func resumeAfterTerminationCancellation() {
        isPreparingForTermination = false
        requestEvaluation(trigger: .launch)
    }

    func handleSleep() {
        isSleeping = true
        invalidateEvaluation()
        cancelTimer()
        // 系统睡眠不撤销首次执行和最终复查的唤醒预约
        refreshSchedule()
    }

    func handleWake() {
        isSleeping = false
        requestEvaluation(trigger: .wake)
    }

    func handleClockChange() {
        invalidateEvaluation()
        setWakeDate(nil)
        refreshSchedule()
        requestEvaluation(trigger: .statusRefresh)
    }

    private var isEnabled: Bool {
        isStarted && settings.isEnabled && !isPreparingForTermination
    }

    private var canEvaluate: Bool {
        isEnabled && !isSleeping
    }

    private func handleEnabledChange(_ enabled: Bool) {
        dependencies.setRequested(enabled)
        guard enabled else {
            cancelWork()
            target = nil
            return
        }
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            // @Published 在 willSet 发值, 等设置提交后再读取
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            activationTask = nil
            requestEvaluation(trigger: .settings)
        }
    }

    private func handleSnapshot(_ snapshot: CodexQuotaSnapshot?) {
        guard isEnabled, let snapshot, !snapshot.isRateLimitsStale else { return }
        let previousKey = target?.key
        let previousExpiration = target?.candidate.expirationDate
        let identity = AutoResetIdentity.accountIdentity(for: snapshot.account)
        if let accountIdentity, accountIdentity != identity {
            invalidateEvaluation()
        }
        reconcile(AutoResetRead(accountIdentity: identity, availableCount: snapshot.resetCreditsAvailableCount, candidates: snapshot.autoResetCandidates))
        if let previousKey, previousKey != target?.key || previousExpiration != target?.candidate.expirationDate {
            invalidateEvaluation()
        }
        refreshSchedule()
    }

    private func requestEvaluation(trigger: LogTrigger) {
        guard canEvaluate else { return }
        guard evaluationTask == nil else {
            pendingTrigger = trigger
            return
        }
        cancelTimer()
        let generation = generation
        evaluationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await performEvaluation(trigger: trigger, generation: generation)
            finishEvaluation()
        }
    }

    private func finishEvaluation() {
        evaluationTask = nil
        if let trigger = pendingTrigger {
            pendingTrigger = nil
            requestEvaluation(trigger: trigger)
        }
        refreshSchedule()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && canEvaluate && !Task.isCancelled
    }

    private func performEvaluation(trigger: LogTrigger, generation: Int) async {
        guard isCurrent(generation) else { return }
        let activity = dependencies.makeWakeActivity()
        let holdsAssertion = activity.beginPreventingIdleSleep() == kIOReturnSuccess
        if !holdsAssertion {
            AppLog.app.error("自动重置短时防睡眠建立失败")
        }
        defer {
            if holdsAssertion, activity.endPreventingIdleSleep() != kIOReturnSuccess {
                AppLog.app.error("自动重置短时防睡眠释放失败")
            }
        }
        var evaluation = beginDueEvaluation()
        var transientFailure = true
        defer {
            if let evaluation {
                finishAttempt(evaluation, transientFailure: transientFailure, coversFinal: isCurrent(generation))
            }
        }
        do {
            let readDeadline = evaluation?.attempt.deadline ?? dependencies.now().addingTimeInterval(60)
            let budget = AppServerRequestBudget(deadline: readDeadline, now: dependencies.now())
            let read = try await dependencies.read(budget)
            guard isCurrent(generation) else { return }
            reconcile(read)
            guard read.candidates != nil else { return }
            guard let currentTarget = target else { return }
            if let evaluation, evaluation.target.key != currentTarget.key {
                return
            }
            if evaluation == nil {
                evaluation = beginDueEvaluation()
            }
            guard let evaluation, records[evaluation.target.key]?.block == nil else { return }
            let deadline = min(evaluation.attempt.deadline, AutoResetSchedule.cutoff(for: currentTarget.candidate.expirationDate))
            guard dependencies.now() < deadline, isCurrent(generation) else { return }
            updateWakeDate(during: evaluation)
            AppLog.app.notice("自动重置开始: trigger=\(trigger.rawValue, privacy: .public)")
            let result = try await dependencies.consume(
                currentTarget.candidate, currentTarget.accountIdentity,
                budget.constrained(to: deadline, now: dependencies.now())
            )
            transientFailure = false
            handleConsumeResult(result, evaluation: evaluation, isCurrent: isCurrent(generation))
        } catch {
            guard isCurrent(generation) else { return }
            handleFailure(error, evaluation: evaluation)
        }
    }

    private func beginDueEvaluation() -> Evaluation? {
        let now = dependencies.now()
        guard let target, var record = records[target.key], !record.consumed, record.block == nil,
              let attempt = record.schedule.begin(expirationDate: target.candidate.expirationDate, leadTime: settings.leadTime.duration, now: now) else { return nil }
        records[target.key] = record
        let evaluation = Evaluation(target: target, attempt: attempt)
        updateWakeDate(during: evaluation)
        return evaluation
    }

    private func finishAttempt(_ evaluation: Evaluation, transientFailure: Bool, coversFinal: Bool) {
        guard var record = records[evaluation.target.key], !record.consumed else { return }
        record.schedule.finish(evaluation.attempt, transientFailure: transientFailure, leadTime: settings.leadTime.duration, now: dependencies.now())
        if coversFinal {
            record.schedule.coverFinalIfNeeded(evaluation.attempt, expirationDate: record.expirationDate, transientFailure: transientFailure, now: dependencies.now())
        }
        records[evaluation.target.key] = record
    }

    private func handleConsumeResult(_ result: ResetCreditConsumeResult, evaluation: Evaluation, isCurrent: Bool) {
        let attempted = evaluation.target
        switch result.outcome {
        case .reset, .alreadyRedeemed:
            // 已确认的副作用不能因任务取消丢失, 但旧读取不能重建计划
            var record = records[attempted.key] ?? Record(expirationDate: attempted.candidate.expirationDate)
            let wasConsumed = record.consumed
            record.consumed = true
            record.block = nil
            records[attempted.key] = record
            if !wasConsumed {
                let remaining = result.refreshedRead.flatMap { $0.accountIdentity == attempted.accountIdentity ? $0.availableCount : nil }
                dependencies.succeeded(remaining, attempted.key)
            }
            if target?.key == attempted.key {
                target = nil
            }
            if isCurrent, let read = result.refreshedRead {
                reconcile(read)
            }
            dependencies.refresh()
            AppLog.app.notice("自动重置完成: outcome=\(result.outcome.rawValue, privacy: .public)")
        case .nothingToReset, .noCredit:
            guard isCurrent else { return }
            if let read = result.refreshedRead {
                reconcile(read)
            }
            if result.outcome == .noCredit {
                dependencies.refresh()
            }
            AppLog.app.notice("自动重置等待复查: outcome=\(result.outcome.rawValue, privacy: .public)")
        }
    }

    private func handleFailure(_ error: Error, evaluation: Evaluation?) {
        if case AutoResetServiceError.accountChanged = error {
            target = nil
            dependencies.refresh()
            return
        }
        if error is CancellationError || error is AutoResetServiceError {
            return
        }
        guard let key = evaluation?.target.key ?? target?.key else { return }
        if let error = error as? CodexStatusError {
            if error.isAuthenticationRequired {
                records[key]?.block = .authentication
                dependencies.failed(.authentication, key)
                dependencies.refresh()
            } else if error.isProtocolOrParameterFailure {
                records[key]?.block = .permanent
                dependencies.failed(.permanent, key)
            }
        } else {
            records[key]?.block = .permanent
            dependencies.failed(.permanent, key)
        }
    }

    // MARK: - 新鲜凭证与计划

    private func reconcile(_ read: AutoResetRead) {
        let now = dependencies.now()
        records = records.filter { $0.value.expirationDate > now.addingTimeInterval(-86400) }
        if accountIdentity != read.accountIdentity {
            target = nil
            accountIdentity = read.accountIdentity
        }
        guard read.availableCount != 0 else { target = nil
            return
        }
        guard let candidates = read.candidates else { return }
        if let target, let expired = candidates.first(where: { $0.id == target.candidate.id && $0.expirationDate <= now }),
           records[target.key]?.notifiedExpiration != expired.expirationDate {
            records[target.key]?.notifiedExpiration = expired.expirationDate
            dependencies.failed(.expired, target.key)
        }
        for candidate in candidates {
            let key = AutoResetIdentity.notificationToken(accountIdentity: read.accountIdentity, creditID: candidate.id)
            var record = records[key] ?? Record(expirationDate: candidate.expirationDate)
            record.expirationDate = candidate.expirationDate
            if record.block == .authentication {
                record.block = nil
            }
            records[key] = record
        }
        target = candidates.filter { candidate in
            let key = AutoResetIdentity.notificationToken(accountIdentity: read.accountIdentity, creditID: candidate.id)
            return candidate.expirationDate > now && records[key]?.consumed != true && records[key]?.block != .permanent
        }.sorted {
            $0.expirationDate == $1.expirationDate ? $0.id < $1.id : $0.expirationDate < $1.expirationDate
        }.first.map { Target(accountIdentity: read.accountIdentity, candidate: $0) }
    }

    private func refreshSchedule() {
        cancelTimer()
        guard isEnabled, let target, var record = records[target.key], record.block == nil, !record.consumed else {
            setWakeDate(nil)
            return
        }
        if evaluationTask != nil {
            let finalDate = target.candidate.expirationDate.addingTimeInterval(-AutoResetSchedule.finalLeadTime)
            setWakeDate(finalDate > dependencies.now() ? finalDate : nil)
            return
        }
        let plan = record.schedule.plan(expirationDate: target.candidate.expirationDate, leadTime: settings.leadTime.duration, now: dependencies.now())
        records[target.key] = record
        setWakeDate(plan?.wakeDate)
        guard let plan, !isSleeping else { return }
        scheduledDate = plan.evaluationDate
        let generation = generation
        scheduledTask = Task { @MainActor [weak self, sleep = dependencies.sleep] in
            do { try await sleep(plan.evaluationDate) } catch { return }
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            scheduledTask = nil
            scheduledDate = nil
            requestEvaluation(trigger: .auto)
        }
    }

    private func updateWakeDate(during evaluation: Evaluation) {
        let finalDate = evaluation.target.candidate.expirationDate.addingTimeInterval(-AutoResetSchedule.finalLeadTime)
        setWakeDate(evaluation.attempt.phase == .final || finalDate <= dependencies.now() ? nil : finalDate)
    }

    private func setWakeDate(_ date: Date?) {
        guard date != wakeDate else { return }
        wakeDate = date
        dependencies.setWakeDate(date)
    }

    private func cancelTimer() {
        scheduledTask?.cancel()
        scheduledTask = nil
        scheduledDate = nil
    }

    private func invalidateEvaluation() {
        generation += 1
        evaluationTask?.cancel()
        // 保留引用直到旧轮收尾, 新触发只排队, 不并行消费同一凭证
    }

    private func cancelWork() {
        cancelTimer()
        setWakeDate(nil)
        activationTask?.cancel()
        activationTask = nil
        pendingTrigger = nil
        invalidateEvaluation()
    }
}
