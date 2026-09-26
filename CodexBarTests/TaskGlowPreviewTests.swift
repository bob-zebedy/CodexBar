import Combine
import Foundation
import Testing

struct TaskGlowPreviewTests {
    private let now = TestFixtures.now

    @Test func previewRequestsDoNotChangePreferences() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = TaskGlowSettings(defaults: preferences.defaults)
        var requests: [TaskGlowPreviewRequest] = []
        let subscription = settings.previewRequests.sink { requests.append($0) }
        defer { subscription.cancel() }
        settings.previewColor(for: .waiting)
        #expect(requests.isEmpty)
        settings.setEnabled(true)
        let saved = preferences.defaults.dictionaryRepresentation() as NSDictionary
        for role in TaskGlowColorRole.allCases {
            settings.previewColor(for: role)
        }
        settings.endColorPreview()
        #expect(requests == [.enabled, .color(.running), .color(.waiting), .color(.completed), .color(.terminated), .endColorPreview])
        #expect(preferences.defaults.dictionaryRepresentation() as NSDictionary == saved)
    }

    @Test func completionDuringPreviewGetsFullDurationAfterReturnTransition() {
        var state = enabledState()
        state.suspend(now: now)
        let completion = completed(at: 2)
        update(&state, snapshot: completion, at: 2)
        state.refresh(now: time(60), terminalDuration: 15)
        #expect(state.state == .completed)
        #expect(state.isSuspended)
        state.resume(now: time(60.4))
        state.refresh(now: time(60), terminalDuration: 15)
        #expect(state.terminal?.startedAt == time(60.4))
        #expect(state.terminal?.expiresAt == time(75.4))
        #expect(completion.latestTerminalEvent?.endedAt == time(2))
        state.refresh(now: time(75.4), terminalDuration: 15)
        #expect(state.state == .hidden)
    }

    @Test func interruptedCompletionKeepsOnlyRemainingTimeAcrossRepeatedPreviews() {
        var state = enabledState(snapshot: completed(at: 0))
        state.suspend(now: time(5))
        state.suspend(now: time(8))
        state.refresh(now: time(20), terminalDuration: 15)
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.terminal?.expiresAt == time(30))
        state.suspend(now: time(22))
        state.resume(now: time(40))
        state.refresh(now: time(40), terminalDuration: 15)
        #expect(state.terminal?.expiresAt == time(48))
        state.refresh(now: time(48), terminalDuration: 15)
        #expect(state.state == .hidden)
    }

    @Test func previewDuringReturnTransitionDoesNotAddUnshownTime() {
        var state = enabledState(snapshot: completed(at: 0))
        state.suspend(now: time(5))
        state.resume(now: time(10.4))
        state.refresh(now: time(10), terminalDuration: 15)
        state.suspend(now: time(10.1))
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.terminal?.expiresAt == time(30))
    }

    @Test func expiredCompletionDoesNotReviveAfterPreview() {
        var state = enabledState(snapshot: completed(at: 0))
        state.refresh(now: time(20), terminalDuration: 15)
        state.suspend(now: time(20))
        state.resume(now: time(60))
        state.refresh(now: time(60), terminalDuration: 15)
        #expect(state.state == .hidden)
    }

    @Test func newTerminationDuringInterruptedReturnGetsFullTime() {
        var state = enabledState(snapshot: completed(at: 0))
        state.suspend(now: time(5))
        state.resume(now: time(10.4))
        state.refresh(now: time(10), terminalDuration: 15)
        state.suspend(now: time(10.1))
        let termination = CodexActivityTermination(
            id: UUID(), isAnonymous: false, projectName: nil, modelName: nil,
            effort: nil, terminatedAt: time(10.2), duration: 60
        )
        let snapshot = CodexActivitySnapshot(
            waitingTasks: [], runningTasks: [], recentCompletions: completed(at: 0).recentCompletions,
            recentTerminations: [termination]
        )
        update(&state, snapshot: snapshot, at: 10.2)
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.state == .terminated)
        #expect(state.terminal?.eventID == termination.id)
        #expect(state.terminal?.expiresAt == time(35))
        state.refresh(now: time(35), terminalDuration: 15)
        #expect(state.state == .hidden)
    }

    @Test func onlyLatestTerminalStateSurvivesPreview() {
        var state = enabledState()
        state.suspend(now: now)
        update(&state, snapshot: completed(at: 2), at: 2)
        let latest = completed(at: 5)
        update(&state, snapshot: latest, at: 5)
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.terminal?.eventID == latest.latestTerminalEvent?.id)
        #expect(state.terminal?.expiresAt == time(35))
        state.refresh(now: time(35), terminalDuration: 15)
        #expect(state.state == .hidden)
    }

    @Test func latestWaitingTaskReplacesCompletionDuringPreview() {
        var state = enabledState()
        state.suspend(now: now)
        update(&state, snapshot: completed(at: 2), at: 2)
        update(&state, snapshot: active(waiting: true), at: 3)
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.state == .waiting)
        #expect(state.terminal == nil)
    }

    @Test func concurrentBriefCompletionGetsFullTimeAfterPreview() throws {
        var state = enabledState(snapshot: active())
        state.suspend(now: time(1))
        let event = try #require(completed(at: 2).latestTerminalEvent)
        state.update(snapshot: active(), terminalEvents: [event], isEnabled: true, acceptsBriefEvents: true, now: time(2))
        state.refresh(now: time(20), terminalDuration: 15)
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.state == .completed)
        #expect(state.terminal?.expiresAt == time(23))
        state.refresh(now: time(23), terminalDuration: 15)
        #expect(state.state == .running)
    }

    @Test func interruptedBriefCompletionResumesRemainingTime() throws {
        var state = enabledState(snapshot: active())
        let event = try #require(completed(at: 1).latestTerminalEvent)
        state.update(snapshot: active(), terminalEvents: [event], isEnabled: true, acceptsBriefEvents: true, now: time(1))
        state.refresh(now: time(1), terminalDuration: 15)
        state.suspend(now: time(2))
        state.resume(now: time(20))
        state.refresh(now: time(20), terminalDuration: 15)
        #expect(state.terminal?.expiresAt == time(22))
        state.refresh(now: time(22), terminalDuration: 15)
        #expect(state.state == .running)
    }

    @Test func disablingDropsSuspensionAndSleepDoesNotExtendIt() {
        var state = enabledState(snapshot: completed(at: 0))
        state.suspend(now: time(5))
        state.resume(now: time(10))
        state.refresh(now: time(60), terminalDuration: 15)
        #expect(state.state == .hidden)
        state.suspend(now: time(60))
        state.update(snapshot: .empty, terminalEvents: [], isEnabled: false, acceptsBriefEvents: false, now: time(60))
        state.refresh(now: time(60), terminalDuration: 15)
        #expect(!state.isSuspended)
        #expect(state.state == .hidden)
    }

    @Test(arguments: TaskGlowColorRole.allCases)
    func previewUsesStateAnimationAndIndependentPlaybackIdentity(_ role: TaskGlowColorRole) {
        let playback = TaskGlowPlayback(startsAt: time(0.4), mediaStart: 100.4)
        let preview = TaskGlowPreviewPresentation(role: role, isColorPreview: true, playback: playback, speed: .standard)
        let next = TaskGlowPreviewPresentation(
            role: role, isColorPreview: true,
            playback: TaskGlowPlayback(startsAt: time(1), mediaStart: 101), speed: .standard
        )
        #expect(preview.playback.id != next.playback.id)
        switch role {
        case .running:
            #expect(preview.state == .running)
            #expect(preview.expiresAt == time(3.1))
        case .waiting:
            #expect(preview.state == .waiting)
            #expect(preview.expiresAt == time(3.75))
        case .completed, .terminated:
            #expect(preview.state == (role == .completed ? .completed : .terminated))
            #expect(preview.expiresAt == time(3.4))
            #expect(preview.terminal?.startedAt == time(0.4))
            #expect(preview.terminal?.eventID == playback.id)
        }
    }

    @Test(arguments: [TaskGlowColorRole.running, .waiting])
    func changingSpeedPreservesCycleProgress(_ role: TaskGlowColorRole) {
        var preview = TaskGlowPreviewPresentation(
            role: role, isColorPreview: true,
            playback: TaskGlowPlayback(startsAt: now, mediaStart: 100), speed: .standard
        )
        let entrance = role == .waiting ? TaskGlowAnimationTiming.expansionDuration : 0
        let duration = preview.expiresAt.timeIntervalSince(now) - entrance
        let halfway = time(entrance + duration / 2)
        preview.setAnimationSpeed(.slow, now: halfway)
        #expect(abs(preview.expiresAt.timeIntervalSince(halfway) - duration * 0.75) < 0.00001)
        #expect(abs(preview.playback.mediaStart - 100 - preview.playback.startsAt.timeIntervalSince(now)) < 0.00001)
    }

    private func enabledState(snapshot: CodexActivitySnapshot = .empty) -> TaskGlowPresentationState {
        var state = TaskGlowPresentationState()
        update(&state, snapshot: snapshot, at: 0)
        state.refresh(now: now, terminalDuration: 15)
        return state
    }

    private func update(_ state: inout TaskGlowPresentationState, snapshot: CodexActivitySnapshot, at seconds: TimeInterval) {
        state.update(snapshot: snapshot, terminalEvents: [], isEnabled: true, acceptsBriefEvents: true, now: time(seconds))
    }

    private func time(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    private func completed(at seconds: TimeInterval) -> CodexActivitySnapshot {
        let completion = CodexActivityCompletion(
            id: UUID(), isAnonymous: false, projectName: nil, modelName: nil,
            effort: nil, completedAt: time(seconds), duration: 60
        )
        return CodexActivitySnapshot(waitingTasks: [], runningTasks: [], recentCompletions: [completion], recentTerminations: [])
    }

    private func active(waiting: Bool = false) -> CodexActivitySnapshot {
        let task = CodexActivityTaskSnapshot(
            id: UUID(), isAnonymous: false, latestEvent: .toolStarted, projectName: nil,
            modelName: nil, effort: nil, toolName: nil, startedAt: now,
            stateChangedAt: now, showsPreciseDuration: true, activeSubagentCount: nil
        )
        return CodexActivitySnapshot(
            waitingTasks: waiting ? [task] : [], runningTasks: waiting ? [] : [task], recentCompletions: [], recentTerminations: []
        )
    }
}
