import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HelperUpdateTests {
    @Test func updatePreservesExternalSleepSetting() async throws {
        let fixture = try Fixture(disabled: true)
        #expect(await fixture.update() == 0)
        #expect(fixture.system.values.withLock { $0.writes } == [])
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.store.record()?.identifier == fixture.updateID)
    }

    @Test func updateKeepsLiveLeaseAndReleaseStillRestoresSleep() async throws {
        let fixture = try Fixture(disabled: false)
        #expect(await fixture.request(true, generation: 1) == 0)
        #expect(fixture.system.values.withLock { $0.disabled })
        #expect(await fixture.update() == 0)
        #expect(fixture.store.record()?.state == .owned)
        #expect(fixture.system.values.withLock { $0.writes } == [true])
        #expect(await fixture.request(false, generation: 2) == 0)
        #expect(fixture.system.values.withLock { $0.writes } == [true, false])
        #expect(fixture.store.record()?.state == .idle)
    }

    @Test func updateRetriesUnfinishedOwnedRecovery() async throws {
        let fixture = try Fixture(disabled: true, ownership: .owned, failWrite: true)
        #expect(fixture.store.record()?.state == .restoring)
        #expect(await fixture.update() != 0)
        #expect(fixture.store.record()?.identifier == nil)
        fixture.system.values.withLock { $0.failWrite = false }
        #expect(await fixture.update() == 0)
        #expect(!fixture.system.values.withLock { $0.disabled })
        #expect(fixture.store.record()?.state == .idle)
        #expect(fixture.store.record()?.identifier == fixture.updateID)
    }

    @Test func failedPersistenceDoesNotConsumeUpdateIdentifier() async throws {
        let fixture = try Fixture(disabled: true)
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
        let fixture = try Fixture(disabled: true)
        fixture.system.values.withLock { $0.failRead = true }
        #expect(await fixture.update() != 0)
        #expect(fixture.store.record()?.identifier == nil)
        fixture.system.values.withLock { $0.failRead = false }
        #expect(await fixture.update() == 0)
        #expect(fixture.system.values.withLock { $0.writes }.isEmpty)
    }
}

private struct Fixture {
    let store: MemoryOwnership
    let system: FakeSleepSystem
    let runtime: HelperRuntime
    let session: any CodexBarHelperProtocol
    let connection: TestConnection
    let clientID = UUID().uuidString
    let updateID = String(repeating: "a", count: 64)

    init(disabled: Bool, ownership: SleepOwnership = .idle, failWrite: Bool = false) throws {
        store = try MemoryOwnership(state: ownership)
        system = FakeSleepSystem(disabled: disabled, failWrite: failWrite)
        runtime = HelperRuntime(ownershipStore: store, sleepOperations: system.operations)
        runtime.recoverOwnershipAtStartup()
        connection = TestConnection()
        precondition(runtime.listener(NSXPCListener.anonymous(), shouldAcceptNewConnection: connection))
        session = try #require(connection.exportedObject as? any CodexBarHelperProtocol)
    }

    func update() async -> Int32 {
        await withCheckedContinuation { continuation in
            session.resetSleepAfterUpdate(updateID) { continuation.resume(returning: $0) }
        }
    }

    func request(_ requested: Bool, generation: UInt64) async -> Int32 {
        await withCheckedContinuation { continuation in
            session.setSleepPreventionRequested(requested, clientSessionID: clientID, generation: generation) { code, _, _ in
                continuation.resume(returning: code)
            }
        }
    }
}

private final class TestConnection: NSXPCConnection, @unchecked Sendable {
    override func resume() {}
}

private final class MemoryOwnership: OwnershipStoring, Sendable {
    struct State: Sendable {
        var data: Data
        var failWrite = false
        var writes = 0
    }

    let url = URL(fileURLWithPath: "/unused-helper-test-state")
    let values: Mutex<State>

    init(state: SleepOwnership) throws {
        let record = SleepOwnershipRecord(schema: 1, state: state, transaction: UUID(), identifier: nil, updated: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        values = try Mutex(State(data: encoder.encode(record)))
    }

    func ensureOwnershipDirectory() throws {}
    func writeOwnershipDataDurably(_ data: Data) throws {
        try values.withLock {
            if $0.failWrite {
                throw CocoaError(.fileWriteUnknown)
            }
            $0.data = data
            $0.writes += 1
        }
    }

    func record() -> SleepOwnershipRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SleepOwnershipRecord.self, from: values.withLock { $0.data })
    }

    func ownershipRecordState() -> OwnershipRecordState {
        record().map(OwnershipRecordState.present) ?? .absent
    }
}

private final class FakeSleepSystem: Sendable {
    struct State: Sendable {
        var disabled: Bool
        var failWrite: Bool
        var failRead = false
        var writes: [Bool] = []
    }

    let values: Mutex<State>
    init(disabled: Bool, failWrite: Bool) {
        values = Mutex(State(disabled: disabled, failWrite: failWrite))
    }

    var operations: HelperSleepOperations {
        HelperSleepOperations(read: { [self] in
            values.withLock { (PmsetResult(exitCode: $0.failRead ? -1 : 0, output: ""), $0.failRead ? nil : $0.disabled) }
        }, write: { [self] disabled in
            values.withLock {
                if $0.failWrite {
                    return PmsetResult(exitCode: -1, output: "test failure")
                }
                $0.disabled = disabled
                $0.writes.append(disabled)
                return PmsetResult(exitCode: 0, output: "")
            }
        })
    }
}
