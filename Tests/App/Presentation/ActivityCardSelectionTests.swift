import Foundation
import Testing

struct ActivityCardSelectionTests {
    private let now = Date(timeIntervalSince1970: 1800000000)

    @Test func progressReordersAutomaticSelectionButNotCarousel() {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b])
        #expect(state.positionText(for: state.selectedID) == "1/2")
        #expect(state.positionText(for: "b") == "2/2")
        #expect(state.positionText(for: nil) == nil)
        #expect(state.positionText(for: "missing") == nil)
        #expect(state.transitionDirection == nil)
        update(&state, running: [b, a, c])
        #expect(state.selectedID == "b")
        #expect(state.transitionDirection == nil)
        #expect(state.activities.compactMap(\.cardSelectionID) == ["a", "b", "c"])
        #expect(state.positionText(for: state.selectedID) == "2/3")
        #expect(state.positionText(for: "a") == "1/3")
        #expect(state.positionText(for: "c") == "3/3")
        state.swipe(1, now: now)
        #expect(state.selectedID == "c")
        #expect(state.transitionDirection == 1)
        state.swipe(1, now: now)
        #expect(state.selectedID == "a")
        state.swipe(-1, now: now)
        #expect(state.positionText(for: state.selectedID) == "3/3")
        #expect(state.transitionDirection == -1)
    }

    @Test func pinFollowsThreadThroughCompletionAndNewTurn() {
        let a = task("a"), b = task("b")
        var state = selection(running: [a, b])
        state.togglePin(now: now)
        let completion = completed(a, at: now)
        update(&state, running: [b], completions: [completion])
        #expect(state.current == .completed(completion))
        let next = task("a")
        update(&state, running: [b, next], completions: [completion])
        #expect(state.current == .running(next))
        #expect(state.pinnedID == "a")
        #expect(state.activities.count == 2)
        #expect(state.positionText(for: state.selectedID) == "1/2")
    }

    @Test(arguments: [false, true], [false, true])
    func manualViewingUsesTenOrFifteenSeconds(pinned: Bool, waiting: Bool) {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b])
        if pinned {
            state.togglePin(now: now)
        }
        if waiting {
            update(&state, running: [a], waiting: [b])
        }
        if !pinned, waiting {
            state.swipe(-1, now: now)
        }
        state.swipe(1, now: now)
        #expect(state.selectedID == "b")
        let duration: TimeInterval = waiting ? 15 : 10
        #expect(state.returnDeadline == now.addingTimeInterval(duration))
        update(&state, running: [a, b].filter { !waiting || $0.id != b.id }, waiting: waiting ? [c, b] : [c])
        #expect(state.selectedID == "b")
        #expect(state.transitionDirection == 1)
        state.reconcile(at: now.addingTimeInterval(duration - 0.01))
        #expect(state.selectedID == "b")
        state.reconcile(at: now.addingTimeInterval(duration))
        #expect(state.selectedID == (pinned ? "a" : "c"))
        #expect(state.transitionDirection == nil)
    }

    @Test func pinReplacementAndUnpinKeepCurrentTaskVisible() {
        var state = selection(running: [task("a"), task("b")])
        state.togglePin(now: now)
        state.swipe(1, now: now)
        state.togglePin(now: now)
        #expect(state.pinnedID == "b")
        #expect(state.manualViewingDeadline == nil)
        state.togglePin(now: now)
        #expect(state.pinnedID == nil)
        #expect(state.selectedID == "b")
        state.reconcile(at: now.addingTimeInterval(10))
        #expect(state.selectedID == "a")
    }

    @Test func closedPanelAndDisconnectedSourceRetainPin() {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b])
        state.togglePin(now: now)
        state.swipe(1, now: now)
        state.setGestureActive(true, now: now)
        update(&state, running: [a, b, c])
        #expect(state.positionText(for: "b") == "2/2")
        state.setVisible(false, now: now)
        #expect(!state.isGestureActive)
        #expect(state.positionText(for: "b") == "2/3")
        #expect(state.returnDeadline == nil)
        #expect(state.transitionDirection == nil)
        state.setVisible(true, now: now)
        #expect(state.selectedID == "a")
        state.setGestureActive(true, now: now)
        state.update(snapshot: .empty, isHealthy: false, now: now)
        #expect(!state.isGestureActive)
        #expect(state.carouselActivities.isEmpty)
        #expect(state.current == nil)
        #expect(state.pinnedID == "a")
        #expect(state.transitionDirection == nil)
        update(&state, running: [b, a])
        #expect(state.activities.compactMap(\.cardSelectionID) == ["a", "b"])
        #expect(state.current == .running(a))
    }

    @Test(arguments: [false, true])
    func expiredPinAllowsAutomaticPreemptionAndRecoversOnNewTurn(terminated: Bool) {
        let a = task("a"), b = task("b"), c = task("c")
        let completions = terminated ? [] : [completed(a, at: now)]
        let terminations = terminated ? [ActivityTermination(
            id: UUID(), taskID: a.id, projectName: a.projectName, modelName: nil, effort: nil,
            terminatedAt: now, duration: 1, threadID: a.threadID
        )] : []
        var state = selection(running: [a, b])
        state.togglePin(now: now)
        update(&state, running: [b], completions: completions, terminations: terminations, at: now.addingTimeInterval(599))
        #expect(state.current?.cardSelectionID == "a")
        #expect(state.activities.count == 2)
        update(&state, running: [b], completions: completions, terminations: terminations, at: now.addingTimeInterval(600))
        #expect(state.pinnedID == "a")
        #expect(state.selectedID == "b")
        #expect(state.current == .running(b))
        #expect(state.activities.count == 1)
        #expect(state.transitionDirection == nil)
        update(&state, running: [c, b], completions: completions, terminations: terminations, at: now.addingTimeInterval(601))
        #expect(state.selectedID == "c")
        let next = task("a")
        update(&state, running: [c, b, next], at: now.addingTimeInterval(602))
        #expect(state.current == .running(next))
    }

    @Test func newPinnedTurnDoesNotInterruptManualViewing() {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b, c])
        state.togglePin(now: now)
        update(&state, running: [b, c])
        state.swipe(1, now: now)
        #expect(state.selectedID == "c")
        let next = task("a")
        update(&state, running: [next, b, c])
        #expect(state.selectedID == "c")
        state.reconcile(at: now.addingTimeInterval(10))
        #expect(state.current == .running(next))
    }

    @Test func waitingDirectionsRecalculateAfterEverySwipeIncludingTies() {
        let tasks = (0 ..< 5).map { task(String($0)) }
        var state = selection(running: tasks)
        state.selectAfterSwipe("0", now: now)
        update(&state, running: [tasks[0], tasks[2], tasks[3]], waiting: [tasks[1], tasks[4]])
        #expect(state.waitingSides == .init(left: true, right: true))
        state.swipe(1, now: now)
        #expect(state.waitingSides == .init(left: true, right: false))
        state.swipe(1, now: now)
        #expect(state.waitingSides == .init(left: true, right: true))
        var tied = selection(running: [tasks[0], tasks[1]])
        tied.togglePin(now: now)
        update(&tied, running: [tasks[0]], waiting: [tasks[1]])
        #expect(tied.waitingSides == .init(left: true, right: true))
        tied.togglePin(now: now)
        #expect(tied.waitingSides == .init(left: true, right: true))
        tied.swipe(1, now: now)
        #expect(tied.waitingSides == .init())
    }

    @Test func gesturesPauseCountdownAndNewSwipesRestartIt() {
        var state = selection(running: [task("a"), task("b"), task("c")])
        state.togglePin(now: now)
        state.setGestureActive(true, now: now)
        state.swipe(1, now: now.addingTimeInterval(1))
        #expect(state.returnDeadline == nil)
        state.reconcile(at: now.addingTimeInterval(20))
        #expect(state.selectedID == "b")
        state.setGestureActive(false, now: now.addingTimeInterval(20))
        #expect(state.returnDeadline == now.addingTimeInterval(30))
        state.swipe(1, now: now.addingTimeInterval(25))
        #expect(state.returnDeadline == now.addingTimeInterval(35))
        state.reconcile(at: now.addingTimeInterval(34))
        #expect(state.selectedID == "c")
        state.reconcile(at: now.addingTimeInterval(35))
        #expect(state.selectedID == "a")
        #expect(state.transitionDirection == nil)
    }

    @Test func disappearingManualTaskFallsBackAndSingleTaskDoesNotStartTimer() {
        let a = task("a"), b = task("b")
        var state = selection(running: [a, b])
        state.togglePin(now: now)
        state.swipe(1, now: now)
        update(&state, running: [a])
        #expect(state.selectedID == "a")
        #expect(state.transitionDirection == nil)
        #expect(state.positionText(for: state.selectedID) == nil)
        #expect(state.returnDeadline == nil)
        state.swipe(1, now: now)
        #expect(state.returnDeadline == nil)
        update(&state, running: [])
        #expect(state.positionText(for: state.selectedID) == nil)
        #expect(state.pinnedID == "a")
    }

    @Test func terminalHistoryKeepsLatestPerThreadAndIncludesFailures() {
        let a = task("a"), b = task("b")
        let old = completed(a, at: now.addingTimeInterval(-10))
        let latest = completed(a, at: now)
        let stopped = ActivityTermination(
            id: UUID(), taskID: b.id, projectName: "same-project", modelName: nil, effort: nil,
            terminatedAt: now, duration: 5, isFailure: true, threadID: "b"
        )
        var state = ActivityCardSelection()
        state.update(snapshot: .init(waitingTasks: [], runningTasks: [], recentCompletions: [latest, old], recentTerminations: [stopped]), isHealthy: true, now: now)
        #expect(state.activities.count == 2)
        #expect(state.activities.contains(.completed(latest)))
        #expect(!state.activities.contains(.completed(old)))
        #expect(state.current == .terminated(stopped))
    }

    @Test func nonblockingQuestionUsesWaitingDirectionAndLongerViewingTime() {
        let a = task("a")
        var b = task("b")
        var state = selection(running: [a, b])
        state.togglePin(now: now)
        b.presentation = ActivityLiveSummary(
            current: ActivityLiveLabel("processing"),
            waiting: ActivityLiveWait(label: ActivityLiveLabel("waiting-input"), since: now, isBlocking: false)
        )
        update(&state, running: [a, b])
        #expect(state.waitingSides == .init(left: true, right: true))
        state.swipe(1, now: now)
        #expect(state.current == .waiting(b))
        #expect(state.returnDeadline == now.addingTimeInterval(15))
    }

    @Test func firstGestureProtectsSelectionBeforeAnyPageWasCommitted() {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b])
        state.setGestureActive(true, now: now)
        update(&state, running: [a, b], waiting: [c], at: now.addingTimeInterval(1))
        #expect(state.selectedID == "a")
        #expect(state.manualViewingDeadline == nil)
        state.reconcile(at: now.addingTimeInterval(20))
        #expect(state.selectedID == "a")
        state.setGestureActive(false, now: now.addingTimeInterval(21))
        #expect(state.selectedID == "c")
    }

    @Test func chainedGesturesKeepOrderPositionsAndWaitingEdgesUntilSettlement() {
        let a = task("a"), b = task("b"), c = task("c"), d = task("d"), e = task("e")
        var state = selection(running: [a, b, c])
        state.togglePin(now: now)
        update(&state, running: [a, b], waiting: [c])
        state.setGestureActive(true, now: now)
        update(&state, running: [a, b, d], waiting: [c])
        update(&state, running: [a, b, d, e], waiting: [c])
        #expect(state.activities.count == 5)
        #expect(state.positionText(for: "a") == "1/3")
        #expect(state.positionText(for: "d") == nil)
        #expect(state.waitingSides == .init(left: true, right: false))
        state.swipe(-1, now: now.addingTimeInterval(1))
        #expect(state.selectedID == "c")
        #expect(state.positionText(for: "c") == "3/3")
        state.setGestureActive(true, now: now.addingTimeInterval(2))
        state.swipe(1, now: now.addingTimeInterval(3))
        #expect(state.selectedID == "a")
        #expect(state.positionText(for: "a") == "1/3")
        #expect(state.waitingSides == .init(left: true, right: false))
        state.setGestureActive(false, now: now.addingTimeInterval(4))
        #expect(state.selectedID == "a")
        #expect(state.positionText(for: "a") == "1/5")
        #expect(state.waitingSides == .init(left: false, right: true))
        #expect(state.returnDeadline == now.addingTimeInterval(14))
    }

    @Test(arguments: [false, true])
    func committedPreviewStartsViewingTimeAfterSettlement(waiting: Bool) {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b])
        state.setGestureActive(true, now: now)
        update(&state, running: waiting ? [a] : [a, b], waiting: waiting ? [c, b] : [c])
        state.selectAfterSwipe("b", now: now.addingTimeInterval(2))
        #expect(state.selectedID == "b")
        #expect(state.current == .running(b))
        #expect(state.positionText(for: "b") == "2/2")
        #expect(state.returnDeadline == nil)
        #expect(state.transitionDirection == nil)
        state.setGestureActive(false, now: now.addingTimeInterval(3))
        #expect(state.current == (waiting ? .waiting(b) : .running(b)))
        let deadline = now.addingTimeInterval(waiting ? 18 : 13)
        #expect(state.returnDeadline == deadline)
        state.reconcile(at: deadline)
        #expect(state.selectedID == "c")
    }

    @Test func disappearingPreviewCannotBeCommitted() {
        let a = task("a"), b = task("b"), c = task("c")
        var state = selection(running: [a, b])
        state.setGestureActive(true, now: now)
        update(&state, running: [a, c])
        #expect(!state.isGestureActive)
        #expect(state.carouselActivities.compactMap(\.cardSelectionID) == ["a", "c"])
        state.selectAfterSwipe("b", now: now)
        #expect(state.selectedID == "a")
        #expect(state.manualViewingDeadline == nil)
        state.setGestureActive(false, now: now)
    }

    private func task(_ thread: String) -> ActivityTaskSnapshot {
        ActivityTaskSnapshot(
            id: UUID(), projectName: "same-project", modelName: "gpt-5", effort: "high",
            startedAt: now, stateChangedAt: now, activeSubagentCount: 0, threadID: thread
        )
    }

    private func completed(_ task: ActivityTaskSnapshot, at date: Date) -> ActivityCompletion {
        ActivityCompletion(
            id: UUID(), taskID: task.id, projectName: task.projectName, modelName: nil, effort: nil,
            completedAt: date, duration: 1, threadID: task.threadID
        )
    }

    private func selection(running: [ActivityTaskSnapshot]) -> ActivityCardSelection {
        var state = ActivityCardSelection()
        update(&state, running: running)
        state.setVisible(true, now: now)
        return state
    }

    private func update(
        _ state: inout ActivityCardSelection,
        running: [ActivityTaskSnapshot],
        waiting: [ActivityTaskSnapshot] = [],
        completions: [ActivityCompletion] = [],
        terminations: [ActivityTermination] = [],
        at date: Date? = nil
    ) {
        state.update(
            snapshot: .init(waitingTasks: waiting, runningTasks: running, recentCompletions: completions, recentTerminations: terminations),
            isHealthy: true, now: date ?? now
        )
    }
}
