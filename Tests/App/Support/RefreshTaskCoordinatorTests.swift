import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct RefreshTaskCoordinatorTests {
    @Test func supersededResultCannotCommitOrEndNewerRefresh() async {
        let coordinator = RefreshTaskCoordinator()
        defer { coordinator.cancel() }
        let oldEntered = TestCheckpoint()
        let oldRelease = TestCheckpoint()
        let oldReturned = TestCheckpoint()
        let newEntered = TestCheckpoint()
        let newRelease = TestCheckpoint()
        let newFinished = TestCheckpoint()
        var committed: [Int] = []
        var refreshing: [Bool] = []
        coordinator.run(
            setRefreshing: { refreshing.append($0) },
            operation: {
                oldEntered.signal()
                await oldRelease.wait()
                oldReturned.signal()
                return 1
            },
            commit: { committed.append($0) }
        )
        await oldEntered.wait()
        coordinator.run(
            setRefreshing: {
                refreshing.append($0)
                if !$0 {
                    newFinished.signal()
                }
            },
            operation: {
                newEntered.signal()
                await newRelease.wait()
                return 2
            },
            commit: { committed.append($0) }
        )
        await newEntered.wait()
        oldRelease.signal()
        await oldReturned.wait()
        #expect(committed.isEmpty)
        #expect(refreshing == [true, true])
        newRelease.signal()
        await newFinished.wait()
        #expect(committed == [2])
        #expect(refreshing == [true, true, false])
    }

    @Test func cancellationInvalidatesGenerationEvenIfOperationReturns() async {
        let coordinator = RefreshTaskCoordinator()
        let entered = TestCheckpoint()
        let release = TestCheckpoint()
        let returned = TestCheckpoint()
        var committed = false
        let generation = coordinator.start { generation in
            entered.signal()
            await release.wait()
            committed = coordinator.canCommit(generation)
            returned.signal()
        }
        await entered.wait()
        coordinator.cancel()
        #expect(!coordinator.canCommit(generation))
        release.signal()
        await returned.wait()
        #expect(!committed)
        var finished = false
        let didFinish = coordinator.finish(generation) { finished = true }
        #expect(!didFinish)
        #expect(!finished)
    }
}
