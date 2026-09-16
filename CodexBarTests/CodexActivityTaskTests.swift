import Foundation
import Testing

struct CodexActivityTaskTests {
    @Test func anonymousTaskHasNoProtectionIdentityOrPreciseDuration() {
        let task = makeTask(TestFixtures.event(session: nil))
        #expect(task.key.isAnonymous)
        #expect(task.key.activityProtectionIdentifier == nil)
        #expect(!task.snapshot.showsPreciseDuration)
        #expect(task.preciseDuration(until: TestFixtures.now.addingTimeInterval(60)) == nil)
    }

    @Test func taskIdentitySeparatesSessionsTurnsAndAnonymousProjects() {
        #expect(CodexActivityTaskKey(event: TestFixtures.event()).sessionId == "session-a")
        #expect(CodexActivityTaskKey(event: TestFixtures.event(turn: nil)).isSessionOnly)
        let first = CodexActivityTaskKey.turn(session: "ab", turn: "c").activityProtectionIdentifier
        let second = CodexActivityTaskKey.turn(session: "a", turn: "bc").activityProtectionIdentifier
        #expect(first != second)
        #expect(first?.count == 64)
        #expect(first != CodexActivityTaskKey.session("ab").activityProtectionIdentifier)
    }

    @Test func preciseDurationRequiresKnownStartAndNonnegativeInterval() {
        let task = makeTask()
        #expect(task.preciseDuration(until: TestFixtures.now.addingTimeInterval(42)) == 42)
        #expect(task.preciseDuration(until: TestFixtures.now.addingTimeInterval(-1)) == nil)
        var restored = task
        restored.startedAt = nil
        #expect(restored.preciseDuration(until: TestFixtures.now) == nil)
    }

    @Test func mixedEffortIsStickyAndEmptyMetadataIsIgnored() {
        var task = makeTask()
        let sameEffortChanged = task.mergeEffort(" high ")
        #expect(!sameEffortChanged)
        let emptyEffortChanged = task.mergeEffort(" \n")
        #expect(!emptyEffortChanged)
        let differentEffortChanged = task.mergeEffort("low")
        #expect(differentEffortChanged)
        #expect(task.effort == "mixed")
        let mixedEffortChanged = task.mergeEffort("high")
        #expect(!mixedEffortChanged)
    }

    @Test func rolloutProgressDoesNotMoveHookOrderingBarrier() {
        var task = makeTask()
        task.recordProgress(at: TestFixtures.now.addingTimeInterval(30))
        task.recordHookEvent(at: TestFixtures.now.addingTimeInterval(10))
        #expect(task.lastHookEventAt == TestFixtures.now.addingTimeInterval(10))
        #expect(task.lastProgressAt == TestFixtures.now.addingTimeInterval(30))
        #expect(task.progressGeneration == 3)
    }

    @Test func incompleteTailDeadlineAlsoWaitsForLatestHookProgressAndUsesCurrentThreshold() {
        var task = makeTask()
        let observed = TestFixtures.now
        let checked = observed.addingTimeInterval(3600)
        task.recordLifecycleRead(incompleteTail(since: observed), at: checked)
        task.recordProgress(at: observed.addingTimeInterval(1800))
        #expect(task.activityProtectionDeadline(at: checked, inactivityDuration: 3600) == observed.addingTimeInterval(5400))
        #expect(task.activityProtectionDeadline(at: checked, inactivityDuration: 1800) == checked)
        #expect(!task.hasFreshLifecycle(at: checked))
        #expect(task.activityProtectionDeadline(at: checked.addingTimeInterval(5), inactivityDuration: 3600) == nil)
    }

    @Test(arguments: [CodexSessionReadStatus.incomplete, .unavailable, .notFound])
    func losingTailEvidenceRevokesProtectionEligibility(status: CodexSessionReadStatus) {
        var task = makeTask()
        let now = TestFixtures.now.addingTimeInterval(3600)
        task.recordLifecycleRead(incompleteTail(since: TestFixtures.now), at: now)
        #expect(task.activityProtectionDeadline(at: now, inactivityDuration: 3600) == now)
        var lost = incompleteTail(since: TestFixtures.now)
        lost.readStatus = status
        lost.incompleteTailUnchangedSince = nil
        task.recordLifecycleRead(lost, at: now)
        #expect(task.activityProtectionDeadline(at: now, inactivityDuration: 3600) == nil)
        #expect(task.incompleteTailCheckedAt == nil)
    }

