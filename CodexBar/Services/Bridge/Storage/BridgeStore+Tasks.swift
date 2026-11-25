import Foundation
import SQLite3

nonisolated extension BridgeStore {
    private static let taskColumns = "id, configuration, project, title, turn, status, updated"

    private func records(_ predicate: String, _ values: [BridgeSQLite.Value] = []) throws -> [BridgeTaskRecord] {
        var records: [BridgeTaskRecord] = []
        try db.rows("SELECT \(Self.taskColumns) FROM tasks WHERE " + predicate, values) { row in
            guard let configurationID = UUID(uuidString: BridgeSQLite.text(row, 1)) else { throw BridgeFailure("invalid_configuration_id") }
            records.append(BridgeTaskRecord(
                id: BridgeSQLite.text(row, 0),
                configurationID: configurationID,
                project: BridgeSQLite.text(row, 2),
                title: BridgeSQLite.text(row, 3),
                latestTurnID: BridgeSQLite.optionalText(row, 4),
                status: BridgeTurnStatus(rawValue: BridgeSQLite.text(row, 5)) ?? .unknown,
                updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 6)) / 1000)
            ))
        }
        return records
    }

    func task(_ id: String) throws -> BridgeTaskRecord? {
        try records("id = ?", [.text(id)]).first
    }

    func activeTasks() throws -> [BridgeTaskRecord] {
        try records("status IN \(Self.activeStatuses)")
    }

    func forEachTaskID(_ visit: (String) -> Void) throws {
        try db.rows("SELECT id FROM tasks") { visit(BridgeSQLite.text($0, 0)) }
    }

    func list(configurationID: UUID, project: String?, status: String?, after: BridgeListCursor?, blocking: Set<BridgeTurnKey>) throws -> [BridgeTaskRecord] {
        var filters = ["configuration = ?"]
        var values: [BridgeSQLite.Value] = [.text(configurationID.uuidString)]
        if let project {
            filters.append("project = ?")
            values.append(.text(project))
        }
        if let after {
            filters.append("(updated, id) < (?, ?)")
            try values += [.integer(Self.milliseconds(after.updated)), .text(after.id)]
        }
        if let status {
            var expression = "status"
            if !blocking.isEmpty {
                let pairs = Array(repeating: "(?, ?)", count: blocking.count).joined(separator: ", ")
                expression = "CASE WHEN (id, turn) IN (VALUES \(pairs)) THEN 'waiting' ELSE status END"
                for request in blocking {
                    values += [.text(request.task), .text(request.turn)]
                }
            }
            filters.append(expression + " = ?")
            values.append(.text(status))
        }
        return try records(filters.joined(separator: " AND ") + " ORDER BY updated DESC, id DESC LIMIT 41", values)
    }

    func insertTask(_ record: BridgeTaskRecord) throws {
        try db.run(
            "INSERT INTO tasks (\(Self.taskColumns)) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                .text(record.id),
                .text(record.configurationID.uuidString),
                .text(record.project),
                .text(record.title),
                .optional(record.latestTurnID),
                .text(record.status.rawValue),
                .integer(Self.milliseconds(record.updated))
            ]
        )
    }

    func updateTask(_ record: BridgeTaskRecord) throws {
        try db.updateOne(
            "UPDATE tasks SET turn = ?, status = ?, updated = ? WHERE id = ? AND configuration = ?",
            [.optional(record.latestTurnID), .text(record.status.rawValue), .integer(Self.milliseconds(record.updated)), .text(record.id), .text(record.configurationID.uuidString)]
        )
    }

    func markQuestionClosed(task: String, item: String, turn: String) throws {
        try storeQuestion(task: task, item: item, turn: turn, origin: nil)
    }

    func moveCarriedQuestions(task: String, from: String, to: String) throws {
        try db.run("UPDATE questions SET turn = ? WHERE task = ? AND turn = ? AND origin IS NOT NULL", [.text(to), .text(task), .text(from)])
    }

    func carryQuestion(task: String, item: String, from origin: String, to turn: String) throws {
        try storeQuestion(task: task, item: item, turn: turn, origin: origin)
    }

    private func storeQuestion(task: String, item: String, turn: String, origin: String?) throws {
        try db.run("""
        INSERT INTO questions (task, item, turn, origin) VALUES (?, ?, ?, ?)
        ON CONFLICT(task, item) DO UPDATE SET turn = excluded.turn, origin = excluded.origin
        """, [.text(task), .text(item), .text(turn), .optional(origin)])
    }

    func isQuestionClosed(task: String, item: String, turn: String) throws -> Bool {
        try db.number("""
        SELECT EXISTS (SELECT 1 FROM questions WHERE task = ? AND item = ? AND turn = ? AND origin IS NULL)
        """, [.text(task), .text(item), .text(turn)]) == 1
    }

    func questionState(task: String, turn: String) throws -> (closed: Set<String>, carried: [String: Set<String>]) {
        var closed = Set<String>()
        var carried: [String: Set<String>] = [:]
        try db.rows("SELECT item, origin FROM questions WHERE task = ? AND turn = ?", [.text(task), .text(turn)]) { row in
            let item = BridgeSQLite.text(row, 0)
            if let origin = BridgeSQLite.optionalText(row, 1) {
                carried[origin, default: []].insert(item)
            } else {
                closed.insert(item)
            }
        }
        return (closed, carried)
    }
}
