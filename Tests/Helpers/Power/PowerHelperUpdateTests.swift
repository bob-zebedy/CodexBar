import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct PowerHelperUpdateTests {
    @Test func updatePreservesExternalSleepSetting() async throws {
        let fixture = try PowerHelperFixture(disabled: true)
        #expect(await fixture.update() == 0)
        #expect(fixture.system.values.withLock { $0.writes } == [])
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.store.record()?.identifier == fixture.updateID)
    }

    @Test func updateKeepsLiveLeaseAndReleaseStillRestoresSleep() async throws {
        let fixture = try PowerHelperFixture(disabled: false)
        #expect(await fixture.request(true, generation: 1).exitCode == 0)
        #expect(fixture.system.values.withLock { $0.disabled })
        #expect(await fixture.update() == 0)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.system.values.withLock { $0.writes } == [true])
        #expect(await fixture.request(false, generation: 2).exitCode == 0)
        #expect(fixture.system.values.withLock { $0.writes } == [true, false])
        #expect(fixture.store.record()?.state == .idle)
    }

    @Test func updateRetriesUnfinishedOwnedRecovery() async throws {
        let fixture = try PowerHelperFixture(disabled: true, ownership: .owned, writeExitCode: -1)
        #expect(fixture.store.record()?.state == .restoring)
        #expect(await fixture.update() != 0)
        #expect(fixture.store.record()?.identifier == nil)
        fixture.system.values.withLock { $0.writeExitCode = 0 }
        #expect(await fixture.update() == 0)
        #expect(!fixture.system.values.withLock { $0.disabled })
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.store.record()?.identifier == fixture.updateID)
    }

    @Test func failedPersistenceDoesNotConsumeUpdateIdentifier() async throws {
        let fixture = try PowerHelperFixture(disabled: true)
        fixture.store.values.withLock { $0.failWrite = true }
        #expect(await fixture.update() != 0)
        #expect(fixture.store.record()?.identifier == nil)
        fixture.store.values.withLock { $0.failWrite = false }
        #expect(await fixture.update() == 0)
        let writes = fixture.store.values.withLock { $0.writes }
        #expect(await fixture.update() == 0)
        #expect(fixture.store.values.withLock { $0.writes } == writes)
        #expect(fixture.system.values.withLock { $0.writes }.isEmpty)
    }

    @Test func failedReadCannotCompleteUpdate() async throws {
        let fixture = try PowerHelperFixture(disabled: true)
        fixture.system.values.withLock { $0.readExitCode = -1 }
        #expect(await fixture.update() != 0)
        #expect(fixture.store.record()?.identifier == nil)
        fixture.system.values.withLock { $0.readExitCode = 0 }
        #expect(await fixture.update() == 0)
        #expect(fixture.system.values.withLock { $0.writes }.isEmpty)
    }
}