    @Test func incompleteTailCannotResumeApprovalButCompleteProgressCan() {
        var task = makeTask()
        _ = task.recordApprovalRequest(from: TestFixtures.event(.permissionRequest))
        let now = TestFixtures.now.addingTimeInterval(3600)
        var state = incompleteTail(since: TestFixtures.now)
        state.lastExecutionProgressAt = now
        let owner = CodexActivityExecutionKey(agentId: nil, turnId: "turn-a")
        task.recordLifecycleRead(state, at: now)
        task.mergeExecutionLifecycle(state, owner: owner)
        #expect(task.state == .waitingApproval)
        #expect(!task.hasFreshLifecycle(at: now))

        state.readStatus = .complete
        state.incompleteTailUnchangedSince = nil
        task.recordLifecycleRead(state, at: now)
        task.mergeExecutionLifecycle(state, owner: owner)
        #expect(task.hasFreshLifecycle(at: now))
        #expect(task.incompleteTailCheckedAt == nil)
        #expect(task.state == .running)
    }

    private func incompleteTail(since date: Date) -> CodexSessionTaskLifecycleState {
        CodexSessionTaskLifecycleState(
            sessionId: "session-a", turnId: "turn-a", startedAt: nil, approvalReviewer: nil, effort: nil,
            lastProgressAt: nil, terminal: nil, readStatus: .incomplete, hasContext: true,
            incompleteTailUnchangedSince: date
        )
    }

    @Test(arguments: ["unchanged", "growth", "unavailable", "stale"])
    func suppressionRevalidatesTailAfterNotification(scenario: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeProtectionMonitor(in: directory, preferences: preferences)
        defer { monitor.stop() }
        let now = Date()
        var task = makeTask(TestFixtures.event(at: now.addingTimeInterval(-7200)))
        task.recordLifecycleRead(incompleteTail(since: now.addingTimeInterval(-3601)), at: now)
        monitor.tasks[task.key] = task
        let candidate = ActivityProtectionCandidate(
            key: task.key, taskID: task.displayID, projectName: task.projectName,
            lastProgressAt: task.lastProgressAt, progressGeneration: task.progressGeneration, inactivityDuration: .oneHour
        )
        #expect(monitor.isActivityProtectionCandidateRelevant(candidate, now: now))

        switch scenario {
        case "growth": task.recordLifecycleRead(incompleteTail(since: now), at: now)
        case "unavailable":
            var state = incompleteTail(since: now)
            state.readStatus = .unavailable
            task.recordLifecycleRead(state, at: now)
        case "stale": task.incompleteTailCheckedAt = now.addingTimeInterval(-5)
        default: break
        }
        monitor.tasks[task.key] = task
        let attemptID = UUID()
        monitor.activityProtectionAttempts[task.key] = ActivityProtectionAttempt(
            id: attemptID, candidate: candidate, markedAt: now, timeoutTask: Task {}
        )
        monitor.finishActivityProtectionAttempt(task.key, attemptID: attemptID, taskID: task.displayID, notificationWasSubmitted: false)
        #expect(monitor.tasks[task.key]?.state == (scenario == "unchanged" ? .suppressed : .running))
        #expect(monitor.activityProtectionAttempts.isEmpty)
    }

    @Test(arguments: [false, true], [ActivityProtectionSettings.InactivityDuration.thirtyMinutes, .oneHour])
    func longerThresholdRestoresTailSuppressionAndUsesNewDeadline(
        expiredObservation: Bool, previousDuration: ActivityProtectionSettings.InactivityDuration
    ) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeProtectionMonitor(in: directory, preferences: preferences)
        defer { monitor.stop() }
        let changedAt = Date()
        let hiddenAfter: TimeInterval = previousDuration == .thirtyMinutes ? 3000 : 3600
        let newDuration: ActivityProtectionSettings.InactivityDuration = previousDuration == .thirtyMinutes ? .oneHour : .twoHours
        let tailStoppedAt = changedAt.addingTimeInterval(-hiddenAfter - 300)
        let hiddenAt = tailStoppedAt.addingTimeInterval(hiddenAfter)
        let newDeadline = tailStoppedAt.addingTimeInterval(newDuration.timeInterval)
        var task = makeTask(TestFixtures.event(at: tailStoppedAt.addingTimeInterval(-3600)))
        let key = task.key
        let identifier = try #require(key.activityProtectionIdentifier)
        task.recordLifecycleRead(incompleteTail(since: tailStoppedAt), at: hiddenAt)
        monitor.tasks[key] = task
        monitor.activityProtectionSettings.setInactivityDuration(previousDuration)
        monitor.reconcileActivityProtection(now: hiddenAt, sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .suppressed)
        #expect(monitor.activityProtectionRecords[identifier] != nil)

