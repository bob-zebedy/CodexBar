import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RefreshTaskCoordinatorTests {
    @Test func supersededResultCannotCommitOrEndNewerRefresh() async throws {
        let coordinator = RefreshTaskCoordinator()
        let oldEntered = TestCheckpoint()
        let oldRelease = TestCheckpoint()
        let oldReturned = TestCheckpoint()
        let newEntered = TestCheckpoint()
        let newRelease = TestCheckpoint()
        let newFinished = TestCheckpoint()
        defer {
            coordinator.cancel()
            oldRelease.signal()
            newRelease.signal()
        }
        var committed: [Int] = []
        var refreshing: [Bool] = []
        coordinator.run(
            setRefreshing: { refreshing.append($0) },
            operation: {
                oldEntered.signal()
                await oldRelease.waitIgnoringCancellation()
                oldReturned.signal()
                return 1
            },
            commit: { committed.append($0) }
        )
        try #require(try await oldEntered.wait())
        coordinator.run(
            setRefreshing: {
                refreshing.append($0)
                if !$0 {
                    newFinished.signal()
                }
            },
            operation: {
                newEntered.signal()
                await newRelease.waitIgnoringCancellation()
                return 2
            },
            commit: { committed.append($0) }
        )
        try #require(try await newEntered.wait())
        oldRelease.signal()
        try #require(try await oldReturned.wait())
        #expect(committed.isEmpty)
        #expect(refreshing == [true, true])
        newRelease.signal()
        try #require(try await newFinished.wait())
        #expect(committed == [2])
        #expect(refreshing == [true, true, false])
    }

    @Test func cancellationInvalidatesGenerationEvenIfOperationReturns() async throws {
        let coordinator = RefreshTaskCoordinator()
        let entered = TestCheckpoint()
        let release = TestCheckpoint()
        let returned = TestCheckpoint()
        defer {
            coordinator.cancel()
            release.signal()
        }
        var committed = false
        let generation = coordinator.start { generation in
            entered.signal()
            await release.waitIgnoringCancellation()
            committed = coordinator.canCommit(generation)
            returned.signal()
        }
        try #require(try await entered.wait())
        coordinator.cancel()
        #expect(!coordinator.canCommit(generation))
        release.signal()
        try #require(try await returned.wait())
        #expect(!committed)
        var finished = false
        let didFinish = coordinator.finish(generation) { finished = true }
        #expect(!didFinish)
        #expect(!finished)
    }
}
