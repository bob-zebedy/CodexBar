import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PowerHelperSleepTests {
    @Test func acquisitionPersistsOwnershipBeforeDisablingAndReleaseRestores() async throws {
        let fixture = try PowerHelperFixture(disabled: false)
        let acquired = await fixture.request(true, generation: 1)
        #expect(acquired.exitCode == 0)
        #expect(acquired.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(acquired.sleepDisabled)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite } == [.owned])

        let released = await fixture.request(false, generation: 2)
        #expect(released.exitCode == 0)
        #expect(!released.sleepDisabled)
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.system.values.withLock { $0.writes } == [true, false])
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite } == [.owned, .restoring])
    }

    @Test func externalSleepSettingIsNeitherClaimedNorRestored() async throws {
        let fixture = try PowerHelperFixture(disabled: true)
        let acquired = await fixture.request(true, generation: 1)
        #expect(acquired.exitCode == 0)
        #expect(acquired.source == CodexBarSleepPreventionSource.external.rawValue)
        #expect(acquired.sleepDisabled)

        let released = await fixture.request(false, generation: 2)
        #expect(released.exitCode == 0)
        #expect(released.sleepDisabled)
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.store.values.withLock { $0.writes } == 0)
        #expect(fixture.system.values.withLock { $0.writes }.isEmpty)
    }

    @Test(arguments: [false, true])
    func ownedRequestOnlyReassertsSleepWhenNeeded(systemWasChanged: Bool) async throws {
        let fixture = try await makeFixture(alreadyOwned: true)
        let transaction = fixture.store.record()?.transaction
        let persistedWrites = fixture.store.values.withLock { $0.writes }
        fixture.system.values.withLock { $0.disabled = !systemWasChanged }

        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == 0)
        #expect(result.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(result.sleepDisabled)
        #expect(fixture.store.record()?.transaction == transaction)
        #expect(fixture.store.values.withLock { $0.writes } == persistedWrites)
        #expect(fixture.system.values.withLock { $0.writes } == (systemWasChanged ? [true, true] : [true]))
    }

    @Test(arguments: [false, true], [Int32(-7), 0])
    func unreadableSleepStateDoesNotTriggerWrites(alreadyOwned: Bool, exitCode: Int32) async throws {
        let fixture = try await makeFixture(alreadyOwned: alreadyOwned)
        let persistedWrites = fixture.store.values.withLock { $0.writes }
        let systemWrites = fixture.system.values.withLock { $0.writes }
        fixture.system.values.withLock { $0.scriptedReads = [(exitCode, nil)] }

        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == (exitCode == 0 ? -1 : exitCode))
        #expect(result.source == (alreadyOwned ? CodexBarSleepPreventionSource.codexBar : .none).rawValue)
        #expect(!result.sleepDisabled)
        #expect(fixture.store.values.withLock { $0.writes } == persistedWrites)
        #expect(fixture.system.values.withLock { $0.writes } == systemWrites)
    }

    @Test(arguments: [false, true])
    func failedInitialPersistenceDoesNotDisableSleepAndCanRetry(discardWrite: Bool) async throws {
        let fixture = try PowerHelperFixture(disabled: false)
        fixture.store.values.withLock {
            $0.failWrite = !discardWrite
            $0.discardsWrites = discardWrite
        }
        let failed = await fixture.request(true, generation: 1)
        #expect(failed.exitCode == -1)
        #expect(failed.source == CodexBarSleepPreventionSource.none.rawValue)
        #expect(!failed.sleepDisabled)
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.system.values.withLock { $0.writes }.isEmpty)

        fixture.store.values.withLock {
            $0.failWrite = false
            $0.discardsWrites = false
        }
        #expect(await fixture.request(true, generation: 2).exitCode == 0)
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite } == [.owned])
    }

    @Test(arguments: [false, true])
    func lostOwnedRecordIsRepairedBeforeAnySleepWrite(systemWasChanged: Bool) async throws {
        let fixture = try await makeFixture(alreadyOwned: true)
        let transaction = fixture.store.record()?.transaction
        fixture.store.values.withLock { $0.data = Data() }
        fixture.system.values.withLock { $0.disabled = !systemWasChanged }

        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == 0)
        #expect(result.sleepDisabled)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.store.record()?.transaction == transaction)
        #expect(fixture.system.values.withLock { $0.writes } == (systemWasChanged ? [true, true] : [true]))
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite.allSatisfy { $0 == .owned } })
    }

    @Test func failedOwnedRecordRepairRestoresSleepBeforeReturningFailure() async throws {
        let fixture = try await makeFixture(alreadyOwned: true)
        fixture.store.values.withLock {
            $0.data = Data()
            $0.failedWriteStates = [.owned]
        }
        fixture.system.values.withLock { $0.disabled = false }

        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == -1)
        #expect(result.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(!result.sleepDisabled)
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.system.values.withLock { $0.writes } == [true, false])
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite } == [.owned, .restoring])
    }

    @Test(arguments: [false, true])
    func failedSystemWriteRetainsOwnershipForRelease(alreadyOwned: Bool) async throws {
        let fixture = try await makeFixture(alreadyOwned: alreadyOwned)
        fixture.system.values.withLock {
            $0.disabled = false
            $0.writeExitCode = -23
        }
        let reads = fixture.system.values.withLock { $0.reads }
        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == -23)
        #expect(result.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(!result.sleepDisabled)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.system.values.withLock { $0.reads } == reads + 1)

        fixture.system.values.withLock { $0.writeExitCode = 0 }
        #expect(await fixture.request(false, generation: 3).exitCode == 0)
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.system.values.withLock { $0.writes.last } == false)
    }

    @Test(arguments: [false, true], [Int32(-9), 0])
    func failedReadbackCannotReportSuccessfulSleepPrevention(alreadyOwned: Bool, exitCode: Int32) async throws {
        let fixture = try await makeFixture(alreadyOwned: alreadyOwned)
        fixture.system.values.withLock {
            $0.disabled = false
            $0.scriptedReads = [(0, false), (exitCode, nil)]
        }
        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == (exitCode == 0 ? -1 : exitCode))
        #expect(result.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(!result.sleepDisabled)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.system.values.withLock { $0.disabled })
    }

    @Test(arguments: [false, true])
    func unchangedSleepStateAfterWriteIsReportedAsFailure(alreadyOwned: Bool) async throws {
        let fixture = try await makeFixture(alreadyOwned: alreadyOwned)
        fixture.system.values.withLock {
            $0.disabled = false
            $0.ignoresWrites = true
        }
        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == -1)
        #expect(result.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(!result.sleepDisabled)
        #expect(fixture.store.record()?.state == .owned)
    }

    @Test(arguments: [false, true], [false, true])
    func recordLostDuringSystemWriteIsRepairedOrSleepIsRestored(alreadyOwned: Bool, repairFails: Bool) async throws {
        let fixture = try await makeFixture(alreadyOwned: alreadyOwned)
        let store = fixture.store
        fixture.system.values.withLock {
            $0.disabled = false
            $0.afterWrite = { disabled in
                guard disabled else { return }
                store.values.withLock {
                    $0.data = Data()
                    $0.failedWriteStates = repairFails ? [.owned] : []
                }
            }
        }
        let previousWrites = fixture.system.values.withLock { $0.writes }
        let result = await fixture.request(true, generation: 2)
        #expect(result.exitCode == (repairFails ? -1 : 0))
        #expect(result.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(result.sleepDisabled == !repairFails)
        #expect(fixture.store.record()?.state == (repairFails ? .idle : .owned))
        #expect(fixture.system.values.withLock { $0.writes } == previousWrites + (repairFails ? [true, false] : [true]))
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite.last } == (repairFails ? .restoring : .owned))
    }

    @Test func pendingRestoreMustFinishBeforeAcquiringSleepAgain() async throws {
        let fixture = try PowerHelperFixture(disabled: true, ownership: .owned, writeExitCode: -23)
        let failed = await fixture.request(true, generation: 1)
        #expect(failed.exitCode == -23)
        #expect(failed.source == CodexBarSleepPreventionSource.codexBar.rawValue)
        #expect(failed.sleepDisabled)
        #expect(fixture.store.record()?.state == .restoring)
        #expect(fixture.system.values.withLock { $0.writes } == [false, false])

        fixture.system.values.withLock { $0.writeExitCode = 0 }
        let retried = await fixture.request(true, generation: 2)
        #expect(retried.exitCode == 0)
        #expect(retried.sleepDisabled)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.system.values.withLock { $0.writes } == [false, false, false, true])
        #expect(fixture.system.values.withLock { $0.ownershipAtWrite } == [.restoring, .restoring, .restoring, .owned])
    }

    private func makeFixture(alreadyOwned: Bool) async throws -> PowerHelperFixture {
        let fixture = try PowerHelperFixture(disabled: false)
        if alreadyOwned {
            let acquired = await fixture.request(true, generation: 1)
            try #require(acquired.exitCode == 0)
        }
        return fixture
    }
}
