import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HelperRuntimeStatusMonitorTests {
    @Test func observationCanRestartAfterCancellationBeforeFirstTick() async {
        let monitor = HelperRuntimeStatusMonitor()
        defer { monitor.cancelObservation() }
        let finished = MonitorCheckpoint()
        monitor.startObservation(interval: .seconds(60)) {
            Issue.record("Cancelled observation ran")
        }
        monitor.cancelObservation()
        monitor.startObservation(interval: .zero) {
            monitor.cancelObservation()
            finished.signal()
        }
        await finished.wait()
    }

    @Test func cancelledObservationCannotClearReplacementWhileItsActionFinishes() async {
        let monitor = HelperRuntimeStatusMonitor()
        defer { monitor.cancelObservation() }
        let oldEntered = MonitorCheckpoint()
        let oldRelease = MonitorCheckpoint()
        let oldReturned = MonitorCheckpoint()
        let replacementFinished = MonitorCheckpoint()
        var replacementTicks = 0
        monitor.startObservation(interval: .zero) {
            oldEntered.signal()
            await oldRelease.wait()
            oldReturned.signal()
        }
        await oldEntered.wait()
        monitor.cancelObservation()
        monitor.startObservation(interval: .milliseconds(1)) {
            replacementTicks += 1
            if replacementTicks == 2 {
                monitor.cancelObservation()
                replacementFinished.signal()
            }
        }
        oldRelease.signal()
        await oldReturned.wait()
        monitor.startObservation(interval: .zero) {
            Issue.record("Replacement observation was overwritten")
            monitor.cancelObservation()
            replacementFinished.signal()
        }
        await replacementFinished.wait()
        #expect(replacementTicks == 2)
    }

    @Test func cancelledStatusReplyCannotFinishNewWakeRequest() async {
        let monitor = HelperRuntimeStatusMonitor()
        let helper = MonitorHelper()
        let connection = MonitorConnection(helper: helper)
        defer { monitor.cancelRequest() }
        let statusTask = Task {
            await monitor.fetch(
                connection: connection,
                timeout: .seconds(60),
                onConnectionFailure: { _ in Issue.record("Unexpected connection failure") },
                onTimeout: { Issue.record("Unexpected timeout") }
            )
        }
        await helper.statusRequested.wait()
        #expect(monitor.isRequestInFlight)
        monitor.cancelRequest()
        #expect(!monitor.isRequestInFlight)
        #expect(await statusTask.value == nil)

        let wakeTask = Task {
            await monitor.setAutoResetWakeSchedule(connection: connection, unixTimestamp: 0, timeout: .seconds(60))
        }
        await helper.wakeRequested.wait()
        helper.statusReply?(0, CodexBarSleepOwnershipState.idle.rawValue, 0, false)
        #expect(monitor.isRequestInFlight)
        helper.wakeReply?(0)
        guard case .success = await wakeTask.value else {
            Issue.record("New wake request did not succeed")
            return
        }
        #expect(!monitor.isRequestInFlight)
    }

    @Test func timeoutClearsRequestAndLateReplyDoesNotPreventReuse() async {
        let monitor = HelperRuntimeStatusMonitor()
        let helper = MonitorHelper()
        let connection = MonitorConnection(helper: helper)
        defer { monitor.cancelRequest() }
        let result = await monitor.setAutoResetWakeSchedule(connection: connection, unixTimestamp: 0, timeout: .zero)
        guard case .timedOut = result else {
            Issue.record("Request did not time out")
            return
        }
        #expect(!monitor.isRequestInFlight)
        helper.wakeReply?(0)

        let statusTask = Task {
            await monitor.fetch(
                connection: connection,
                timeout: .seconds(60),
                onConnectionFailure: { _ in Issue.record("Unexpected connection failure") },
                onTimeout: { Issue.record("Unexpected timeout") }
            )
        }
        await helper.statusRequested.wait()
        helper.statusReply?(0, CodexBarSleepOwnershipState.owned.rawValue, 1, true)
        let status = await statusTask.value
        #expect(status?.ownership == .owned)
        #expect(status?.activeClientCount == 1)
        #expect(status?.sleepDisabled == true)
        #expect(!monitor.isRequestInFlight)
    }
}

private final nonisolated class MonitorConnection: NSXPCConnection {
    let helper: MonitorHelper

    init(helper: MonitorHelper) {
        self.helper = helper
        super.init()
    }

    override func remoteObjectProxyWithErrorHandler(_: @escaping (any Error) -> Void) -> Any {
        helper
    }
}

@MainActor
private final class MonitorHelper: NSObject, CodexBarHelperProtocol {
    let statusRequested = MonitorCheckpoint()
    let wakeRequested = MonitorCheckpoint()
    var statusReply: (@Sendable (Int32, Int, Int, Bool) -> Void)?
    var wakeReply: (@Sendable (Int32) -> Void)?

    nonisolated func getSleepPreventionStatus(reply: @escaping @Sendable (Int32, Int, Int, Bool) -> Void) {
        MainActor.assumeIsolated {
            statusReply = reply
            statusRequested.signal()
        }
    }

    nonisolated func setAutoResetWakeSchedule(_: TimeInterval, reply: @escaping @Sendable (Int32) -> Void) {
        MainActor.assumeIsolated {
            wakeReply = reply
            wakeRequested.signal()
        }
    }

    nonisolated func setSleepPreventionRequested(
        _: Bool,
        clientSessionID _: String,
        generation _: UInt64,
        reply: @escaping @Sendable (Int32, Int, Bool) -> Void
    ) {
        Issue.record("Unexpected sleep prevention request")
        reply(-1, 0, false)
    }

    nonisolated func resetSleepAfterUpdate(_: String, reply: @escaping @Sendable (Int32) -> Void) {
        Issue.record("Unexpected update reset request")
        reply(-1)
    }
}

private final class MonitorCheckpoint {
    private var isSignaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func signal() {
        isSignaled = true
        waiter?.resume()
        waiter = nil
    }
}
