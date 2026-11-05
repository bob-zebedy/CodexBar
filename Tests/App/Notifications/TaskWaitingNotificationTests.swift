import Foundation
import Testing
import UserNotifications

@Suite(.tags(.integration))
struct TaskWaitingNotificationTests {
    @Test(arguments: [false, true])
    func disablingNotificationsDuringFailedSubmissionStopsRetry(categoryOnly: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        fixture.delivery.suspendsSubmissions = true
        let submission = try fixture.enterWaiting(blockingInput: false)
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { fixture.delivery.hasPendingSubmission })
        if categoryOnly {
            fixture.settings.setTaskWaitingEnabled(false)
        } else {
            fixture.settings.setEnabled(false)
        }
        fixture.delivery.resumeSubmission(failing: true)
        #expect(await submission.value == false)
        #expect(fixture.delivery.attempts.count == 1)
        #expect(fixture.delivery.delivered.isEmpty)
        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals.isEmpty)

        fixture.settings.setTaskWaitingEnabled(true)
        fixture.settings.setEnabled(true)
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { fixture.settings.canDeliver })
        fixture.delivery.suspendsSubmissions = false
        let next = try fixture.enterWaiting(blockingInput: false)
        #expect(await next.value)
        try fixture.resolveWaiting()
        #expect(fixture.delivery.delivered.isEmpty)
    }

    @Test(arguments: [false, true])
    func oldWaitingSubmissionCannotOverwriteOrUntrackTheNextWait(oldFails: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        fixture.delivery.suspendsSubmissions = true
        let first = try fixture.enterWaiting(blockingInput: false)
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { fixture.delivery.attempts.count == 1 })
        let firstID = fixture.identifier
        try fixture.resolveWaiting()
        let second = try fixture.enterWaiting(blockingInput: true)
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) { fixture.delivery.attempts.count == 2 })
        let secondID = fixture.identifier
        #expect(firstID != secondID)
        fixture.delivery.resumeSubmission(at: 1)
        #expect(await second.value)
        fixture.delivery.resumeSubmission(failing: oldFails)
        #expect(await first.value == false)
        #expect(fixture.delivery.attempts.count == 2)
        #expect(fixture.delivery.delivered == [secondID])
        try fixture.resolveWaiting()
        #expect(fixture.delivery.delivered.isEmpty)
        #expect(fixture.delivery.removals.last == [secondID])
    }

    @Test(arguments: [false, true])
    func monitorTransitionDeliversAndSnapshotWithdrawsNotification(blockingInput: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        try fixture.publishWaiting(blockingInput: blockingInput)
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
            fixture.delivery.delivered == [fixture.identifier]
        }, "Notification operation did not reach the expected state")
        #expect(fixture.delivery.attempts == [fixture.identifier])
        try fixture.resolveWaiting()
        #expect(fixture.delivery.delivered.isEmpty)
        #expect(fixture.delivery.removals == [[fixture.identifier]])
    }

    @Test(arguments: [false, true])
    func resolvedBeforeSubmissionSkipsDeliveryAndClearsTracking(blockingInput: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        let submission = try fixture.enterWaiting(blockingInput: blockingInput)

        try fixture.resolveWaiting()
        #expect(fixture.delivery.attempts.isEmpty)
        #expect(await submission.value == false)
        #expect(fixture.delivery.attempts.isEmpty)
        #expect(fixture.delivery.delivered.isEmpty)
        #expect(fixture.delivery.removals == [[fixture.identifier]])
        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals == [[fixture.identifier]])
    }

    @Test(arguments: [false, true])
    func resolvedDuringSubmissionWithdrawsLateDelivery(blockingInput: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        fixture.delivery.suspendsSubmissions = true
        let submission = try fixture.enterWaiting(blockingInput: blockingInput)
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
            fixture.delivery.hasPendingSubmission
        }, "Notification operation did not reach the expected state")

        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals == [[fixture.identifier]])
        fixture.delivery.resumeSubmission()
        #expect(await submission.value == false)
        #expect(fixture.delivery.attempts.count == 1)
        #expect(fixture.delivery.delivered.isEmpty)
        #expect(fixture.delivery.removals == [[fixture.identifier], [fixture.identifier]])
    }

    @Test(arguments: [false, true])
    func resolvedAfterDeliveryUsesSnapshotToWithdrawAndClearTracking(blockingInput: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        let submission = try fixture.enterWaiting(blockingInput: blockingInput)
        #expect(await submission.value)
        #expect(fixture.delivery.delivered == [fixture.identifier])

        try fixture.resolveWaiting(keepsNonblockingQuestion: true)
        #expect(fixture.monitor.snapshot.panelWaitingTasks.count == 1)
        #expect(fixture.monitor.snapshot.blockingWaitingTaskIDs.isEmpty)
        #expect(fixture.delivery.delivered.isEmpty)
        #expect(fixture.delivery.removals == [[fixture.identifier]])
        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals == [[fixture.identifier]])
    }

    @Test(arguments: [false, true])
    func exhaustedSubmissionRetriesClearTrackingWhileTaskStillWaits(blockingInput: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.start()
        fixture.delivery.failuresRemaining = 2
        let submission = try fixture.enterWaiting(blockingInput: blockingInput)
        #expect(await submission.value == false)
        #expect(fixture.delivery.attempts.count == 2)
        #expect(fixture.monitor.snapshot.blockingWaitingTaskIDs == [fixture.taskID])
        #expect(fixture.delivery.delivered.isEmpty)
        #expect(fixture.delivery.removals.isEmpty)

        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals.isEmpty)
        let retried = try fixture.enterWaiting(blockingInput: blockingInput)
        #expect(await retried.value)
        #expect(fixture.delivery.delivered == [fixture.identifier])
        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals == [[fixture.identifier]])
        try fixture.resolveWaiting()
        #expect(fixture.delivery.removals == [[fixture.identifier]])
    }
}

