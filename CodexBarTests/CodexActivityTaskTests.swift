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
