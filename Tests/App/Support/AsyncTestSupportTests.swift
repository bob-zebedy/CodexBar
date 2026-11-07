import Foundation
import Testing

struct AsyncTestSupportTests {
    @Test func missingSignalTimesOutAndLateSignalRemainsObservable() async throws {
        let checkpoint = TestCheckpoint()
        #expect(try await checkpoint.wait(timeout: .milliseconds(20)) == false)
        checkpoint.signal()
        #expect(try await checkpoint.wait(timeout: .zero))
    }

    @Test func boundedWaitRespondsToCancellation() async {
        let checkpoint = TestCheckpoint()
        let task = Task { try await checkpoint.wait(timeout: .seconds(60)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancelledDependencyWaitsForExplicitRelease() async throws {
        let started = TestCheckpoint()
        let checkpoint = TestCheckpoint()
        defer { checkpoint.signal() }
        var returned = false
        let task = Task {
            started.signal()
            await checkpoint.waitIgnoringCancellation()
            returned = true
        }
        task.cancel()
        try #require(try await started.wait())
        #expect(!returned)
        checkpoint.signal()
        await task.value
        #expect(returned)
    }
}
