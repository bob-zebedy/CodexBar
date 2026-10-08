import Foundation
import Testing

struct ActivityTaskTests {
    @Test(arguments: [-172800.0, 0.5, 2.0])
    func lifecycleBackfillsMissingStartWithTimestampTolerance(offset: TimeInterval) {
        var task = makeTask()
        task.startedAt = nil
        let start = task.lastActivityAt.addingTimeInterval(offset)
        let state = healthyLifecycle(startedAt: start)
        _ = ActivityMonitor.mergeLifecycleBackfill(from: state, into: &task)
        #expect(task.startedAt == (offset <= 1 ? start : nil))
        if task.startedAt != nil {
            let earlier = healthyLifecycle(startedAt: start.addingTimeInterval(-60))
            _ = ActivityMonitor.mergeLifecycleBackfill(from: earlier, into: &task)
            #expect(task.startedAt == start)
        }
    }

    @Test func namelessToolAndApprovalDoNotReusePreviousToolName() {
        var task = makeTask(TestFixtures.event(.toolStarted))
        #expect(task.snapshot.toolName == "exec_command")
        let event = ActivityRecord(
            timestamp: TestFixtures.now.addingTimeInterval(1), name: ActivityEventKind.toolStarted.rawValue,
            origin: .main, cwd: nil, tool: nil, model: nil, effort: nil,
            approvalReviewer: .user, sessionID: "session-a", turnID: "turn-a", agentID: nil
        )
        var nameless = event
        nameless.source = AppServerEventSource(method: "item/started", threadID: "session-a", itemType: "fileChange")
        task.mergeMetadata(from: nameless)
        #expect(task.snapshot.toolName == nil)
        #expect(task.snapshot.toolDisplayName == String(localized: "activity.action.edit-files"))

        var approval = ActivityRecord(
            timestamp: TestFixtures.now.addingTimeInterval(2), name: ActivityEventKind.approvalRequested.rawValue,
            origin: .main, cwd: nil, tool: nil, model: nil, effort: nil,
            approvalReviewer: .user, sessionID: "session-a", turnID: "turn-a", agentID: nil
        )
        approval.source = AppServerEventSource(method: "item/commandExecution/requestApproval", threadID: "session-a", itemType: "commandExecution")
        task.mergeMetadata(from: approval)
        let enteredWaiting = task.recordApprovalRequest(from: approval)
        #expect(enteredWaiting)
        #expect(task.snapshot.toolName == nil)
        #expect(task.snapshot.toolDisplayName == String(localized: "activity.action.command"))
    }

    @Test func anonymousTaskHasNoProtectionIdentityOrPreciseDuration() {
        let task = makeTask(TestFixtures.event(session: nil))
        #expect(task.key.isAnonymous)
        #expect(task.key.protectionIdentifier == nil)
        #expect(!task.snapshot.showsPreciseDuration)
        #expect(task.preciseDuration(until: TestFixtures.now.addingTimeInterval(60)) == nil)
    }

