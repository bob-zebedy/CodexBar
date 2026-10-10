import Foundation
import Testing

struct ActivityTaskTests {
    @Test(arguments: [ActivityEventKind.turnCompleted, .turnAborted])
    func terminalSnapshotPreservesTaskIdentityAcrossTurns(terminal: ActivityEventKind) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        let now = Date()
        monitor.consume(.live([TestFixtures.event(at: now)]))
        let firstID = try #require(monitor.tasks.values.first?.snapshot.id)
        monitor.consume(.live([TestFixtures.event(terminal, at: now.addingTimeInterval(1))]))
        if terminal == .turnCompleted {
            let completion = try #require(monitor.completions.first)
            #expect(completion.taskID == firstID)
            #expect(completion.id != firstID)
        } else {
            let termination = try #require(monitor.terminations.first)
            #expect(termination.taskID == firstID)
            #expect(termination.id != firstID)
        }
        monitor.consume(.live([TestFixtures.event(at: now.addingTimeInterval(2), turn: "turn-b")]))
        let nextID = try #require(monitor.tasks.values.first?.snapshot.id)
        #expect(nextID != firstID)
    }

    @Test(arguments: ["thread", "turn", "both", "empty-thread", "empty-turn"], [false, true])
    func incompleteIdentityCannotCreateOrChangeTasks(missing: String, snapshot: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        let now = Date()
        let thread: String? = switch missing {
        case "thread", "both": nil
        case "empty-thread": ""
        default: "thread-a"
        }
        let turn: String? = switch missing {
        case "turn", "both": nil
        case "empty-turn": ""
        default: "turn-a"
        }
        let events = ActivityEventKind.allCases.map {
            TestFixtures.event($0, at: now.addingTimeInterval(1), thread: thread, turn: turn)
        }
        monitor.consume(snapshot ? .snapshotEvents(events) : .live(events))
        #expect(monitor.tasks.isEmpty)
        #expect(monitor.completions.isEmpty)
        #expect(monitor.terminations.isEmpty)
        monitor.consume(.live([TestFixtures.event(at: now)]))
        let original = try #require(monitor.tasks.values.first?.snapshot)
        monitor.consume(snapshot ? .snapshotEvents(events) : .live(events))
        #expect(monitor.tasks.count == 1)
        #expect(monitor.tasks.values.first?.snapshot == original)
        #expect(monitor.completions.isEmpty)
        #expect(monitor.terminations.isEmpty)
        #expect(monitor.pendingTerminalTasks.isEmpty)
        #expect(monitor.terminalTokenUsageRequests.isEmpty)
    }

    @Test func lateTerminalOnlyCompletesItsOwnTurnOnce() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        let now = Date()
        monitor.consume(.live([TestFixtures.event(at: now)]))
        monitor.consume(.live([TestFixtures.event(at: now.addingTimeInterval(1), turn: "turn-b")]))
        let terminal = TestFixtures.event(.turnCompleted, at: now.addingTimeInterval(2))
        monitor.consume(.live([terminal, terminal]))
        #expect(Set(monitor.tasks.keys) == [.init(thread: "thread-a", turn: "turn-b")])
        #expect(monitor.pendingTerminalTasks.isEmpty)
        #expect(monitor.completions.count == 1)
        #expect(monitor.terminations.isEmpty)
    }

    @Test func dailySnapshotDoesNotEnterConnectionRecovery() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        let presentation = monitor.sourcePresentation
        monitor.consume(.snapshotEvents([TestFixtures.event(at: Date())]))
        #expect(monitor.tasks.count == 1)
        #expect(monitor.sourcePresentation == presentation)
        #expect(!monitor.isBootstrapping)
    }

    @Test func guardianIsFilteredAtEntryAndAutoReviewedUserTaskRemainsVisible() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        let now = Date()
        for kind in [ActivityEventKind.turnStarted, .toolStarted, .approvalRequested, .turnCompleted, .turnAborted] {
            monitor.consume(.live([TestFixtures.event(kind, at: now, origin: .autoReview)]))
        }
        #expect(monitor.tasks.isEmpty)
        #expect(monitor.pendingTerminalTasks.isEmpty)
        #expect(monitor.completions.isEmpty)
        #expect(monitor.terminations.isEmpty)
        #expect(monitor.recentlyEndedTaskAt.isEmpty)
        monitor.consume(.live([TestFixtures.event(at: now)]))
        #expect(monitor.tasks.count == 1)
    }

    @Test func subagentLinkRetentionDoesNotDependOnIdentityOrRefreshTime() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        let root = ActivityTaskKey(thread: "root", turn: "root-turn")
        let child = ActivityTurnReference(threadID: "child", turnID: "child-turn")
        let expired = Date().addingTimeInterval(-ActivityRetention.window - 1)
        monitor.subagentTurnLinks[child] = (root, expired)
        var state = SessionLifecycleState(
            requestedThreadID: "child", turnID: "child-turn", startedAt: nil,
            effort: nil, lastProgressAt: nil, terminal: nil
        )
        state.rootThreadID = "root"
        state.rootTurnID = "root-turn"
        state.parentThreadID = "root"
        _ = monitor.applySubagentLifecycle(state, terminalOnly: false)
        #expect(monitor.subagentTurnLinks[child]?.retainedAt == expired)
        _ = monitor.subagentLifecycleReferences()
        #expect(monitor.subagentTurnLinks[child] == nil)
    }

    @Test func incompleteSubagentRootCannotBeGuessedFromQueuedEventsOrPreviousLink() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        let event = TestFixtures.event(.toolStarted, agent: "child", origin: .auxiliary)
        #expect(monitor.deferUnassociatedSubagentEvent(event, source: .live))
        var state = SessionLifecycleState(
            requestedThreadID: "child", turnID: "turn-a", startedAt: TestFixtures.now,
            effort: nil, lastProgressAt: nil, terminal: nil,
            rootTurnID: "turn-a", parentThreadID: "thread-a"
        )
        let reference = ActivityTurnReference(threadID: "child", turnID: "turn-a")
        #expect(!monitor.applySubagentLifecycle(state, terminalOnly: false))
        #expect(monitor.subagentTurnLinks[reference] == nil)
        monitor.subagentTurnLinks[reference] = (.init(thread: "thread-a", turn: "turn-a"), TestFixtures.now)
        #expect(!monitor.applySubagentLifecycle(state, terminalOnly: false))
        state.rootThreadID = "different-thread"
        #expect(!monitor.applySubagentLifecycle(state, terminalOnly: false))
    }

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

    @Test func onlyPendingApprovalExposesNotificationAction() {
        var task = makeTask(TestFixtures.event(.toolStarted))
        #expect(task.snapshot.approvalActionText == nil)
        let event = ActivityRecord(
            timestamp: TestFixtures.now.addingTimeInterval(1), name: ActivityEventKind.toolStarted.rawValue,
            origin: .main, cwd: nil, toolName: nil, model: nil, effort: nil,
            threadID: "thread-a", turnID: "turn-a", agentID: nil
        )
        var nameless = event
        nameless.context = ActivityContext(method: "item/started", threadID: "thread-a", itemType: "fileChange")
        task.mergeMetadata(from: nameless)
        #expect(task.snapshot.approvalActionText == nil)

        var approval = ActivityRecord(
            timestamp: TestFixtures.now.addingTimeInterval(2), name: ActivityEventKind.approvalRequested.rawValue,
            origin: .main, cwd: nil, toolName: nil, model: nil, effort: nil,
            threadID: "thread-a", turnID: "turn-a", agentID: nil
        )
        approval.context = ActivityContext(method: "item/commandExecution/requestApproval", threadID: "thread-a", itemType: "commandExecution")
        task.mergeMetadata(from: approval)
        let enteredWaiting = task.recordApprovalRequest(from: approval)
        #expect(enteredWaiting)
        #expect(task.snapshot.approvalActionText == String(localized: "activity.action.command"))
        task.resumeExecution(from: TestFixtures.event(.toolStarted, at: TestFixtures.now.addingTimeInterval(3)))
        #expect(task.snapshot.approvalActionText == String(localized: "activity.action.command"))
        var lifecycle = healthyLifecycle(startedAt: TestFixtures.now)
        lifecycle.isWaitingApproval = false
        lifecycle.approvalChangedAt = TestFixtures.now.addingTimeInterval(4)
        task.mergeExecutionLifecycle(lifecycle, owner: ActivityExecutionKey(agentID: nil, turnID: "turn-a"))
        #expect(task.snapshot.approvalActionText == nil)
    }

    @Test(arguments: [nil, [], ["read"]] as [[String]?])
    func approvalActionsDoNotFallBackToAnotherCommandsActions(_ actions: [String]?) {
        var task = makeTask()
        var earlier = TestFixtures.event(.toolStarted)
        earlier.context = ActivityContext(method: "item/started", threadID: "thread-a", itemType: "commandExecution")
        task.mergeMetadata(from: earlier)
        var approval = ActivityRecord(
            timestamp: TestFixtures.now.addingTimeInterval(1), name: ActivityEventKind.approvalRequested.rawValue,
            origin: .main, cwd: nil, toolName: nil, commandActionTypes: actions, model: nil, effort: nil,
            threadID: "thread-a", turnID: "turn-a", agentID: nil
        )
        approval.context = ActivityContext(method: "item/commandExecution/requestApproval", threadID: "thread-a", itemType: "commandExecution")
        let enteredWaiting = task.recordApprovalRequest(from: approval)
        #expect(enteredWaiting)
        #expect(task.displayedApproval?.commandActionTypes == actions)
        let expected = actions?.isEmpty == false
            ? String(localized: "activity.live.actions-read")
            : String(localized: "activity.action.command")
        #expect(task.snapshot.approvalActionText == expected)
    }

    @Test func unknownSourceCannotReuseAnotherEventsOrigin() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        monitor.isActivitySourceHealthy = true
        monitor.consume(.live([TestFixtures.event(at: Date())]))
        monitor.consume(.live([TestFixtures.event(.turnCompleted, at: Date(), origin: .unknown)]))
        #expect(monitor.tasks.count == 1)
        #expect(monitor.completions.isEmpty)
    }

    @Test func taskIdentityRequiresSessionAndTurnAndSeparatesTheirBoundaries() {
        #expect(ActivityTaskKey(event: TestFixtures.event())?.threadID == "thread-a")
        #expect(ActivityTaskKey(event: TestFixtures.event(turn: nil)) == nil)
        #expect(ActivityTaskKey(event: TestFixtures.event(thread: nil)) == nil)
        let first = ActivityTaskKey(thread: "ab", turn: "c").protectionIdentifier
        let second = ActivityTaskKey(thread: "a", turn: "bc").protectionIdentifier
        #expect(first != second)
        #expect(first.count == 64)
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
        task.recordProgress(at: TestFixtures.now.addingTimeInterval(10))
        #expect(task.acceptsExecutionEvent(TestFixtures.event(.toolCompleted, at: TestFixtures.now.addingTimeInterval(10))))
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

    @Test func onlyCompleteAuthoritativeStateCanResumeApproval() {
        var task = makeTask()
        _ = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        let now = TestFixtures.now.addingTimeInterval(3600)
        var state = healthyLifecycle()
        state.readStatus = .unavailable
        state.lastProgressAt = now
        state.isWaitingApproval = false
        state.approvalChangedAt = now
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
            requestedThreadID: "thread-a", turnID: "turn-a", startedAt: startedAt, effort: nil,
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
        let identifier = key.protectionIdentifier
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
        monitor.protectionLoadState = .available
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
        #expect(task.snapshot.activeSubagentCount == nil)
        task.hasCompleteSubagentCoverage = true
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
        missing.hasCompleteSubagentCoverage = true
        missing.recordSubagentActivity(agentID: nil, isStarting: true, at: TestFixtures.now)
        #expect(missing.snapshot.activeSubagentCount == nil)
        var unmatched = makeTask()
        unmatched.hasCompleteSubagentCoverage = true
        unmatched.recordSubagentActivity(agentID: "unknown", isStarting: false, at: TestFixtures.now)
        #expect(unmatched.snapshot.activeSubagentCount == nil)
    }

    @Test func approvalRequestImmediatelyWaitsWithoutReviewerContext() {
        var task = makeTask(TestFixtures.event())
        let request = TestFixtures.event(.approvalRequested)
        let enteredWaiting = task.recordApprovalRequest(from: request)
        #expect(enteredWaiting)
        #expect(task.state == .waitingApproval)
        let repeated = task.recordApprovalRequest(from: request)
        #expect(!repeated)
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
        #expect(task.state == .waitingApproval)
        task.finishExecution(ActivityExecutionKey(agentID: "agent", turnID: "turn-a"), at: TestFixtures.now.addingTimeInterval(3))
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

    @Test func anotherToolsProgressDoesNotInvalidateAnApprovalRequest() {
        var task = makeTask()
        let progress = TestFixtures.now.addingTimeInterval(2)
        task.resumeExecution(from: TestFixtures.event(.toolCompleted, at: progress))
        let lateRequestChanged = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        #expect(lateRequestChanged)
        #expect(task.state == .waitingApproval)
        task.finishExecution(ActivityExecutionKey(agentID: nil, turnID: "turn-a"), at: progress)
        #expect(!task.acceptsExecutionEvent(TestFixtures.event(.toolStarted, at: progress.addingTimeInterval(1))))
    }

    @Test func executionProgressDoesNotDismissApproval() {
        var task = makeTask()
        _ = task.recordApprovalRequest(from: TestFixtures.event(.approvalRequested))
        task.resumeExecution(from: TestFixtures.event(.toolCompleted))
        #expect(task.state == .waitingApproval)
        task.resumeExecution(from: TestFixtures.event(.toolCompleted, at: TestFixtures.now.addingTimeInterval(0.001)))
        #expect(task.state == .waitingApproval)
    }

    private func makeTask(_ event: ActivityRecord = TestFixtures.event()) -> ActivityTask {
        ActivityTask(
            displayID: UUID(), key: ActivityTaskKey(event: event)!, event: event,
            state: .running, startedAt: event.timestamp, progressGeneration: 1
        )
    }
}
