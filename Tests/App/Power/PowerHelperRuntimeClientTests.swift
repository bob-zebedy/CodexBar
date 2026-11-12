import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PowerHelperRuntimeClientTests {
    @Test func observationCanRestartAfterCancellationBeforeFirstTick() async throws {
        let client = PowerHelperRuntimeClient()
        defer { client.cancelObservation() }
        let finished = TestCheckpoint()
        client.startObservation(interval: .seconds(60)) {
            Issue.record("Cancelled observation ran")
        }
        client.cancelObservation()
        client.startObservation(interval: .zero) {
            client.cancelObservation()
            finished.signal()
        }
        try #require(try await finished.wait())
    }

    @Test func cancelledObservationCannotClearReplacementWhileItsActionFinishes() async throws {
        let client = PowerHelperRuntimeClient()
        defer { client.cancelObservation() }
        let oldEntered = TestCheckpoint()
        let oldRelease = TestCheckpoint()
        let oldReturned = TestCheckpoint()
        let replacementEntered = TestCheckpoint()
        let replacementRelease = TestCheckpoint()
        let replacementFinished = TestCheckpoint()
        defer {
            oldRelease.signal()
            replacementRelease.signal()
        }
        var replacementTicks = 0
        client.startObservation(interval: .zero) {
            oldEntered.signal()
            await oldRelease.waitIgnoringCancellation()
            oldReturned.signal()
        }
        try #require(try await oldEntered.wait())
        client.cancelObservation()
        client.startObservation(interval: .zero) {
            replacementTicks += 1
            if replacementTicks == 1 {
                replacementEntered.signal()
                await replacementRelease.waitIgnoringCancellation()
            } else {
                client.cancelObservation()
                replacementFinished.signal()
            }
        }
        try #require(try await replacementEntered.wait())
        oldRelease.signal()
        try #require(try await oldReturned.wait())
        client.startObservation(interval: .zero) {
            Issue.record("Replacement observation was overwritten")
            client.cancelObservation()
            replacementFinished.signal()
        }
        replacementRelease.signal()
        try #require(try await replacementFinished.wait())
        #expect(replacementTicks == 2)
    }

    @Test func cancelledStatusReplyCannotFinishNewWakeRequest() async throws {
        let client = PowerHelperRuntimeClient()
        let powerHelper = MonitorPowerHelper()
        let connection = MonitorConnection(powerHelper: powerHelper)
        defer { client.cancelRequest() }
        let statusTask = Task {
            await client.fetch(
                connection: connection,
                timeout: .seconds(60),
                onConnectionFailure: { _ in Issue.record("Unexpected connection failure") },
                onTimeout: { Issue.record("Unexpected timeout") }
            )
        }
        try #require(try await powerHelper.statusRequested.wait())
        #expect(client.isRequestInFlight)
        client.cancelRequest()
        #expect(!client.isRequestInFlight)
        #expect(await statusTask.value == nil)

        let wakeTask = Task {
            await client.setAutoResetWakeSchedule(connection: connection, unixTimestamp: 0, timeout: .seconds(60))
        }
        try #require(try await powerHelper.wakeRequested.wait())
        powerHelper.statusReply?(0, CodexBarSleepOwnershipState.idle.rawValue, 0, false)
        #expect(client.isRequestInFlight)
        powerHelper.wakeReply?(0)
        guard case .success = await wakeTask.value else {
            Issue.record("New wake request did not succeed")
            return
        }
        #expect(!client.isRequestInFlight)
    }

    @Test func timeoutClearsRequestAndLateReplyDoesNotPreventReuse() async throws {
        let client = PowerHelperRuntimeClient()
        let powerHelper = MonitorPowerHelper()
        let connection = MonitorConnection(powerHelper: powerHelper)
        defer { client.cancelRequest() }
        let result = await client.setAutoResetWakeSchedule(connection: connection, unixTimestamp: 0, timeout: .zero)
        guard case .timedOut = result else {
            Issue.record("Request did not time out")
            return
        }
        #expect(!client.isRequestInFlight)
        powerHelper.wakeReply?(0)

        let statusTask = Task {
            await client.fetch(
                connection: connection,
                timeout: .seconds(60),
                onConnectionFailure: { _ in Issue.record("Unexpected connection failure") },
                onTimeout: { Issue.record("Unexpected timeout") }
            )
        }
        try #require(try await powerHelper.statusRequested.wait())
        powerHelper.statusReply?(0, CodexBarSleepOwnershipState.owned.rawValue, 1, true)
        let status = await statusTask.value
        #expect(status?.ownership == .owned)
        #expect(status?.activeClientCount == 1)
        #expect(status?.sleepDisabled == true)
        #expect(!client.isRequestInFlight)
    }
}

private final nonisolated class MonitorConnection: NSXPCConnection {
    let powerHelper: MonitorPowerHelper

    init(powerHelper: MonitorPowerHelper) {
        self.powerHelper = powerHelper
        super.init()
    }

    override func remoteObjectProxyWithErrorHandler(_: @escaping (any Error) -> Void) -> Any {
        powerHelper
    }
}

@MainActor
private final class MonitorPowerHelper: NSObject, CodexBarPowerHelperProtocol {
    let statusRequested = TestCheckpoint()
    let wakeRequested = TestCheckpoint()
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
