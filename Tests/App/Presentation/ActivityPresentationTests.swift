import Combine
import Foundation
import Testing

struct ActivityPresentationTests {
    @Test(arguments: ["active", "missing", "pending", "bootstrap", "recovering", "old", "superseded", "rounded", "missing-time"])
    func completedEventFinalizesWithoutLifecyclePolling(_ scenario: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
        )
        defer { monitor.stop() }
        let now = Date()
        let endedAt = switch scenario {
        case "old": now.addingTimeInterval(-60)
        case "rounded": Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 1)
        default: now
        }
        let startedAt = endedAt.addingTimeInterval(-2)
        let start = TestFixtures.event(at: startedAt)
        let key = try #require(ActivityTaskKey(event: start))
        var task = ActivityTask(displayID: UUID(), key: key, event: start, state: .running, startedAt: startedAt, progressGeneration: 1)
        if scenario == "rounded" {
            let progress = TestFixtures.event(.toolCompleted, at: endedAt.addingTimeInterval(0.5))
            task.recordExecutionEvent(progress)
            task.recordProgress(at: progress.timestamp)
        }
        monitor.isActivitySourceHealthy = true
        monitor.turnTransitionNotBefore = startedAt
        monitor.terminalPresentationNotBefore = startedAt
        if scenario == "recovering" {
            monitor.beginProtectionRecovery()
        }
        var notices = 0
        let subscription = monitor.transitionPublisher.sink { transition in
            if case .completed = transition {
                notices += 1
                #expect(monitor.snapshot.recentCompletions.count == 1)
                #expect(monitor.snapshot.runningTasks.count == (scenario == "superseded" ? 1 : 0))
            }
        }
        defer { subscription.cancel() }
        var presentations: [ActivityPresentationUpdate] = []
        let presentation = monitor.presentationPublisher.sink { presentations.append($0) }
        defer { presentation.cancel() }
        if scenario == "pending" || scenario == "superseded" {
            monitor.graph.pendingTerminalTasks[key] = PendingTerminalTask(task: task, supersededAt: now)
        } else if scenario != "missing" {
            monitor.graph.tasks[key] = task
        }
        let next = TestFixtures.event(at: now, turn: "next")
        if scenario == "superseded" {
            let nextKey = try #require(ActivityTaskKey(event: next))
            monitor.graph.tasks[nextKey] = ActivityTask(displayID: UUID(), key: nextKey, event: next, state: .running, startedAt: now, progressGeneration: 0)
        }
        var end = TestFixtures.event(.turnCompleted, at: endedAt, thread: start.threadID, turn: start.turnID)
        end.context = ActivityDataContext(
            method: "turn/completed", threadID: "thread-a", turnID: "turn-a", turnStatus: .completed,
            turnStartedAt: startedAt, turnCompletedAt: scenario == "missing-time" ? nil : endedAt, duration: scenario == "missing-time" ? nil : 2
        )
        if scenario == "bootstrap" {
            monitor.consume(.snapshotEvents([end, end]))
        } else {
            monitor.consume(.live([end, end]))
        }
        #expect(monitor.graph.tasks[key] == nil)
        #expect(monitor.graph.pendingTerminalTasks[key] == nil)
        #expect(monitor.completions.count == 1)
        #expect(monitor.completions.first?.duration == (scenario == "missing-time" ? nil : 2))
        #expect(monitor.graph.terminalTokenUsageRequests.count == 1)
        let audible = ["active", "missing", "pending", "superseded", "rounded", "missing-time"].contains(scenario)
        #expect(notices == (audible ? 1 : 0))
        #expect(presentations.flatMap(\.terminalEvents).count == (audible ? 1 : 0))
        if scenario == "superseded" {
            #expect(try monitor.graph.tasks[#require(ActivityTaskKey(event: next))] != nil)
        }
        var repeated: [ActivityTransition] = []
        monitor.resolveTerminal(.completed(at: endedAt, duration: 2), task: task, key: key, abortFallback: endedAt, into: &repeated)
        monitor.consume(.lifecycleChanged)
        monitor.refreshSnapshot(now: now)
        #expect(repeated.isEmpty)
        #expect(monitor.completions.count == 1)
        #expect(presentations.flatMap(\.terminalEvents).count == (audible ? 1 : 0))
    }

    @Test(arguments: [
        (ActivityItem(id: "command", type: .commandExecution, commandActions: ["search", "read", "read"].map { .init(type: $0) }), "activity.live.actions-read-search"),
        (ActivityItem(id: "command", type: .commandExecution), "activity.action.command"),
        (ActivityItem(id: "file", type: .fileChange), "activity.action.edit-files"),
        (ActivityItem(id: "agent", type: .collabAgentToolCall, tool: "spawnAgent"), "activity.action.start-subagent")
    ] as [(ActivityItem, LocalizedStringResource)], [false, true])
    func waitingSurfacesShareLocalizedActions(
        operation: (source: ActivityItem, action: LocalizedStringResource), hasProject: Bool
    ) {
        let approval = ActivityApproval(
            requestedAt: TestFixtures.now, toolName: operation.source.tool, sequence: 0,
            itemType: operation.source.type.rawValue, commandActionTypes: operation.source.commandActions?.map(\.type)
        )
        let task = ActivityTaskSnapshot(
            id: UUID(),
            projectName: hasProject ? "CodexBar" : nil, modelName: nil, effort: nil,
            startedAt: TestFixtures.now, stateChangedAt: TestFixtures.now,
            activeSubagentCount: nil, approvalActionText: approval.actionText, threadID: "waiting-thread"
        )
        let expected = String(localized: operation.action)
        let notice = NotificationContent.taskWaiting(project: task.projectName, actionText: task.approvalActionText)
        #expect(task.approvalActionText == expected)
        #expect(notice.body.contains(expected))
        #expect(!notice.body.contains(operation.source.type.rawValue))
        if let raw = operation.source.tool {
            #expect(!notice.body.contains(raw))
        }
    }

    @Test(arguments: [false, true], ["unavailable", "bootstrap", "stop"])
    func clearingActivityAlsoClearsGlow(waiting: Bool, reason: String) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDataDirectoryURL: directory.url
        )
        monitor.protectionLoadState = .available
        monitor.isStarted = true
        monitor.isActivitySourceHealthy = true
        defer { monitor.stop() }
        var updates: [ActivityPresentationUpdate] = []
        var glow = TaskGlowPresentationState()
        let now = Date()
        let subscription = monitor.presentationPublisher.sink { update in
            updates.append(update)
            glow.update(snapshot: update.snapshot, terminalEvents: update.terminalEvents, isEnabled: true, acceptsBriefEvents: true, now: now)
            glow.refresh(now: now, terminalDuration: 10)
        }
        defer { subscription.cancel() }
        monitor.consume(.live([TestFixtures.event(at: now)]))
        if waiting {
            monitor.consume(.live([TestFixtures.event(.approvalRequested, at: now.addingTimeInterval(1))]))
        }
        #expect(glow.state == (waiting ? .waiting : .running))
        #expect(monitor.snapshot.activeCount == 1)

        switch reason {
        case "unavailable": monitor.consume(.sourceUnavailable)
        case "bootstrap": monitor.consume(.bootstrapStart)
        default: monitor.stop()
        }
        #expect(monitor.snapshot == .empty)
        #expect(updates.last?.snapshot == .empty)
        #expect(updates.last?.terminalEvents.isEmpty == true)
        #expect(glow.state == .hidden)

        if reason == "unavailable" {
            let count = updates.count
            monitor.consume(.sourceUnavailable)
            #expect(updates.count == count)
            monitor.isActivitySourceHealthy = true
            monitor.consume(.live([TestFixtures.event(at: now.addingTimeInterval(2), thread: "restored")]))
            #expect(updates.last?.snapshot == monitor.snapshot)
            #expect(updates.last?.terminalEvents.isEmpty == true)
            #expect(glow.state != .hidden)
        }
    }

    @Test func statusItemTerminalExpiresAtTenSecondsWhileCardKeepsHistory() {
        let completion = ActivityCompletion(
            id: UUID(), projectName: nil, modelName: nil, effort: nil,
            completedAt: TestFixtures.now, duration: 30, threadID: "completed-thread"
        )
        let snapshot = ActivitySnapshot(waitingTasks: [], runningTasks: [], recentCompletions: [completion], recentTerminations: [])
        #expect(snapshot.statusItemActivity(at: TestFixtures.now.addingTimeInterval(9.999)) == .completed(completion))
        #expect(snapshot.statusItemActivity(at: TestFixtures.now.addingTimeInterval(10)) == .idle)
        #expect(snapshot.primaryActivity == .completed(completion))
        #expect(snapshot.hasTaskCenterContent)
        #expect(!snapshot.hasActiveTasks)
    }

    @Test func waitingTaskTakesPriorityOverRunningTask() {
        let waiting = task(thread: "waiting-thread")
        let running = task(thread: "running-thread")
        let snapshot = ActivitySnapshot(waitingTasks: [waiting], runningTasks: [running], recentCompletions: [], recentTerminations: [])
        #expect(snapshot.primaryActivity == .waiting(waiting))
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.statusItemActivityExpiration == nil)
    }

    @Test(arguments: [false, true])
    func accountFailureKeepsLiveTaskIcon(waiting: Bool) {
        let task = task(thread: "thread-a")
        let activity = ActivitySnapshot(
            waitingTasks: waiting ? [task] : [], runningTasks: waiting ? [] : [task],
            recentCompletions: [], recentTerminations: []
        )
        let state = StatusIconState(usesErrorImage: true, ordinaryUsageAllowed: nil, progress: nil, activity: activity)
        #expect(state.symbolName(at: TestFixtures.now) == (waiting ? "person.badge.key.fill" : "person.badge.clock.fill"))
        let idle = StatusIconState(usesErrorImage: true, ordinaryUsageAllowed: nil, progress: nil, activity: .empty)
        #expect(idle.symbolName(at: TestFixtures.now) == "person.slash.fill")
    }

    private func task(thread: String) -> ActivityTaskSnapshot {
        ActivityTaskSnapshot(
            id: UUID(),
            projectName: nil, modelName: nil, effort: nil,
            startedAt: TestFixtures.now, stateChangedAt: TestFixtures.now,
            activeSubagentCount: nil, threadID: thread
        )
    }
}