        let checkedAt = expiredObservation ? changedAt.addingTimeInterval(-5) : changedAt
        monitor.tasks[key]?.recordLifecycleRead(incompleteTail(since: tailStoppedAt), at: checkedAt)
        monitor.activityProtectionSettings.setInactivityDuration(newDuration)
        monitor.handleActivityProtectionTimingChange()
        #expect(monitor.tasks[key]?.state == .running)
        #expect(monitor.activityProtectionRecords[identifier] == nil)
        #expect(monitor.tasks[key]?.lastProgressAt == task.lastProgressAt)
        #expect(monitor.tasks[key]?.hasFreshLifecycle(at: changedAt) == false)

        monitor.reconcileActivityProtection(now: newDeadline, sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .running)
        monitor.tasks[key]?.recordLifecycleRead(incompleteTail(since: tailStoppedAt), at: newDeadline.addingTimeInterval(-1))
        monitor.reconcileActivityProtection(now: newDeadline.addingTimeInterval(-1), sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .running)
        monitor.reconcileActivityProtection(now: newDeadline, sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .suppressed)
        #expect(monitor.activityProtectionRecords[identifier] != nil)
        monitor.cancelInactivityCheck()
        await monitor.activityProtectionPersistenceTask?.value
    }

    private func makeProtectionMonitor(in directory: TestDirectory, preferences: TestPreferences) throws -> CodexActivityMonitor {
        let monitor = try CodexActivityMonitor(
            codexHookSettings: CodexHookSettings(
                hooksURL: directory.url.appendingPathComponent("hooks.json"),
                codexStatusService: makeStatusService(suiteName: preferences.suite)
            ),
            activityProtectionSettings: ActivityProtectionSettings(defaults: preferences.defaults),
            activityProtectionStateStore: ActivityProtectionStateStore(directoryURL: directory.url)
        )
        monitor.isStarted = true
        monitor.isActivityProtectionEnabled = true
        monitor.isActivitySourceHealthy = true
        monitor.tailReader = HookEventTailReader(eventsDirectoryURL: directory.url) { _ in }
        return monitor
    }

    private nonisolated func makeStatusService(suiteName: String) throws -> CodexStatusService {
        try CodexStatusService(defaults: #require(UserDefaults(suiteName: suiteName)))
    }

    @Test func subagentCountDeduplicatesAndRejectsOlderEvents() {
        var task = makeTask()
        #expect(task.snapshot.activeSubagentCount == 0)
        task.recordSubagentActivity(agentId: "agent", isStarting: true, at: TestFixtures.now)
        task.recordSubagentActivity(agentId: "agent", isStarting: true, at: TestFixtures.now)
        #expect(task.snapshot.activeSubagentCount == 1)
        task.recordSubagentActivity(agentId: "agent", isStarting: false, at: TestFixtures.now.addingTimeInterval(2))
        task.recordSubagentActivity(agentId: "agent", isStarting: true, at: TestFixtures.now.addingTimeInterval(1))
        #expect(task.snapshot.activeSubagentCount == 0)
    }

    @Test func missingSubagentIdentityAndUnmatchedStopMakeCountUnavailable() {
        var missing = makeTask()
        missing.recordSubagentActivity(agentId: nil, isStarting: true, at: TestFixtures.now)
        #expect(missing.snapshot.activeSubagentCount == nil)
        var unmatched = makeTask()
        unmatched.recordSubagentActivity(agentId: "unknown", isStarting: false, at: TestFixtures.now)
        #expect(unmatched.snapshot.activeSubagentCount == nil)
    }

    @Test func onlyUserApprovalTransitionsToWaiting() {
        for reviewer in [CodexApprovalReviewer.user, .autoReview, .guardianSubagent] {
            var task = makeTask(TestFixtures.event(reviewer: reviewer))
            let transitioned = task.recordApprovalRequest(from: TestFixtures.event(.permissionRequest, reviewer: reviewer))
            #expect(transitioned == (reviewer == .user))
            #expect(task.state == (reviewer == .user ? .waitingApproval : .running))
        }
    }

    @Test func unknownApprovalWaitsForContextOfSameExecution() {
        var task = makeTask(TestFixtures.event(reviewer: nil))
        let requestedWaiting = task.recordApprovalRequest(from: TestFixtures.event(.permissionRequest, reviewer: nil))
        #expect(!requestedWaiting)
        let otherOwner = CodexActivityExecutionKey(agentId: "other", turnId: "turn-a")
        task.mergeApprovalContext(reviewer: .user, observedAt: TestFixtures.now, owner: otherOwner)
        let resolvedOtherExecution = task.resolvePendingApprovals()
        #expect(!resolvedOtherExecution)
        #expect(task.state == .running)
        let owner = CodexActivityExecutionKey(agentId: nil, turnId: "turn-a")
        task.mergeApprovalContext(reviewer: .user, observedAt: TestFixtures.now, owner: owner)
        let resolvedOwner = task.resolvePendingApprovals()
        #expect(resolvedOwner)
        #expect(task.state == .waitingApproval)
    }

    @Test func mainProgressCannotDismissSubagentApproval() {
        var task = makeTask()
        let approval = TestFixtures.event(.permissionRequest, agent: "agent", origin: .auxiliary)
        let enteredWaiting = task.recordApprovalRequest(from: approval)
        #expect(enteredWaiting)
        task.resumeExecution(from: TestFixtures.event(.postToolUse, at: TestFixtures.now.addingTimeInterval(1)), latestEvent: .toolFinished)
        #expect(task.state == .waitingApproval)
        task.resumeExecution(from: TestFixtures.event(.postToolUse, at: TestFixtures.now.addingTimeInterval(2), agent: "agent", origin: .auxiliary), latestEvent: .toolFinished)
        #expect(task.state == .running)
    }

    @Test func resolvingOneApprovalKeepsOtherExecutionWaiting() {
        var task = makeTask()
        let mainEnteredWaiting = task.recordApprovalRequest(from: TestFixtures.event(.permissionRequest))
        #expect(mainEnteredWaiting)
        let agentRequest = TestFixtures.event(.permissionRequest, at: TestFixtures.now.addingTimeInterval(1), agent: "agent", origin: .auxiliary)
        let agentEnteredWaiting = task.recordApprovalRequest(from: agentRequest)
        #expect(!agentEnteredWaiting)
        task.finishExecution(CodexActivityExecutionKey(agentId: nil, turnId: "turn-a"), at: TestFixtures.now.addingTimeInterval(2))
        #expect(task.state == .waitingApproval)
        #expect(task.displayedApproval?.requestedAt == TestFixtures.now.addingTimeInterval(1))
        task.finishExecution(CodexActivityExecutionKey(agentId: "agent", turnId: "turn-a"), at: TestFixtures.now.addingTimeInterval(3))
        #expect(task.state == .running)
    }

    @Test func lateApprovalDoesNotUndoConfirmedExecutionProgress() {
        var task = makeTask()
        let progress = TestFixtures.now.addingTimeInterval(2)
        task.resumeExecution(from: TestFixtures.event(.postToolUse, at: progress), latestEvent: .toolFinished)
        let lateRequestChanged = task.recordApprovalRequest(from: TestFixtures.event(.permissionRequest))
        #expect(!lateRequestChanged)
        #expect(task.state == .running)
        task.finishExecution(CodexActivityExecutionKey(agentId: nil, turnId: "turn-a"), at: progress)
        #expect(!task.acceptsExecutionEvent(TestFixtures.event(.preToolUse, at: progress.addingTimeInterval(1))))
    }

    @Test func equalTimestampRolloutProgressDoesNotDismissApproval() {
        var task = makeTask()
        _ = task.recordApprovalRequest(from: TestFixtures.event(.permissionRequest))
        let owner = CodexActivityExecutionKey(agentId: nil, turnId: "turn-a")
        task.mergeExecutionProgress(at: TestFixtures.now, owner: owner)
        #expect(task.state == .waitingApproval)
        task.mergeExecutionProgress(at: TestFixtures.now.addingTimeInterval(0.001), owner: owner)
        #expect(task.state == .running)
    }

    private func makeTask(_ event: WorkflowHookEvent = TestFixtures.event()) -> CodexActivityTask {
        CodexActivityTask(
            displayID: UUID(), key: CodexActivityTaskKey(event: event), event: event,
            state: .running, latestEvent: .promptSubmitted, startedAt: event.timestamp, progressGeneration: 1
        )
    }
}
