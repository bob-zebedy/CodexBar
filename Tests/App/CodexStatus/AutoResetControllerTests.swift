import Combine
import Foundation
import IOKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AutoResetControllerTests {
    @Test func repeatedSnapshotsCannotRestartExhaustedWindow() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        fixture.state.error = CodexStatusError.serverTimeout
        fixture.controller.start()
        // 首次读取尚无目标, 用快照发现凭证后再计入业务尝试
        try fixture.outcomes.send(.data(fixture.snapshot()))
        for (index, offset) in [0.0, 15, 45, 105, 225].enumerated() {
            fixture.clock.advance(to: fixture.start.addingTimeInterval(offset))
            try await eventually { fixture.controller.scheduledDate != nil && fixture.state.readCount >= index + 1 }
            for _ in 0 ..< 10 {
                try fixture.outcomes.send(.data(fixture.snapshot()))
            }
            if index < 4 {
                #expect(fixture.controller.scheduledDate == fixture.start.addingTimeInterval([15, 45, 105, 225][index]))
            }
        }
        #expect(fixture.controller.scheduledDate == fixture.start.addingTimeInterval(600))
        #expect(fixture.controller.wakeDate == fixture.expiration.addingTimeInterval(-180))
        #expect(fixture.state.consumeCount == 0)
        #expect(fixture.state.activeAssertions.isEmpty)
    }

    @Test func disableAndReenableWaitsForOldCleanupAndUsesFreshAssertion() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        let oldRead = ResetGate<AutoResetRead>()
        let newConsume = ResetGate<ResetCreditConsumeResult>()
        fixture.state.readOverride = { await oldRead.wait() }
        fixture.controller.start()
        try await eventually { fixture.state.readCount == 1 }
        #expect(fixture.state.activeAssertions.count == 1)
        fixture.settings.setEnabled(false)
        fixture.state.readOverride = nil
        fixture.state.consumeOverride = { await newConsume.wait() }
        fixture.settings.setEnabled(true)
        await settle()
        #expect(fixture.state.readCount == 1)
        oldRead.release(fixture.state.read)
        try await eventually { fixture.state.consumeCount == 1 }
        #expect(fixture.state.createdAssertions == 2)
        #expect(fixture.state.activeAssertions == [2])
        newConsume.release(ResetCreditConsumeResult(outcome: .nothingToReset, refreshedRead: fixture.state.read))
        try await eventually { fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.releasedAssertions == [1, 2])
    }

    @Test func confirmedSuccessAfterDisableDoesNotRecreateSchedule() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        let consume = ResetGate<ResetCreditConsumeResult>()
        fixture.state.consumeOverride = { await consume.wait() }
        fixture.controller.start()
        try await eventually { fixture.state.consumeCount == 1 }
        fixture.settings.setEnabled(false)
        consume.release(ResetCreditConsumeResult(outcome: .reset, refreshedRead: fixture.state.read))
        try await eventually { fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.successes == 1)
        #expect(fixture.controller.scheduledDate == nil)
        #expect(fixture.controller.wakeDate == nil)
        fixture.settings.setEnabled(true)
        try await eventually { fixture.state.readCount >= 2 && fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.consumeCount == 1)
    }

    @Test func ordinaryCheckKeepsFinalWakeAndSleepingDoesNotCatchUp() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        fixture.controller.start()
        try await eventually { fixture.controller.scheduledDate != nil }
        #expect(fixture.controller.scheduledDate == fixture.start.addingTimeInterval(300))
        #expect(fixture.controller.wakeDate == fixture.start.addingTimeInterval(720))
        fixture.controller.handleSleep()
        fixture.clock.advance(to: fixture.start.addingTimeInterval(730))
        await settle()
        #expect(fixture.state.consumeCount == 1)
        #expect(fixture.controller.scheduledDate == nil)
        fixture.controller.handleWake()
        try await eventually { fixture.state.consumeCount == 2 && fixture.state.activeAssertions.isEmpty }
        #expect(fixture.controller.scheduledDate == nil)
        #expect(fixture.controller.wakeDate == nil)
        for _ in 0 ..< 10 {
            try fixture.outcomes.send(.data(fixture.snapshot()))
        }
        await settle()
        #expect(fixture.state.consumeCount == 2)
    }

    @Test func lateStartWithinSafetyMarginNeverConsumes() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        fixture.clock.advance(to: fixture.expiration.addingTimeInterval(-50))
        fixture.controller.start()
        try await eventually { fixture.state.readCount == 1 && fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.consumeCount == 0)
        #expect(fixture.controller.scheduledDate == nil)
    }

    @Test func cancelledReadAcrossFinalPointDoesNotUseFinalOpportunity() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        let gate = ResetGate<AutoResetRead>()
        fixture.state.readOverride = { await gate.wait() }
        try fixture.outcomes.send(.data(fixture.snapshot()))
        fixture.controller.start()
        try await eventually { fixture.state.readCount == 1 }
        fixture.controller.handleSleep()
        fixture.clock.advance(to: fixture.start.addingTimeInterval(730))
        fixture.state.readOverride = nil
        fixture.controller.handleWake()
        gate.release(fixture.state.read)
        try await eventually { fixture.state.consumeCount == 1 && fixture.state.activeAssertions.isEmpty }
        #expect(fixture.controller.scheduledDate == nil)
    }

    @Test func terminationPreparationFreezesAndCancellationResumes() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        fixture.controller.start()
        try await eventually { fixture.controller.scheduledDate != nil }
        fixture.controller.prepareForTermination()
        fixture.clock.advance(to: fixture.start.addingTimeInterval(400))
        try fixture.outcomes.send(.data(fixture.snapshot()))
        await settle()
        #expect(fixture.state.consumeCount == 1)
        #expect(fixture.controller.wakeDate == nil)
        fixture.controller.resumeAfterTerminationCancellation()
        try await eventually { fixture.state.consumeCount == 2 && fixture.state.activeAssertions.isEmpty }
    }

    @Test(arguments: [false, true])
    func changedAccountRejectsLateOldRead(stale: Bool) async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        let gate = ResetGate<AutoResetRead>()
        let old = fixture.state.read
        try fixture.outcomes.send(.data(fixture.snapshot()))
        fixture.state.readOverride = { await gate.wait() }
        fixture.controller.start()
        try await eventually { fixture.state.readCount == 1 }
        fixture.state.account = CodexAccount(type: "chatgpt", email: "other@example.com", planType: "plus")
        fixture.state.readOverride = nil
        try fixture.outcomes.send(.data(fixture.snapshot(isStale: stale)))
        gate.release(old)
        try await eventually { fixture.state.consumeCount == 1 && fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.consumedAccounts == [AutoResetIdentity.accountIdentity(for: fixture.state.account)])
    }

    @Test(arguments: [false, true])
    func unavailableAccountClearsScheduleAndIgnoresLateRead(signedOut: Bool) async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        let gate = ResetGate<AutoResetRead>()
        try fixture.outcomes.send(.data(fixture.snapshot()))
        fixture.state.readOverride = { await gate.wait() }
        fixture.controller.start()
        try await eventually { fixture.state.readCount == 1 }
        #expect(fixture.controller.wakeDate != nil)
        fixture.outcomes.send(signedOut ? .notLoggedIn : .authenticationRequired)
        #expect(fixture.controller.wakeDate == nil)
        #expect(fixture.controller.scheduledDate == nil)
        fixture.controller.handleWake()
        gate.release(fixture.state.read)
        try await eventually { fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.consumeCount == 0)
        #expect(fixture.controller.wakeDate == nil)
        fixture.state.readOverride = nil
        try fixture.outcomes.send(.data(fixture.snapshot()))
        let retry = try #require(fixture.controller.scheduledDate)
        fixture.clock.advance(to: retry)
        try await eventually { fixture.state.consumeCount == 1 }
    }

    @Test func failedAccountReadPreservesExistingPlan() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        fixture.controller.start()
        try await eventually { fixture.controller.scheduledDate != nil }
        let wake = fixture.controller.wakeDate
        let scheduled = fixture.controller.scheduledDate
        fixture.outcomes.send(.initializationFailed)
        await settle()
        #expect(fixture.controller.wakeDate == wake)
        #expect(fixture.controller.scheduledDate == scheduled)
    }

    @Test func confirmedConsumptionAfterSignOutCannotRecreatePlanOrBeConsumedAgain() async throws {
        let fixture = try ResetFixture()
        defer { fixture.stop() }
        let consume = ResetGate<ResetCreditConsumeResult>()
        fixture.state.consumeOverride = { await consume.wait() }
        fixture.controller.start()
        try await eventually { fixture.state.consumeCount == 1 }
        fixture.outcomes.send(.notLoggedIn)
        consume.release(ResetCreditConsumeResult(outcome: .reset, refreshedRead: fixture.state.read))
        try await eventually { fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.successes == 1)
        #expect(fixture.controller.wakeDate == nil)
        fixture.state.consumeOverride = nil
        try fixture.outcomes.send(.data(fixture.snapshot()))
        fixture.controller.handleWake()
        try await eventually { fixture.state.readCount >= 2 && fixture.state.activeAssertions.isEmpty }
        #expect(fixture.state.consumeCount == 1)
    }
}