private final class Fixture {
    let directory: TestDirectory
    let preferences: TestPreferences
    let settings: NotificationSettings
    let monitor: ActivityMonitor
    let service: NotificationService
    let delivery = TestNotificationDelivery()
    let taskID = UUID()
    private let key = ActivityTaskKey(thread: "thread-a", turn: "turn-a")
    private let owner = ActivityExecutionKey(agentThreadID: nil, turnID: "turn-a")
    private var graph = ActivityTaskGraph()

    var identifier: String {
        delivery.attempts.last ?? delivery.removals.first?.first ?? "not-submitted"
    }

    init() throws {
        directory = try TestDirectory()
        preferences = try TestPreferences()
        preferences.defaults.set(true, forKey: "Notification.isEnabled")
        settings = NotificationSettings(defaults: preferences.defaults, readAuthorizationStatus: { .authorized })
        monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
        )
        let model = CodexStatusViewModel(
            service: CodexStatusService(socketURL: directory.url.appendingPathComponent("unused.sock"), logStorage: nil),
            defaults: preferences.defaults
        )
        service = NotificationService(
            settings: settings, statusViewModel: model, activityMonitor: monitor,
            defaults: preferences.defaults, delivery: delivery.client, openMenuSurface: {}
        )
        let now = Date()
        graph.tasks[key] = ActivityTask(
            displayID: taskID, key: key, event: TestFixtures.event(at: now),
            state: .running, startedAt: now, progressGeneration: 0
        )
        monitor.isActivitySourceHealthy = true
        monitor.turnTransitionNotBefore = now
    }

    func start() async throws {
        service.start()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5)) {
            self.settings.canDeliver
        }, "Notification operation did not reach the expected state")
    }

    func enterWaiting(blockingInput: Bool) throws -> Task<Bool, Never> {
        let transition = try waitingTransition(blockingInput: blockingInput)
        monitor.acceptFixtureGraph(graph)
        return try #require(service.handleActivityTransition(transition))
    }

    func publishWaiting(blockingInput: Bool) throws {
        let transition = try waitingTransition(blockingInput: blockingInput)
        monitor.acceptFixtureGraph(graph, transitions: [transition])
    }

    private func waitingTransition(blockingInput: Bool) throws -> ActivityTransition {
        let now = Date()
        if blockingInput {
            graph.tasks[key]?.executions[owner]?.presentation = try question(blocking: true, at: now)
        } else {
            _ = graph.tasks[key]?.recordApprovalRequest(from: TestFixtures.event(.approvalRequested, at: now))
        }
        let snapshot = try #require(graph.tasks[key]?.snapshot)
        return .waiting(snapshot, since: now)
    }

    func resolveWaiting(keepsNonblockingQuestion: Bool = false) throws {
        graph.tasks[key]?.executions[owner]?.approval = nil
        graph.tasks[key]?.executions[owner]?.presentation = try keepsNonblockingQuestion ? question(blocking: false, at: Date()) : nil
        graph.tasks[key]?.state = .running
        monitor.acceptFixtureGraph(graph)
    }

    func cleanUp() {
        delivery.cancelPendingSubmissions()
        preferences.remove()
        try? directory.remove()
    }

    private func question(blocking: Bool, at date: Date) throws -> ActivityLivePresentation {
        var presentation = ActivityLivePresentation()
        let input = try TestFixtures.decode(ActivityInput.self, """
        {"id":"input","method":"item/tool/requestUserInput","params":{"threadId":"thread-a","turnId":"turn-a","isBlocking":\(blocking)}}
        """)
        presentation.consume(input, at: date)
        return presentation
    }
}

private final class TestNotificationDelivery {
    var suspendsSubmissions = false
    var failuresRemaining = 0
    private(set) var attempts: [String] = []
    private(set) var delivered = Set<String>()
    private(set) var removals: [Set<String>] = []
    private var pending: [CheckedContinuation<Void, any Error>] = []

    var hasPendingSubmission: Bool {
        !pending.isEmpty
    }

    var client: NotificationService.Delivery {
        NotificationService.Delivery(
            setDelegate: { _ in },
            add: { [self] request in
                attempts.append(request.identifier)
                if suspendsSubmissions {
                    try await withCheckedThrowingContinuation { pending.append($0) }
                }
                if failuresRemaining > 0 {
                    failuresRemaining -= 1
                    throw CocoaError(.fileWriteUnknown)
                }
                delivered.insert(request.identifier)
            },
            remove: { [self] identifiers in
                removals.append(Set(identifiers))
                delivered.subtract(identifiers)
            }
        )
    }

    func resumeSubmission(at index: Int = 0, failing: Bool = false) {
        let continuation = pending.remove(at: index)
        if failing {
            continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        } else {
            continuation.resume()
        }
    }

    func cancelPendingSubmissions() {
        suspendsSubmissions = false
        failuresRemaining = 2
        let continuations = pending
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}