    @Test func taskIdentitySeparatesSessionsTurnsAndAnonymousProjects() {
        #expect(ActivityTaskKey(event: TestFixtures.event()).sessionID == "session-a")
        #expect(ActivityTaskKey(event: TestFixtures.event(turn: nil)).isSessionOnly)
        let first = ActivityTaskKey.turn(session: "ab", turn: "c").protectionIdentifier
        let second = ActivityTaskKey.turn(session: "a", turn: "bc").protectionIdentifier
        #expect(first != second)
        #expect(first?.count == 64)
        #expect(first != ActivityTaskKey.session("ab").protectionIdentifier)
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

    @Test func executionProgressDoesNotMoveEventOrderingBarrier() {
        var task = makeTask()
        task.recordProgress(at: TestFixtures.now.addingTimeInterval(30))
        task.recordEvent(at: TestFixtures.now.addingTimeInterval(10))
        #expect(task.lastEventAt == TestFixtures.now.addingTimeInterval(10))
        #expect(task.lastProgressAt == TestFixtures.now.addingTimeInterval(30))
        #expect(task.progressGeneration == 3)
    }

    @Test func protectionDeadlineUsesLatestProgressAndCurrentThreshold() {
        var task = makeTask()
        let observed = TestFixtures.now
        let checked = observed.addingTimeInterval(3600)
        task.recordLifecycleRead(healthyLifecycle(), at: checked)
        task.recordProgress(at: observed.addingTimeInterval(1800))
        #expect(task.protectionDeadline(at: checked, inactivityDuration: 3600) == observed.addingTimeInterval(5400))
        #expect(task.protectionDeadline(at: checked, inactivityDuration: 1800) == checked)
        #expect(task.hasFreshLifecycle(at: checked))
        #expect(task.protectionDeadline(at: checked.addingTimeInterval(5), inactivityDuration: 3600) == nil)
    }

    @Test(arguments: [SessionReadStatus.unavailable, .notFound])
    func losingLifecycleCoverageRevokesProtectionEligibility(status: SessionReadStatus) {
        var task = makeTask()
        let now = TestFixtures.now.addingTimeInterval(3600)
        task.recordLifecycleRead(healthyLifecycle(), at: now)
        #expect(task.protectionDeadline(at: now, inactivityDuration: 3600) == now)
        var lost = healthyLifecycle()
        lost.readStatus = status
        task.recordLifecycleRead(lost, at: now)
        #expect(task.protectionDeadline(at: now, inactivityDuration: 3600) == nil)
    }

    @Test func unavailableSourceCannotResumeApprovalButCompleteProgressCan() {
        var task = makeTask()
        _ = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        let now = TestFixtures.now.addingTimeInterval(3600)
        var state = healthyLifecycle()
        state.readStatus = .unavailable
        state.lastExecutionProgressAt = now
        let owner = ActivityExecutionKey(agentID: nil, turnID: "turn-a")
        task.recordLifecycleRead(state, at: now)
        task.mergeExecutionLifecycle(state, owner: owner)
        #expect(task.state == .waitingApproval)
        #expect(!task.hasFreshLifecycle(at: now))

        state.readStatus = .complete
        task.recordLifecycleRead(state, at: now)
        task.mergeExecutionLifecycle(state, owner: owner)
        #expect(task.hasFreshLifecycle(at: now))
        #expect(task.state == .running)
    }

    private func healthyLifecycle(startedAt: Date? = nil) -> SessionLifecycleState {
        SessionLifecycleState(
            requestedThreadID: "session-a", turnID: "turn-a", startedAt: startedAt, approvalReviewer: nil, effort: nil,
            lastProgressAt: nil, terminal: nil, readStatus: .complete
        )
    }

    @Test(arguments: ["unchanged", "growth", "unavailable", "stale"])
    func suppressionRevalidatesCoverageAfterNotification(scenario: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeProtectionMonitor(in: directory, preferences: preferences)
        defer { monitor.stop() }
        let now = Date()
        var task = makeTask(TestFixtures.event(at: now.addingTimeInterval(-7200)))
        task.recordLifecycleRead(healthyLifecycle(), at: now)
        monitor.tasks[task.key] = task
        let candidate = ProtectionCandidate(
            key: task.key, taskID: task.displayID, projectName: task.projectName,
            lastProgressAt: task.lastProgressAt, progressGeneration: task.progressGeneration, inactivityDuration: .oneHour
        )
        #expect(monitor.isProtectionCandidateRelevant(candidate, now: now))

        switch scenario {
        case "growth": task.recordProgress(at: now)
        case "unavailable":
            var state = healthyLifecycle()
            state.readStatus = .unavailable
            task.recordLifecycleRead(state, at: now)
        case "stale": task.lifecycleCoverageCheckedAt = now.addingTimeInterval(-5)
        default: break
        }
        monitor.tasks[task.key] = task
        let attemptID = UUID()
        monitor.protectionAttempts[task.key] = ProtectionAttempt(
            id: attemptID, candidate: candidate, markedAt: now, timeoutTask: Task {}
        )
        monitor.finishProtectionAttempt(task.key, attemptID: attemptID, taskID: task.displayID, notificationWasSubmitted: false)
        #expect(monitor.tasks[task.key]?.state == (scenario == "unchanged" ? .suppressed : .running))
        #expect(monitor.protectionAttempts.isEmpty)
    }

    @Test(arguments: [false, true], [ProtectionSettings.InactivityDuration.thirtyMinutes, .oneHour])
    func longerThresholdRestoresSuppressionAndUsesNewDeadline(
        expiredObservation: Bool, previousDuration: ProtectionSettings.InactivityDuration
    ) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = try makeProtectionMonitor(in: directory, preferences: preferences)
        defer { monitor.stop() }
        let changedAt = Date()
        let hiddenAfter: TimeInterval = previousDuration == .thirtyMinutes ? 3000 : 3600
        let newDuration: ProtectionSettings.InactivityDuration = previousDuration == .thirtyMinutes ? .oneHour : .twoHours
        let progressStoppedAt = changedAt.addingTimeInterval(-hiddenAfter - 300)
        let hiddenAt = progressStoppedAt.addingTimeInterval(hiddenAfter)
        let newDeadline = progressStoppedAt.addingTimeInterval(newDuration.timeInterval)
        var task = makeTask(TestFixtures.event(at: progressStoppedAt))
        let key = task.key
        let identifier = try #require(key.protectionIdentifier)
        task.recordLifecycleRead(healthyLifecycle(), at: hiddenAt)
        monitor.tasks[key] = task
        monitor.protectionSettings.setInactivityDuration(previousDuration)
        monitor.reconcileProtection(now: hiddenAt, sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .suppressed)
        #expect(monitor.protectionRecords[identifier] != nil)

        let checkedAt = expiredObservation ? changedAt.addingTimeInterval(-5) : changedAt
        monitor.tasks[key]?.recordLifecycleRead(healthyLifecycle(), at: checkedAt)
        monitor.protectionSettings.setInactivityDuration(newDuration)
        monitor.handleProtectionTimingChange()
        #expect(monitor.tasks[key]?.state == .running)
        #expect(monitor.protectionRecords[identifier] == nil)
        #expect(monitor.tasks[key]?.lastProgressAt == task.lastProgressAt)
        #expect(monitor.tasks[key]?.hasFreshLifecycle(at: changedAt) == !expiredObservation)

        monitor.reconcileProtection(now: newDeadline, sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .running)
        monitor.tasks[key]?.recordLifecycleRead(healthyLifecycle(), at: newDeadline.addingTimeInterval(-1))
        monitor.reconcileProtection(now: newDeadline.addingTimeInterval(-1), sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .running)
        monitor.reconcileProtection(now: newDeadline, sendsNotification: false)
        #expect(monitor.tasks[key]?.state == .suppressed)
        #expect(monitor.protectionRecords[identifier] != nil)
        monitor.cancelInactivityCheck()
        await monitor.protectionPersistenceTask?.value
    }