private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(predicate())
}

private func settle() async {
    for _ in 0 ..< 30 {
        await Task.yield()
    }
}

private final class ResetGate<Value: Sendable> {
    private var waiter: CheckedContinuation<Value, Never>?
    func wait() async -> Value {
        await withCheckedContinuation { waiter = $0 }
    }

    func release(_ value: Value) {
        waiter?.resume(returning: value)
        waiter = nil
    }
}

private final class ResetClock {
    var now: Date
    private var waiters: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    init(now: Date) {
        self.now = now
    }

    func sleep(until date: Date) async throws {
        if date <= now {
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { waiters[id] = (date, $0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }

    func advance(to date: Date) {
        now = date
        for (id, entry) in waiters where entry.0 <= date {
            waiters.removeValue(forKey: id)?.1.resume()
        }
    }
}

private final class ResetState {
    var account = CodexAccount(type: "chatgpt", email: "test@example.com", planType: "plus")
    let candidate: AutoResetCandidate
    var read: AutoResetRead {
        AutoResetRead(accountIdentity: AutoResetIdentity.accountIdentity(for: account), availableCount: 1, candidates: [candidate])
    }

    var error: (any Error)?
    var readOverride: (() async throws -> AutoResetRead)?
    var consumeOverride: (() async throws -> ResetCreditConsumeResult)?
    var readCount = 0
    var consumeCount = 0
    var consumedAccounts: [String] = []
    var successes = 0
    var createdAssertions = 0
    var activeAssertions: Set<Int> = []
    var releasedAssertions: [Int] = []
    init(expiration: Date) {
        candidate = AutoResetCandidate(id: "test-credit", expirationDate: expiration)
    }
}

private final class ResetAssertion: AutoResetWakeActivity {
    let id: Int
    let state: ResetState
    init(state: ResetState) {
        self.state = state
        state.createdAssertions += 1
        id = state.createdAssertions
    }

    func beginPreventingIdleSleep() -> IOReturn {
        state.activeAssertions.insert(id)
        return kIOReturnSuccess
    }

    func endPreventingIdleSleep() -> IOReturn {
        state.activeAssertions.remove(id)
        state.releasedAssertions.append(id)
        return kIOReturnSuccess
    }
}

private final class ResetFixture {
    let preferences: TestPreferences
    let settings: AutoResetSettings
    let controller: AutoResetController
    let outcomes = CurrentValueSubject<CodexFetchOutcome, Never>(.initializationFailed)
    let start = Date(timeIntervalSince1970: 1800000000)
    let clock: ResetClock
    let state: ResetState
    var expiration: Date {
        state.candidate.expirationDate
    }

    init() throws {
        preferences = try TestPreferences()
        settings = AutoResetSettings(defaults: preferences.defaults)
        settings.setLeadTime(.fifteenMinutes)
        settings.setEnabled(true)
        clock = ResetClock(now: start)
        state = ResetState(expiration: start.addingTimeInterval(900))
        let state = state
        let clock = clock
        controller = AutoResetController(settings: settings, outcomes: outcomes.eraseToAnyPublisher(), dependencies: .init(
            read: { _ in
                state.readCount += 1
                if let handler = state.readOverride {
                    return try await handler()
                }
                if let error = state.error {
                    throw error
                }
                return state.read
            },
            consume: { _, account, _ in
                state.consumeCount += 1
                state.consumedAccounts.append(account)
                if let handler = state.consumeOverride {
                    return try await handler()
                }
                return ResetCreditConsumeResult(outcome: .nothingToReset, refreshedRead: state.read)
            },
            setRequested: { _ in }, setWakeDate: { _ in },
            succeeded: { _, _ in state.successes += 1 }, failed: { _, _ in }, refresh: {},
            makeWakeActivity: { ResetAssertion(state: state) }, now: { clock.now }, sleep: { try await clock.sleep(until: $0) }
        ))
    }

    func snapshot(isStale: Bool = false) throws -> CodexQuotaSnapshot {
        let response = try TestFixtures.decode(AccountRateLimitsResponse.self, """
        {"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[
          {"id":"test-credit","status":"available","resetType":"codexRateLimits","expiresAt":\(Int(expiration.timeIntervalSince1970))}
        ]}}
        """)
        return try CodexQuotaSnapshot(accountResponse: AccountReadResponse(account: state.account), rateLimitsResponse: response, isRateLimitsStale: isStale)
    }

    func stop() {
        controller.stop()
        preferences.remove()
    }
}
