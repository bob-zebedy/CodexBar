import Combine
import Foundation
import Testing

struct ActivityPresentationTests {
    @Test(arguments: [
        (("commandExecution", "search/read/read"), "activity.live.actions-read-search"),
        (("commandExecution", nil), "activity.action.command"),
        (("fileChange", nil), "activity.action.edit-files"),
        (("collabAgentToolCall", "spawnAgent"), "activity.action.start-subagent")
    ] as [((String, String?), LocalizedStringResource)], [false, true])
    func waitingSurfacesShareLocalizedActions(
        operation: (source: (type: String, tool: String?), action: LocalizedStringResource), hasProject: Bool
    ) {
        let task = ActivityTaskSnapshot(
            id: UUID(), isAnonymous: false,
            projectName: hasProject ? "CodexBar" : nil, modelName: nil, effort: nil, toolName: operation.source.tool,
            startedAt: TestFixtures.now, stateChangedAt: TestFixtures.now,
            showsPreciseDuration: true, activeSubagentCount: nil, itemType: operation.source.type
        )
        let expected = String(localized: operation.action)
        let notice = NotificationContent.taskWaiting(project: task.projectName, toolName: task.toolDisplayName)
        #expect(task.toolDisplayName == expected)
        #expect(notice.body.contains(expected))
        #expect(!notice.body.contains(operation.source.type))
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
            activityDirectoryURL: directory.url
        )
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
            monitor.consume(.live([TestFixtures.event(at: now.addingTimeInterval(2), session: "restored")]))
            #expect(updates.last?.snapshot == monitor.snapshot)
            #expect(updates.last?.terminalEvents.isEmpty == true)
            #expect(glow.state != .hidden)
        }
    }
}
