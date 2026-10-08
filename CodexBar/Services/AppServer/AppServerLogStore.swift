import Foundation
import os
import SQLite3

nonisolated struct AppServerLogPage: Sendable {
    let entries: [AppServerLogEntry]
    let revision: Int64
    let generation: Int64
    let total: Int
    let hasMore: Bool
}

/// SQLite 连接和全部可变状态仅在 queue 上访问, 请求线程只提交有序写入
final nonisolated class AppServerLogStore: @unchecked Sendable {
    #if CODEXBAR_TESTING
        static let shared = AppServerLogStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarTestLogs-\(UUID().uuidString)"))
    #else
        static let shared = AppServerLogStore(directoryURL: defaultDirectory)
    #endif

    static var defaultDirectory: URL {
        AppStorage.directoryURL().appendingPathComponent("Logs", isDirectory: true)
    }

    static let databaseName = "logs.sqlite"

    struct Limits: Sendable {
        var entries = 10000
        var bytes = 50 * 1024 * 1024
        var bodyBytes = 128 * 1024
        var pageEntries = 1000
    }

    private let limits: Limits
    private var storedBytes = 0
    private var storedCount = 0
    private var needsCheckpoint = false
    private let admissionLock = NSLock()
    private var queuedBytes = 0
    private var droppedEntries = 0
    private let directoryURL: URL
    private let queue = DispatchQueue(label: "CodexBar.request-log", qos: .utility)
    private var database: OpaquePointer?
    private var writeError: String?
    private var isFinished = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directoryURL: URL, limits: Limits = Limits()) {
        self.limits = limits
        self.directoryURL = directoryURL
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    func beginRequest(method: String, payload: String, connection: String? = nil, source: AppServerLogEntry.Source = .request) -> UUID {
        let entry = AppServerLogEntry(id: UUID(), connection: connection, requestedAt: Date(), source: source, status: .pending, method: method, request: payload)
        append(entry)
        return entry.id
    }

    func finishRequest(_ id: UUID, response: String) {
        complete(id, status: .success, detail: response)
    }

    func failRequest(_ id: UUID, message: String) {
        complete(id, status: .failure, detail: message)
    }

    func recordSent(method: String, payload: String, connection: String? = nil, error: String? = nil) {
        let now = Date()
        append(AppServerLogEntry(
            id: UUID(),
            connection: connection,
            requestedAt: now,
            respondedAt: now,
            source: .sent,
            status: error == nil ? .success : .failure,
            method: method,
            request: payload,
            detail: error
        ))
    }

    func recordFailure(
        method: String? = nil,
        message: String,
        connection: String? = nil,
        source: AppServerLogEntry.Source = .local
    ) {
        append(AppServerLogEntry(
            id: UUID(),
            connection: connection,
            requestedAt: Date(),
            source: source,
            status: .failure,
            method: method,
            request: nil,
            detail: message
        ))
    }

    func recordReceived(method: String, payload: String, connection: String) {
        let now = Date()
        append(AppServerLogEntry(
            id: UUID(),
            connection: connection,
            requestedAt: now,
            respondedAt: now,
            source: .received,
            status: .information,
            method: method,
            request: nil,
            detail: payload
        ))
    }

    @discardableResult
    func recordConnection(method: String, detail: String, connection: String, status: AppServerLogEntry.Status) -> UUID {
        let entry = AppServerLogEntry(
            id: UUID(),
            connection: connection,
            requestedAt: Date(),
            source: .connection,
            status: status,
            method: method,
            request: nil,
            detail: detail
        )
        append(entry)
        return entry.id
    }

    func page(before position: Int64? = nil, limit: Int = 100) async throws -> AppServerLogPage {
        try await perform { storage in
            let limit = min(max(1, limit), storage.limits.pageEntries)
            let stats = try storage.stats()
            let entries = try storage.read(
                "SELECT position, payload, id FROM entries WHERE position < ? ORDER BY position DESC LIMIT ?",
                values: [position ?? Int64.max, Int64(max(1, limit) + 1)]
            )
            return AppServerLogPage(
                entries: Array(entries.prefix(max(1, limit))), revision: stats.revision,
                generation: stats.generation, total: stats.total, hasMore: entries.count > max(1, limit)
            )
        }
    }

    func changes(since revision: Int64) async throws -> AppServerLogPage {
        try await perform { storage in
            let stats = try storage.stats()
            let entries = stats.revision == revision ? [] : try storage.read(
                "SELECT position, payload, id FROM entries WHERE revision > ? ORDER BY position DESC LIMIT ?", values: [revision, Int64(storage.limits.pageEntries + 1)]
            )
            return AppServerLogPage(
                entries: Array(entries.prefix(storage.limits.pageEntries)),
                revision: stats.revision,
                generation: stats.generation,
                total: stats.total,
                hasMore: entries.count > storage.limits.pageEntries
            )
        }
    }

    func clear() async throws {
        try await perform { storage in
            try storage.transaction {
                try storage.execute("DELETE FROM entries")
                try storage.execute("UPDATE metadata SET revision = revision + 1, generation = generation + 1, total = 0")
            }
            storage.storedBytes = 0
            storage.storedCount = 0
            storage.writeError = nil
            try storage.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// 正常退出时排空已提交写入, 之后到达的网络回调不再追加日志
    func finish() async throws {
        try await perform { storage in
            storage.isFinished = true
            try storage.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private func append(_ entry: AppServerLogEntry) {
        let entry = entry.bounded(to: limits.bodyBytes)
        enqueue(cost: (entry.request?.utf8.count ?? 0) + (entry.detail?.utf8.count ?? 0)
            + (entry.method?.utf8.count ?? 0) + (entry.connection?.utf8.count ?? 0) + 1024) { storage in
                try storage.transaction { try storage.save(entry, inserting: true) }
            }
    }

    private func complete(_ id: UUID, status: AppServerLogEntry.Status, detail: String) {
        let completed = Date()
        let originalBytes = detail.utf8.count
        let detail = AppServerLogEntry.truncated(detail, limit: limits.bodyBytes)
        enqueue(cost: detail.utf8.count + 1024) { storage in
            try storage.transaction {
                let statement = try storage.prepare("SELECT position, payload, id FROM entries WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                try storage.bind(id.uuidString, to: statement, at: 1)
                guard try storage.step(statement) == SQLITE_ROW else { return }
                guard var entry = storage.decode(statement, skipCorrupt: true) else { return }
                entry.status = status
                entry.detail = detail
                entry.detailOriginalBytes = originalBytes > storage.limits.bodyBytes ? originalBytes : nil
                entry.respondedAt = completed
                try storage.save(entry, inserting: false)
            }
        }
    }

    private func enqueue(cost: Int, _ operation: @escaping @Sendable (AppServerLogStore) throws -> Void) {
        admissionLock.lock()
        guard queuedBytes + cost <= limits.bytes else {
            droppedEntries += 1
            admissionLock.unlock()
            return
        }
        queuedBytes += cost
        admissionLock.unlock()
        queue.async { [self] in
            defer {
                admissionLock.lock()
                queuedBytes -= cost
                admissionLock.unlock()
            }
            guard !isFinished else { return }
            do {
                try open()
                try operation(self)
                if needsCheckpoint {
                    try execute("PRAGMA wal_checkpoint(TRUNCATE)")
                    try execute("PRAGMA incremental_vacuum(256)")
                    needsCheckpoint = false
                }
                writeError = nil
            } catch {
                writeError = String(localized: "log.persistence.error.write")
                // 不把包含请求正文的数据库错误写入系统日志
                AppLog.app.error("请求日志写入失败")
            }
        }
    }

    private func perform<Value: Sendable>(_ operation: @escaping @Sendable (AppServerLogStore) throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try open()
                    admissionLock.lock()
                    let dropped = droppedEntries
                    droppedEntries = 0
                    admissionLock.unlock()
                    if dropped > 0, !isFinished {
                        let entry = AppServerLogEntry(
                            id: UUID(),
                            requestedAt: Date(),
                            source: .local, status: .failure,
                            method: "log/backpressure",
                            request: nil,
                            detail: "Skipped \(dropped) log entries because the write buffer was full"
                        )
                        try transaction { try save(entry, inserting: true) }
                    }
                    let result = try operation(self)
                    if let writeError {
                        throw StorageError(message: writeError)
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var opened: OpaquePointer?
        let path = directoryURL.appendingPathComponent(Self.databaseName).path
        guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let opened {
                sqlite3_close(opened)
            }
            throw StorageError(message: String(localized: "log.persistence.error.read"))
        }
        database = opened
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            sqlite3_busy_timeout(database, 3000)
            if try scalar("PRAGMA auto_vacuum") != 2 {
                try execute("PRAGMA auto_vacuum = INCREMENTAL")
                try execute("VACUUM")
            }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA journal_size_limit = 4194304")
            try execute("PRAGMA wal_autocheckpoint = 256")
            try execute("PRAGMA synchronous = NORMAL")
            try execute("PRAGMA secure_delete = ON")
            try execute("CREATE TABLE IF NOT EXISTS metadata (revision INTEGER NOT NULL, generation INTEGER NOT NULL, total INTEGER NOT NULL)")
            try execute("INSERT INTO metadata SELECT 0, 0, 0 WHERE NOT EXISTS (SELECT 1 FROM metadata)")
            try execute("""
            CREATE TABLE IF NOT EXISTS entries (
                position INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
                revision INTEGER NOT NULL, state TEXT NOT NULL, payload BLOB NOT NULL
            )
            """)
            try execute("CREATE INDEX IF NOT EXISTS entries_revision ON entries(revision)")
            try execute("CREATE INDEX IF NOT EXISTS entries_state ON entries(state)")
            storedCount = try scalar("SELECT COUNT(*) FROM entries")
            storedBytes = try scalar("SELECT COALESCE(SUM(length(payload)), 0) FROM entries")
            try transaction { try pruneIfNeeded() }
            // 上次进程退出时未完成的请求不能永久显示为等待响应
            let interrupted = try read("SELECT position, payload, id FROM entries WHERE state = 'pending'", values: [], skipCorrupt: true)
            try transaction {
                for var entry in interrupted {
                    entry.status = .failure
                    entry.detail = String(localized: "log.persistence.interrupted")
                    try save(entry, inserting: false)
                }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    private func save(_ entry: AppServerLogEntry, inserting: Bool) throws {
        let previousBytes = inserting ? 0 : try scalar("SELECT COALESCE(length(payload), 0) FROM entries WHERE id = '\(entry.id.uuidString)'")
        guard inserting || previousBytes > 0 else { return }
        try execute("UPDATE metadata SET revision = revision + 1\(inserting ? ", total = total + 1" : "")")
        let sql = inserting
            ? "INSERT INTO entries (id, state, payload, revision) VALUES (?, ?, ?, (SELECT revision FROM metadata))"
            : "UPDATE entries SET state = ?2, payload = ?3, revision = (SELECT revision FROM metadata) WHERE id = ?1"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(entry.id.uuidString, to: statement, at: 1)
        try bind(entry.status.rawValue, to: statement, at: 2)
        let data = try JSONEncoder().encode(entry.bounded(to: limits.bodyBytes))
        let bound = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), Self.transient) }
        guard bound == SQLITE_OK else { throw failure() }
        _ = try step(statement)
        storedBytes += data.count - previousBytes
        storedCount += inserting ? 1 : 0
        try pruneIfNeeded()
    }

    private func pruneIfNeeded() throws {
        guard storedCount > limits.entries || storedBytes > limits.bytes else { return }
        let count = max(1, limits.entries * 9 / 10)
        let bytes = max(1, limits.bytes * 9 / 10)
        try execute("""
        DELETE FROM entries WHERE position IN (
            SELECT position FROM (
                SELECT position, ROW_NUMBER() OVER (ORDER BY position DESC) AS n,
                    SUM(length(payload)) OVER (ORDER BY position DESC) AS bytes FROM entries
            ) WHERE n > \(count) OR bytes > \(bytes)
        )
        """)
        storedCount = try scalar("SELECT COUNT(*) FROM entries")
        storedBytes = try scalar("SELECT COALESCE(SUM(length(payload)), 0) FROM entries")
        try execute("UPDATE metadata SET total = \(storedCount), revision = revision + 1, generation = generation + 1")
        needsCheckpoint = true
    }

    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private struct Statistics {
        let revision: Int64
        let generation: Int64
        let total: Int
    }

    private func stats() throws -> Statistics {
        let statement = try prepare("SELECT revision, generation, total FROM metadata")
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw failure() }
        return Statistics(revision: sqlite3_column_int64(statement, 0), generation: sqlite3_column_int64(statement, 1), total: Int(sqlite3_column_int64(statement, 2)))
    }

    private func read(_ sql: String, values: [Int64], skipCorrupt: Bool = false) throws -> [AppServerLogEntry] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_int64(statement, Int32(index + 1), value) == SQLITE_OK else { throw failure() }
        }
        var entries: [AppServerLogEntry] = []
        while try step(statement) == SQLITE_ROW {
            if let entry = decode(statement, skipCorrupt: skipCorrupt) {
                entries.append(entry)
            }
        }
        return entries
    }

    private func decode(_ statement: OpaquePointer, skipCorrupt: Bool = false) -> AppServerLogEntry? {
        let position = sqlite3_column_int64(statement, 0)
        let data = sqlite3_column_blob(statement, 1).map {
            Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, 1)))
        } ?? Data()
        let storedID = sqlite3_column_text(statement, 2).flatMap { UUID(uuidString: String(cString: $0)) }
        if var entry = try? JSONDecoder().decode(AppServerLogEntry.self, from: data), entry.id == storedID {
            entry.position = position
            return entry
        }
        guard !skipCorrupt else { return nil }
        // 占位记录沿用数据库身份和位置, 原始字节不被恢复流程覆盖
        var identity = (UInt64(0), UInt64(bitPattern: position).bigEndian)
        let id = storedID ?? withUnsafeBytes(of: &identity) { UUID(uuid: $0.load(as: uuid_t.self)) }
        return AppServerLogEntry(
            position: position, id: id, requestedAt: .distantPast, source: .local, status: .failure,
            method: "log/corrupt", request: nil,
            detail: String(localized: "log.persistence.error.read") + "\n" + (String(data: data, encoding: .utf8) ?? data.base64EncodedString())
        )
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            storedCount = (try? scalar("SELECT COUNT(*) FROM entries")) ?? storedCount
            storedBytes = (try? scalar("SELECT COALESCE(SUM(length(payload)), 0) FROM entries")) ?? storedBytes
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func bind(_ text: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, text, -1, Self.transient) == SQLITE_OK else { throw failure() }
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw failure() }
        return status
    }

    private func failure() -> StorageError {
        StorageError(message: String(localized: "log.persistence.error.read"))
    }

    private struct StorageError: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }
}
