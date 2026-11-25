import CryptoKit
import Foundation
import SQLite3

nonisolated struct BridgeConfiguration: Identifiable, Equatable, Sendable {
    static let maximumNameLength = 30

    let id: UUID
    let name: String
    let permissions: BridgePermissions
    var usageCount: Int64 = 0
}

nonisolated struct BridgeTaskRecord {
    let id: String
    let configurationID: UUID
    let project: String
    let title: String
    var latestTurnID: String?
    var status = BridgeTurnStatus.idle
    var updated = Date()
}

final nonisolated class BridgeStore {
    private static let schemaVersion: Int64 = 1
    static let retention: TimeInterval = 30 * 86400
    static var directory: URL {
        AppStoragePaths().rootURL.appendingPathComponent("Bridge", isDirectory: true)
    }

    static let activeStatuses = "(" + BridgeTurnStatus.active.map { "'\($0.rawValue)'" }.joined(separator: ", ") + ")"

    let db: BridgeSQLite

    static func databaseURL(in directory: URL) -> URL {
        directory.appendingPathComponent("bridge.sqlite")
    }

    static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        db = try BridgeSQLite(url: Self.databaseURL(in: directory))
        try db.transaction {
            let version = try db.number("PRAGMA user_version")
            switch version {
            case 0:
                try createSchema()
                try db.run("PRAGMA user_version = \(Self.schemaVersion)")
            case Self.schemaVersion: break
            default: throw StorageCompatibilityError.unsupportedFormat("Bridge", Int(version))
            }
        }
    }

    private func createSchema() throws {
        try db.run("""
        CREATE TABLE configurations (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            token TEXT NOT NULL UNIQUE,
            permissions TEXT NOT NULL CHECK (json_valid(permissions) AND json_type(permissions) = 'object'),
            uses INTEGER NOT NULL DEFAULT 0 CHECK (uses >= 0)
        )
        """)
        try db.run("""
        CREATE TABLE tasks (
            id TEXT PRIMARY KEY NOT NULL,
            configuration TEXT NOT NULL REFERENCES configurations(id) ON DELETE CASCADE,
            project TEXT NOT NULL, title TEXT NOT NULL, turn TEXT,
            status TEXT NOT NULL, updated INTEGER NOT NULL
        )
        """)
        try db.run("""
        CREATE TABLE questions (
            task TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
            item TEXT NOT NULL, turn TEXT NOT NULL, origin TEXT,
            PRIMARY KEY (task, item)
        ) WITHOUT ROWID
        """)
        try db.run("""
        CREATE TRIGGER clear_previous_questions AFTER UPDATE OF turn ON tasks WHEN NEW.turn IS NOT OLD.turn
        BEGIN DELETE FROM questions WHERE task = NEW.id AND turn IS NOT NEW.turn; END
        """)
        try db.run("CREATE INDEX tasks_by_configuration ON tasks (configuration, updated DESC, id DESC)")
        try db.run("""
        CREATE TABLE operations (
            configuration TEXT NOT NULL REFERENCES configurations(id) ON DELETE CASCADE,
            tool TEXT NOT NULL CHECK (tool IN ('codex_start', 'codex_reply')),
            id TEXT NOT NULL, arguments BLOB NOT NULL CHECK (length(arguments) = 32),
            created INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
            task TEXT, turn TEXT, buffer TEXT, sequence INTEGER,
            error TEXT, detail TEXT,
            PRIMARY KEY (configuration, tool, id),
            CHECK (
                (status = 'pending' AND turn IS NULL AND buffer IS NULL AND sequence IS NULL AND error IS NULL AND detail IS NULL) OR
                (status = 'succeeded' AND task IS NOT NULL AND turn IS NOT NULL AND buffer IS NOT NULL
                    AND sequence IS NOT NULL AND sequence >= 0 AND error IS NULL AND detail IS NULL) OR
                (status = 'failed' AND error IS NOT NULL AND turn IS NULL AND buffer IS NULL AND sequence IS NULL)
            )
        ) WITHOUT ROWID
        """)
        try db.run("CREATE INDEX operations_by_date ON operations (created)")
    }

    func addConfiguration(_ configuration: BridgeConfiguration, token: String) throws {
        try db.run("""
        INSERT INTO configurations (id, name, token, permissions) VALUES (?, ?, ?, ?)
        """, [
            .text(configuration.id.uuidString),
            .text(configuration.name),
            .text(token),
            .text(configuration.permissions.jsonText())
        ])
    }

    func updateConfiguration(_ configuration: BridgeConfiguration) throws {
        try db.updateOne("""
        UPDATE configurations SET name = ?, permissions = ? WHERE id = ?
        """, [
            .text(configuration.name), .text(configuration.permissions.jsonText()), .text(configuration.id.uuidString)
        ])
    }

    func configurations() throws -> [BridgeConfiguration] {
        var configurations: [BridgeConfiguration] = []
        try db.rows("SELECT id, name, permissions, uses FROM configurations ORDER BY rowid") { row in
            guard let configurationID = UUID(uuidString: BridgeSQLite.text(row, 0)) else { throw BridgeFailure("invalid_configuration_id") }
            try configurations.append(BridgeConfiguration(
                id: configurationID,
                name: BridgeSQLite.text(row, 1),
                permissions: BridgePermissions.decode(BridgeSQLite.text(row, 2)),
                usageCount: sqlite3_column_int64(row, 3)
            ))
        }
        return configurations
    }

    /// 写锁被占用时返回 nil, 配置已删除时仍须拒绝本次调用
    func addToolUses(_ amount: Int64, for configurationID: UUID) throws -> Int64? {
        let key = BridgeSQLite.Value.text(configurationID.uuidString)
        return try db.withoutWaitingForLock {
            do {
                let count = try db.number("UPDATE configurations SET uses = uses + ? WHERE id = ? RETURNING uses", [.integer(amount), key])
                guard count > 0 else { throw BridgeFailure("unauthorized") }
                return count
            } catch let failure as BridgeSQLite.Failure where failure.code == SQLITE_BUSY {
                guard try db.number("SELECT EXISTS (SELECT 1 FROM configurations WHERE id = ?)", [key]) == 1 else { throw BridgeFailure("unauthorized") }
                return nil
            }
        }
    }

    static func configurationID(forToken token: String, in directory: URL) throws -> UUID? {
        let db = try BridgeSQLite(url: databaseURL(in: directory), readOnly: true)
        var configurationID: UUID?
        try db.rows("SELECT id FROM configurations WHERE token = ?", [.text(token)]) { configurationID = UUID(uuidString: BridgeSQLite.text($0, 0)) }
        return configurationID
    }

    func token(for configurationID: UUID) throws -> String {
        var token: String?
        try db.rows("SELECT token FROM configurations WHERE id = ?", [.text(configurationID.uuidString)]) { token = BridgeSQLite.text($0, 0) }
        guard let token, !token.isEmpty else { throw BridgeFailure("invalid_configuration") }
        return token
    }

    @discardableResult
    func deleteConfiguration(_ configurationID: UUID) throws -> Set<String> {
        try db.transaction {
            let bindings: [BridgeSQLite.Value] = [.text(configurationID.uuidString)]
            var tasks = Set<String>()
            try db.rows("SELECT id FROM tasks WHERE configuration = ?", bindings) { tasks.insert(BridgeSQLite.text($0, 0)) }
            try db.run("DELETE FROM configurations WHERE id = ?", bindings)
            return tasks
        }
    }

    @discardableResult
    func prune(now: Date) throws -> Set<String> {
        let cutoff: [BridgeSQLite.Value] = try [.integer(Self.milliseconds(now.addingTimeInterval(-Self.retention)))]
        return try db.transaction {
            var removed = Set<String>()
            try db.rows("DELETE FROM tasks WHERE updated < ? AND status NOT IN \(Self.activeStatuses) RETURNING id", cutoff) {
                removed.insert(BridgeSQLite.text($0, 0))
            }
            try db.run("""
            DELETE FROM operations WHERE created < ? AND NOT (
                status = 'pending' AND id GLOB 'question/*' AND EXISTS (SELECT 1 FROM tasks WHERE tasks.id = operations.task)
            )
            """, cutoff)
            return removed
        }
    }

    static func milliseconds(_ date: Date) throws -> Int64 {
        guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded()) else { throw BridgeFailure("invalid_timestamp") }
        return value
    }
}
