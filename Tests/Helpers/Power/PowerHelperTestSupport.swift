import Foundation
import Synchronization
import Testing

struct PowerHelperFixture {
    struct SleepReply: Sendable {
        let exitCode: Int32
        let source: Int
        let sleepDisabled: Bool
    }

    let store: MemoryOwnership
    let system: FakeSleepSystem
    let runtime: PowerHelperRuntime
    let session: any CodexBarPowerHelperProtocol
    let connection: TestConnection
    let clientID = UUID().uuidString
    let updateID = String(repeating: "a", count: 64)

    init(disabled: Bool, ownership: SleepOwnership = .idle, writeExitCode: Int32 = 0) throws {
        store = try MemoryOwnership(state: ownership)
        system = FakeSleepSystem(disabled: disabled, writeExitCode: writeExitCode, store: store)
        runtime = PowerHelperRuntime(ownershipStore: store, sleepOperations: system.operations)
        runtime.recoverOwnershipAtStartup()
        connection = TestConnection()
        precondition(runtime.listener(NSXPCListener.anonymous(), shouldAcceptNewConnection: connection))
        session = try #require(connection.exportedObject as? any CodexBarPowerHelperProtocol)
    }

    func update() async -> Int32 {
        await withCheckedContinuation { continuation in
            session.resetSleepAfterUpdate(updateID) { continuation.resume(returning: $0) }
        }
    }

    func request(_ requested: Bool, generation: UInt64) async -> SleepReply {
        await withCheckedContinuation { continuation in
            session.setSleepPreventionRequested(requested, clientSessionID: clientID, generation: generation) { code, source, disabled in
                continuation.resume(returning: SleepReply(exitCode: code, source: source, sleepDisabled: disabled))
            }
        }
    }
}

final class TestConnection: NSXPCConnection, @unchecked Sendable {
    override func resume() {}
}

final class MemoryOwnership: OwnershipStoring, Sendable {
    struct State: Sendable {
        var data: Data
        var failWrite = false
        var failedWriteStates = Set<SleepOwnership>()
        var discardsWrites = false
        var writes = 0
    }

    let url = URL(fileURLWithPath: "/unused-power-helper-test-state")
    let values: Mutex<State>

    init(state: SleepOwnership) throws {
        let record = SleepOwnershipRecord(schema: 1, state: state, transaction: UUID(), identifier: nil, updated: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        values = try Mutex(State(data: encoder.encode(record)))
    }

    func ensureOwnershipDirectory() throws {}

    func writeOwnershipDataDurably(_ data: Data) throws {
        let record = try #require(Self.decode(data))
        try values.withLock {
            if $0.failWrite || $0.failedWriteStates.contains(record.state) {
                throw CocoaError(.fileWriteUnknown)
            }
            if !$0.discardsWrites {
                $0.data = data
            }
            $0.writes += 1
        }
    }

    func record() -> SleepOwnershipRecord? {
        Self.decode(values.withLock { $0.data })
    }

    func ownershipRecordState() -> OwnershipRecordState {
        record().map(OwnershipRecordState.present) ?? .absent
    }

    private static func decode(_ data: Data) -> SleepOwnershipRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SleepOwnershipRecord.self, from: data)
    }
}

final class FakeSleepSystem: Sendable {
    struct State: Sendable {
        var disabled: Bool
        var writeExitCode: Int32
        var readExitCode: Int32 = 0
        var scriptedReads: [(exitCode: Int32, value: Bool?)] = []
        var ignoresWrites = false
        var afterWrite: (@Sendable (Bool) -> Void)?
        var reads = 0
        var writes: [Bool] = []
        var ownershipAtWrite: [SleepOwnership?] = []
    }

    let values: Mutex<State>
    private let store: MemoryOwnership

    init(disabled: Bool, writeExitCode: Int32, store: MemoryOwnership) {
        values = Mutex(State(disabled: disabled, writeExitCode: writeExitCode))
        self.store = store
    }

    var operations: PowerHelperSleepOperations {
        PowerHelperSleepOperations(read: { [self] in
            values.withLock {
                $0.reads += 1
                if !$0.scriptedReads.isEmpty {
                    let read = $0.scriptedReads.removeFirst()
                    return (PmsetResult(exitCode: read.exitCode, output: ""), read.value)
                }
                return (PmsetResult(exitCode: $0.readExitCode, output: ""), $0.readExitCode == 0 ? $0.disabled : nil)
            }
        }, write: { [self] disabled in
            let ownership = store.record()?.state
            let result = values.withLock { state -> (Int32, (@Sendable (Bool) -> Void)?) in
                state.writes.append(disabled)
                state.ownershipAtWrite.append(ownership)
                guard state.writeExitCode == 0 else {
                    return (state.writeExitCode, nil)
                }
                if !state.ignoresWrites {
                    state.disabled = disabled
                }
                return (0, state.afterWrite)
            }
            result.1?(disabled)
            return PmsetResult(exitCode: result.0, output: "")
        })
    }
}
