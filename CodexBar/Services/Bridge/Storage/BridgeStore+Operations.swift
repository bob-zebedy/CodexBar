import Foundation
import SQLite3

nonisolated struct BridgeOperationKey {
    let configurationID: UUID
    let tool: BridgeTool
    let id: String

    static func question(_ configurationID: UUID, task: String, origin: String, item: String) throws -> Self {
        let identity: BridgeJSON = [.string(task), .string(origin), .string(item)]
        return try Self(configurationID: configurationID, tool: .reply, id: "question/" + identity.jsonText())
    }

    var bindings: [BridgeSQLite.Value] {
        [.text(configurationID.uuidString), .text(tool.rawValue), .text(id)]
    }
}

nonisolated extension BridgeStore {
    private static let operationPredicate = "configuration = ? AND tool = ? AND id = ?"

    enum SavedOperation: Equatable {
        case receipt(BridgeJSON)
        case firstTurnPending(task: String)
    }

    func replay(_ key: BridgeOperationKey, digest: Data) throws -> SavedOperation? {
        var result: SavedOperation?
        try db.rows("""
        SELECT arguments, status, task, turn, buffer, sequence, error, detail
        FROM operations WHERE \(Self.operationPredicate)
        """, key.bindings) { row in
            guard BridgeSQLite.blob(row, 0) == digest else { throw BridgeFailure("operation_conflict") }
            switch BridgeSQLite.text(row, 1) {
            case "succeeded":
                guard let epoch = UUID(uuidString: BridgeSQLite.text(row, 4)) else { throw BridgeFailure("invalid_cursor") }
                result = .receipt(BridgeCursor(epoch: epoch, task: BridgeSQLite.text(row, 2), turn: BridgeSQLite.text(row, 3), sequence: Int(sqlite3_column_int64(row, 5))).receipt)
            case "failed":
                let code = BridgeSQLite.text(row, 6)
                if code == "first_turn_not_sent" {
                    result = .firstTurnPending(task: BridgeSQLite.text(row, 2))
                } else {
                    result = .receipt(BridgeFailure(code, BridgeSQLite.text(row, 7)).result)
                }
            default: throw BridgeFailure("outcome_unknown", BridgeSQLite.text(row, 2))
            }
        }
        return result
    }

    func reserve(_ key: BridgeOperationKey, digest: Data, task: String?) throws -> BridgeJSON? {
        try db.transaction {
            if let replay = try replay(key, digest: digest) {
                switch replay {
                case let .receipt(value): return value
                case let .firstTurnPending(task): throw BridgeFailure("outcome_unknown", task)
                }
            }
            guard try db.number("SELECT count(*) FROM operations") < 20000 else { throw BridgeFailure("capacity_reached") }
            if key.tool == .start, try db.number("SELECT count(*) FROM tasks") >= 2000 {
                throw BridgeFailure("capacity_reached")
            }
            try db.run(
                "INSERT INTO operations (configuration, tool, id, arguments, task, created) VALUES (?, ?, ?, ?, ?, ?)",
                key.bindings + [.blob(digest), .optional(task), .integer(Self.milliseconds(Date()))]
            )
            return nil
        }
    }

    func recordThread(_ record: BridgeTaskRecord, for key: BridgeOperationKey) throws {
        try db.transaction {
            try insertTask(record)
            try db.updateOne("UPDATE operations SET task = ?, status = 'failed', error = 'first_turn_not_sent' WHERE \(Self.operationPredicate) AND status = 'pending'", [.text(record.id)] + key.bindings)
        }
    }

    func beginFirstTurn(_ key: BridgeOperationKey) throws {
        try db.updateOne("""
        UPDATE operations SET status = 'pending', error = NULL
        WHERE \(Self.operationPredicate) AND status = 'failed' AND error = 'first_turn_not_sent'
        """, key.bindings)
    }

    func complete(_ key: BridgeOperationKey, cursor: BridgeCursor, task: BridgeTaskRecord?, beforeTurnUpdate: () throws -> Void = {}) throws {
        try db.transaction {
            try beforeTurnUpdate()
            if let task {
                try updateTask(task)
            }
            try db.updateOne("""
            UPDATE operations SET status = 'succeeded', task = ?, turn = ?, buffer = ?, sequence = ?
            WHERE \(Self.operationPredicate) AND status = 'pending'
            """, [.text(cursor.task), .text(cursor.turn), .text(cursor.epoch.uuidString), .integer(Int64(cursor.sequence))] + key.bindings)
        }
    }

    func hasUnconfirmedQuestionReply(for record: BridgeTaskRecord) throws -> Bool {
        try db.number("""
        SELECT EXISTS (SELECT 1 FROM operations WHERE configuration = ? AND tool = 'codex_reply'
            AND task = ? AND id GLOB 'question/*' AND status = 'pending')
        """, [.text(record.configurationID.uuidString), .text(record.id)]) == 1
    }

    func isPending(_ key: BridgeOperationKey) throws -> Bool {
        try db.number("SELECT EXISTS (SELECT 1 FROM operations WHERE \(Self.operationPredicate) AND status = 'pending')", key.bindings) == 1
    }

    func hasPendingReply(_ key: BridgeOperationKey, message: String) throws -> Bool {
        try db.number(
            "SELECT EXISTS (SELECT 1 FROM operations WHERE \(Self.operationPredicate) AND status = 'pending' AND arguments = ?)",
            key.bindings + [.blob(Self.digest(Data(message.utf8)))]
        ) == 1
    }

    func release(_ key: BridgeOperationKey) throws {
        try db.run("DELETE FROM operations WHERE \(Self.operationPredicate) AND status = 'pending'", key.bindings)
    }

    func fail(_ key: BridgeOperationKey, error: BridgeFailure) throws {
        try db.updateOne(
            "UPDATE operations SET status = 'failed', error = ?, detail = ? WHERE \(Self.operationPredicate) AND status = 'pending'",
            [.text(error.code), .optional(error.detail.isEmpty ? nil : error.detail)] + key.bindings
        )
    }
}
