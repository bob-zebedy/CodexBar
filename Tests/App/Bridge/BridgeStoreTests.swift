import Foundation
import Testing

struct BridgeStoreTests {
    @Test(.tags(.integration))
    func configurationPermissionsValidateOnWriteAndRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeStore(directory: directory)
        let configuration = BridgeConfiguration(id: UUID(), name: "reader", permissions: .init())
        let invalid = BridgeConfiguration(id: configuration.id, name: "invalid", permissions: .init(network: .ask, approval: .deny))
        #expect(throws: BridgeFailure.self) { try store.addConfiguration(invalid, token: "token") }
        try store.addConfiguration(configuration, token: "token")
        #expect(throws: BridgeFailure.self) { try store.updateConfiguration(invalid) }
        #expect(try store.configurations() == [configuration])

        var stored: BridgeJSON?
        try store.db.rows("SELECT permissions FROM configurations") { row in
            stored = try JSONDecoder().decode(BridgeJSON.self, from: Data(BridgeSQLite.text(row, 0).utf8))
        }
        #expect(stored == ["writable": .bool(false), "network": "ask", "approval": "ask"])
        for json in [
            #"{"writable":false,"network":"ask","approval":"deny"}"#,
            #"{"writable":true,"network":"unknown","approval":"ask"}"#,
            #"{"writable":true,"network":"allow"}"#
        ] {
            try store.db.run("UPDATE configurations SET permissions = ?", [.text(json)])
            let failure = #expect(throws: BridgeFailure.self) { try store.configurations() }
            #expect(failure?.code == "invalid_configuration")
        }
    }

    @Test(.tags(.integration))
    func retainedOperationsReplayAcrossReopenAndExpire() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeStore(directory: directory)
        let configurationID = UUID()
        let digest = BridgeStore.digest(Data("token".utf8))
        try store.addConfiguration(BridgeConfiguration(id: configurationID, name: "client", permissions: .init()), token: "token")
        let key = BridgeOperationKey(configurationID: configurationID, tool: .reply, id: "rejected")
        let failure = BridgeFailure("codex_rejected", "rejected")
        #expect(try store.reserve(key, digest: digest, task: "thread") == nil)
        try store.fail(key, error: failure)
        let reopened = try BridgeStore(directory: directory)
        #expect(try reopened.replay(key, digest: digest) == .receipt(failure.result))
        let conflict = #expect(throws: BridgeFailure.self) { try reopened.replay(key, digest: Data()) }
        #expect(conflict?.code == "operation_conflict")
        try reopened.prune(now: Date().addingTimeInterval(BridgeStore.retention + 1))
        #expect(try reopened.replay(key, digest: digest) == nil)
    }

    @Test(.tags(.integration))
    func receiptAndTurnCommitTogetherAndExpireIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeStore(directory: directory)
        let configurationID = UUID()
        let digest = BridgeStore.digest(Data("test".utf8))
        try store.addConfiguration(BridgeConfiguration(id: configurationID, name: "test", permissions: .init()), token: "token")
        let key = BridgeOperationKey(configurationID: configurationID, tool: .start, id: "submit")
        #expect(try store.reserve(key, digest: digest, task: nil) == nil)
        let expired = Date().addingTimeInterval(-BridgeStore.retention - 3600)
        var task = BridgeTaskRecord(id: "thread", configurationID: configurationID, project: "/fixture", title: "", updated: expired)
        try store.recordThread(task, for: key)
        try store.beginFirstTurn(key)
        let cursor = BridgeCursor(epoch: UUID(), task: task.id, turn: "turn", sequence: 0)
        task.latestTurnID = cursor.turn
        task.status = .completed
        try store.db.run("""
        CREATE TEMP TRIGGER fail_receipt BEFORE UPDATE ON operations
        BEGIN SELECT RAISE(ABORT, 'fixture'); END
        """)
        #expect(throws: BridgeSQLite.Failure.self) { try store.complete(key, cursor: cursor, task: task) }
        #expect(try store.task(task.id)?.status == .idle)
        let unknown = #expect(throws: BridgeFailure.self) { try store.replay(key, digest: digest) }
        #expect(unknown?.code == "outcome_unknown")
        #expect(unknown?.detail == task.id)
        try store.db.run("DROP TRIGGER fail_receipt")
        try store.complete(key, cursor: cursor, task: task)
        var active = BridgeTaskRecord(id: "running", configurationID: configurationID, project: "/fixture", title: "", updated: expired)
        active.status = .running
        active.latestTurnID = "active-turn"
        try store.insertTask(active)
        let expiredQuestion = try BridgeOperationKey.question(configurationID, task: task.id, origin: cursor.turn, item: "question")
        let activeQuestion = try BridgeOperationKey.question(configurationID, task: active.id, origin: "active-turn", item: "question")
        _ = try store.reserve(expiredQuestion, digest: digest, task: task.id)
        _ = try store.reserve(activeQuestion, digest: digest, task: active.id)
        try store.db.run("UPDATE operations SET created = ? WHERE status = 'pending'", [.integer(BridgeStore.milliseconds(expired))])

        #expect(try store.prune(now: Date()) == [task.id])
        #expect(try store.task(task.id) == nil)
        #expect(try !store.isPending(expiredQuestion))
        #expect(try store.isPending(activeQuestion))
        #expect(try store.replay(key, digest: digest) == .receipt(cursor.receipt))
    }

    @Test(.tags(.integration))
    func taskPaginationSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try BridgeStore(directory: directory)
        let configurationID = UUID()
        let configuration = BridgeConfiguration(id: configurationID, name: "client", permissions: .init())
        try db.addConfiguration(configuration, token: "test")
        let timestamp = Date(timeIntervalSince1970: 12345.678)
        for index in 0 ..< 45 {
            try db.insertTask(BridgeTaskRecord(id: String(index), configurationID: configurationID, project: directory.path, title: "", updated: timestamp))
        }
        let first = try db.list(configurationID: configurationID, project: nil, status: nil, after: nil, blocking: [])
        #expect(first.count == 41)
        let last = first[39]
        let cursor = BridgeListCursor(configurationID: configurationID, project: nil, status: nil, updated: last.updated, id: last.id)
        let encoded = try #require(try cursor.encoded().text)
        let data = try #require(Data(base64Encoded: encoded))
        let fields = try JSONDecoder().decode(BridgeJSON.self, from: data)
        #expect(fields["owner"] == .string(configurationID.uuidString))
        let reopened = try BridgeStore(directory: directory)
        let next = try reopened.list(configurationID: configurationID, project: nil, status: nil, after: BridgeListCursor.decode(encoded), blocking: [])
        #expect(next.count == 5)
        #expect(Set(first.prefix(40).map(\.id) + next.map(\.id)).count == 45)
    }
}