    private func makeProtectionMonitor(in directory: TestDirectory, preferences: TestPreferences) throws -> ActivityMonitor {
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url)
        )
        monitor.isStarted = true
        monitor.isProtectionEnabled = true
        monitor.isActivitySourceHealthy = true
        monitor.activityReader = AppServerActivityReader(lifecycleCache: SessionLifecycleCache(), socketURL: directory.url.appendingPathComponent("test.sock")) { _ in }
        return monitor
    }

    private nonisolated func makeStatusService(suiteName: String) -> CodexStatusService {
        CodexStatusService(socketURL: URL(fileURLWithPath: "/tmp/\(suiteName).sock"))
    }

    @Test func subagentCountDeduplicatesAndRejectsOlderEvents() {
        var task = makeTask()
        #expect(task.snapshot.activeSubagentCount == 0)
        task.recordSubagentActivity(agentID: "agent", isStarting: true, at: TestFixtures.now)
        task.recordSubagentActivity(agentID: "agent", isStarting: true, at: TestFixtures.now)
        #expect(task.snapshot.activeSubagentCount == 1)
        task.recordSubagentActivity(agentID: "agent", isStarting: false, at: TestFixtures.now.addingTimeInterval(2))
        task.recordSubagentActivity(agentID: "agent", isStarting: true, at: TestFixtures.now.addingTimeInterval(1))
        #expect(task.snapshot.activeSubagentCount == 0)
    }

    @Test func missingSubagentIdentityAndUnmatchedStopMakeCountUnavailable() {
        var missing = makeTask()
        missing.recordSubagentActivity(agentID: nil, isStarting: true, at: TestFixtures.now)
        #expect(missing.snapshot.activeSubagentCount == nil)
        var unmatched = makeTask()
        unmatched.recordSubagentActivity(agentID: "unknown", isStarting: false, at: TestFixtures.now)
        #expect(unmatched.snapshot.activeSubagentCount == nil)
    }

    @Test func onlyUserApprovalTransitionsToWaiting() {
        for reviewer in [ApprovalReviewer.user, .autoReview, .guardianSubagent] {
            var task = makeTask(TestFixtures.event(reviewer: reviewer))
            let transitioned = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested, reviewer: reviewer))
            #expect(transitioned == (reviewer == .user))
            #expect(task.state == (reviewer == .user ? .waitingApproval : .running))
        }
    }

    @Test func unknownApprovalWaitsForContextOfSameExecution() {
        var task = makeTask(TestFixtures.event(reviewer: nil))
        let requestedWaiting = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested, reviewer: nil))
        #expect(!requestedWaiting)
        let otherOwner = ActivityExecutionKey(agentID: "other", turnID: "turn-a")
        task.mergeApprovalContext(reviewer: .user, observedAt: TestFixtures.now, owner: otherOwner)
        let resolvedOtherExecution = task.resolvePendingApprovals()
        #expect(!resolvedOtherExecution)
        #expect(task.state == .running)
        let owner = ActivityExecutionKey(agentID: nil, turnID: "turn-a")
        task.mergeApprovalContext(reviewer: .user, observedAt: TestFixtures.now, owner: owner)
        let resolvedOwner = task.resolvePendingApprovals()
        #expect(resolvedOwner)
        #expect(task.state == .waitingApproval)
    }

    @Test func mainProgressCannotDismissSubagentApproval() {
        var task = makeTask()
        let approval = TestFixtures.event(.approvalRequested, agent: "agent", origin: .auxiliary)
        let enteredWaiting = task.recordApprovalRequest(from: approval)
        #expect(enteredWaiting)
        task.resumeExecution(from: TestFixtures.event(.toolCompleted, at: TestFixtures.now.addingTimeInterval(1)))
        #expect(task.state == .waitingApproval)
        task.resumeExecution(from: TestFixtures.event(.toolCompleted, at: TestFixtures.now.addingTimeInterval(2), agent: "agent", origin: .auxiliary))
        #expect(task.state == .running)
    }

    @Test func resolvingOneApprovalKeepsOtherExecutionWaiting() {
        var task = makeTask()
        let mainEnteredWaiting = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        #expect(mainEnteredWaiting)
        let agentRequest = TestFixtures.event(.approvalRequested, at: TestFixtures.now.addingTimeInterval(1), agent: "agent", origin: .auxiliary)
        let agentEnteredWaiting = task.recordApprovalRequest(from: agentRequest)
        #expect(!agentEnteredWaiting)
        task.finishExecution(ActivityExecutionKey(agentID: nil, turnID: "turn-a"), at: TestFixtures.now.addingTimeInterval(2))
        #expect(task.state == .waitingApproval)
        #expect(task.displayedApproval?.requestedAt == TestFixtures.now.addingTimeInterval(1))
        task.finishExecution(ActivityExecutionKey(agentID: "agent", turnID: "turn-a"), at: TestFixtures.now.addingTimeInterval(3))
        #expect(task.state == .running)
    }

    @Test func lateApprovalDoesNotUndoConfirmedExecutionProgress() {
        var task = makeTask()
        let progress = TestFixtures.now.addingTimeInterval(2)
        task.resumeExecution(from: TestFixtures.event(.toolCompleted, at: progress))
        let lateRequestChanged = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        #expect(!lateRequestChanged)
        #expect(task.state == .running)
        task.finishExecution(ActivityExecutionKey(agentID: nil, turnID: "turn-a"), at: progress)
        #expect(!task.acceptsExecutionEvent(TestFixtures.event(.toolStarted, at: progress.addingTimeInterval(1))))
    }

    @Test func equalTimestampExecutionProgressDoesNotDismissApproval() {
        var task = makeTask()
        _ = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        let owner = ActivityExecutionKey(agentID: nil, turnID: "turn-a")
        task.mergeExecutionProgress(at: TestFixtures.now, owner: owner)
        #expect(task.state == .waitingApproval)
        task.mergeExecutionProgress(at: TestFixtures.now.addingTimeInterval(0.001), owner: owner)
        #expect(task.state == .running)
    }

    private func makeTask(_ event: ActivityRecord = TestFixtures.event()) -> ActivityTask {
        ActivityTask(
            displayID: UUID(), key: ActivityTaskKey(event: event), event: event,
            state: .running, startedAt: event.timestamp, progressGeneration: 1
        )
    }
}
