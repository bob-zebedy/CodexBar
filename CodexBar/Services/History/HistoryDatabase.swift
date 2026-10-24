import Foundation
import SQLite3

/// SQLite 操作同步完成, 应用通过 HistoryDatabaseStore 串行访问共享连接
final nonisolated class HistoryDatabase {
    private static let schemaVersion: Int32 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let eventIndexPrefix = "codexbar_events_"

    /// 索引使用专用前缀, 定义改变时更换名称, 避免将同名旧索引误判为已更新
    private static let eventIndexDefinitions = [
        eventIndexPrefix + "date_kind_position": "(date, kind, position)",
        eventIndexPrefix + "token_usage_thread": """
        (CASE WHEN json_valid(CAST(payload AS TEXT)) THEN json_extract(CAST(payload AS TEXT), '$.tokenUsage.threadID') END, position)
        WHERE kind = 'tokenUsage'
        """
    ]

    // 仅记录专用前缀启用前已发布的索引, 后续不再扩充
    private static let legacyEventIndexNames: Set<String> = ["events_date", "events_token_usage_thread"]
    private var connection: OpaquePointer?
    private var threadSnapshots: [String: CachedThreadSnapshot] = [:]

    private struct CachedThreadSnapshot {
        let snapshot: TokenUsageThreadSnapshot
        let accessedAt: Date
    }

    enum Value {
        case integer(Int64)
        case text(String)
        case data(Data)
        case null
    }

    struct Failure: Error {
        let code: Int32
        let message: String

        var requiresReopening: Bool {
            switch code & 0xFF {
            case SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN, SQLITE_PROTOCOL, SQLITE_READONLY:
                true
            default:
                false
            }
        }
    }

    struct Entry {
        /// 数据库分配的写入序号, 用于增量读取, 不表示业务事件发生顺序
        let position: Int64
        let record: AppServerEventRecord
    }

    init(directoryURL: URL) throws {
        let url = AppStorage(rootURL: directoryURL).historyDatabaseURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let error = failure(result)
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        sqlite3_busy_timeout(connection, 2000)
        do {
            let schemaVersion = try scalar("PRAGMA user_version")
            guard schemaVersion == 0 || schemaVersion == Int64(Self.schemaVersion) else {
                throw StorageCompatibilityError.unsupportedFormat("HistoryDatabase", Int(schemaVersion))
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA synchronous = FULL")
            if schemaVersion == 0 {
                try transaction {
                    try execute("""
                    CREATE TABLE IF NOT EXISTS days (
                        date TEXT PRIMARY KEY
                    )
                    """)
                    try execute("""
                    CREATE TABLE IF NOT EXISTS events (
                        position INTEGER PRIMARY KEY AUTOINCREMENT,
                        identity TEXT UNIQUE,
                        date TEXT NOT NULL REFERENCES days(date) ON DELETE CASCADE,
                        kind TEXT NOT NULL,
                        payload BLOB NOT NULL
                    )
                    """)
                    try execute("""
                    CREATE TABLE IF NOT EXISTS aggregates (
                        date TEXT PRIMARY KEY REFERENCES days(date) ON DELETE CASCADE,
                        activityData BLOB,
                        tokenUsage BLOB
                    )
                    """)
                    try execute("PRAGMA user_version = \(Self.schemaVersion)")
                }
            }
            try ensureEventIndexes()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(connection)
    }

    private func ensureEventIndexes() throws {
        let changes = try eventIndexChanges()
        guard !changes.missing.isEmpty || !changes.obsolete.isEmpty else { return }

        try transaction {
            // 等待写锁期间其他连接可能已更新索引, 锁内重新读取后再执行差异
            let changes = try eventIndexChanges()
            for (name, definition) in changes.missing.sorted(by: { $0.key < $1.key }) {
                try execute("CREATE INDEX \(Self.quotedIdentifier(name)) ON events \(definition)")
            }
            for name in changes.obsolete.sorted() {
                try execute("DROP INDEX \(Self.quotedIdentifier(name))")
            }
        }
    }

    private func eventIndexChanges() throws -> (missing: [String: String], obsolete: Set<String>) {
        var existing = Set<String>()
        var managed = Set<String>()
        try query("SELECT name, \"unique\", origin FROM pragma_index_list('events')") {
            let name = Self.text($0, at: 0)
            existing.insert(name)
            guard sqlite3_column_int($0, 1) == 0, Self.text($0, at: 2) == "c",
                  name.hasPrefix(Self.eventIndexPrefix) || Self.legacyEventIndexNames.contains(name) else { return }
            managed.insert(name)
        }
        return (
            Self.eventIndexDefinitions.filter { !existing.contains($0.key) },
            managed.subtracting(Self.eventIndexDefinitions.keys)
        )
    }

    var hasOpenTransaction: Bool {
        sqlite3_get_autocommit(connection) == 0
    }

    func canReuseConnection() throws -> Bool {
        var moved: Int32 = 0
        let result = sqlite3_file_control(connection, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
        guard result == SQLITE_OK else { throw failure(result) }
        guard moved == 0, !hasOpenTransaction else { return false }
        return try scalar("PRAGMA user_version") == Int64(Self.schemaVersion)
    }

    func transaction<T>(isolation _: isolated (any Actor)? = #isolation, _ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try Task.checkCancellation()
            try execute("COMMIT")
            return value
        } catch {
            sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    @discardableResult
    func append(_ record: AppServerEventRecord) throws -> Bool {
        try transaction { try insert(record) }
    }

    @discardableResult
    private func insert(_ record: AppServerEventRecord) throws -> Bool {
        let date = HistoryStorage.dateKey(for: record.activityData?.timestamp ?? record.tokenUsage?.aggregationDate ?? record.recordedAt)
        let data = try JSONLines.stableEncoder.encode(record)
        guard data.count <= 1024 * 1024 else { throw StorageCompatibilityError.incompleteSource }
        try execute("INSERT OR IGNORE INTO days(date) VALUES (?)", [.text(date)])
        try execute(
            "INSERT OR IGNORE INTO events(identity, date, kind, payload) VALUES (?, ?, ?, ?)",
            [record.deduplicationID.map(Value.text) ?? .null, .text(date), .text(record.kind.rawValue), .data(data)]
        )
        return sqlite3_changes(connection) > 0
    }

    func appendTokenUsage(_ sample: TokenUsageSample) throws {
        try transaction {
            var exists = false
            try query("SELECT 1 FROM events WHERE identity = ?", [.text("tokenUsage:" + sample.id)]) { _ in exists = true }
            guard !exists else { return }
            var latest: TokenUsageObservation?
            try query("""
            SELECT payload FROM events
            WHERE kind = 'tokenUsage' AND CASE WHEN json_valid(CAST(payload AS TEXT)) THEN json_extract(CAST(payload AS TEXT), '$.tokenUsage.threadID') END = ?
            ORDER BY position DESC LIMIT 1
            """, [.text(sample.threadID)]) {
                latest = try AppServerEventRecord.decode(from: Self.data($0, at: 0)).tokenUsage
            }
            guard latest?.current.total != sample.current.total || latest?.turnID != sample.turnID else { return }
            // 不可比较的累计值只建立新基线, 不将上下文估算或回退当成消耗
            var previous = latest?.current.total ?? sample.current.total
            if sample.current.total.subtractingCounters(previous) == nil {
                previous = sample.current.total
            }
            guard sample.current.total.subtractingCounters(previous) != nil else { return }
            let observation = TokenUsageObservation(
                id: sample.id, observedAt: sample.observedAt, threadID: sample.threadID, turnID: sample.turnID,
                turnStartedAt: sample.turnStartedAt, previous: previous, current: sample.current
            )
            try insert(AppServerEventRecord(tokenUsage: observation, recordedAt: sample.observedAt))
        }
    }

    func tokenUsageSnapshot(threadID: String) throws -> TokenUsageThreadSnapshot {
        let result = try tokenUsageSnapshot(threadSnapshots[threadID]?.snapshot ?? TokenUsageThreadSnapshot(threadID: threadID))
        threadSnapshots[threadID] = CachedThreadSnapshot(snapshot: result, accessedAt: Date())
        if threadSnapshots.count > 128, let oldest = threadSnapshots.min(by: { $0.value.accessedAt < $1.value.accessedAt })?.key {
            threadSnapshots[oldest] = nil
        }
        return result
    }

    func tokenUsageSnapshot(_ previous: TokenUsageThreadSnapshot) throws -> TokenUsageThreadSnapshot {
        var snapshot = previous
        try query("""
        SELECT position, payload FROM events
        WHERE kind = 'tokenUsage' AND CASE WHEN json_valid(CAST(payload AS TEXT)) THEN json_extract(CAST(payload AS TEXT), '$.tokenUsage.threadID') END = ? AND position > ?
        ORDER BY position
        """, [.text(previous.threadID), .integer(previous.position)]) { row in
            guard let observation = try AppServerEventRecord.decode(from: Self.data(row, at: 1)).tokenUsage,
                  let turn = observation.turnID, let delta = observation.delta,
                  let total = (snapshot.turns[turn] ?? .zero).adding(delta), total.isValid else {
                throw StorageCompatibilityError.incompleteSource
            }
            // 首次非零累计值只建立比较基线, 不代表本轮已确认消耗为零
            let isInitialBaseline = snapshot.position == 0 && delta == .zero && observation.current.total != .zero
            if !isInitialBaseline {
                snapshot.turns[turn] = total
            }
            snapshot.position = sqlite3_column_int64(row, 0)
        }
        return snapshot
    }

    func appendActivityData(_ events: [ActivityDataRecord]) throws {
        try transaction {
            for event in events where event.id != nil {
                try insert(AppServerEventRecord(activityData: event))
            }
        }
    }

    func dates() throws -> [String] {
        var result: [String] = []
        try query("SELECT date FROM days ORDER BY date") { result.append(Self.text($0, at: 0)) }
        return result
    }

    func entries(after position: Int64 = 0, date: String? = nil, kind: AppServerEventRecord.Kind? = nil, consume: (Entry) throws -> Void) throws {
        let sql = "SELECT position, payload, kind FROM events WHERE position > ?" + (date == nil ? "" : " AND date = ?")
            + (kind == nil ? "" : " AND kind = ?") + " ORDER BY position"
        var values: [Value] = [.integer(position)]
        if let date {
            values.append(.text(date))
        }
        if let kind {
            values.append(.text(kind.rawValue))
        }
        try query(sql, values) { row in
            let record = try AppServerEventRecord.decode(from: Self.data(row, at: 1))
            guard record.kind.rawValue == Self.text(row, at: 2) else { throw StorageCompatibilityError.incompleteSource }
            try consume(Entry(position: sqlite3_column_int64(row, 0), record: record))
        }
    }

    func activityDataAggregates() throws -> [ActivityDataAggregate] {
        var values: [ActivityDataAggregate] = []
        try query("SELECT activityData FROM aggregates WHERE activityData IS NOT NULL ORDER BY date") {
            if let value = try? JSONLines.decoder.decode(ActivityDataAggregate.self, from: Self.data($0, at: 0)) {
                values.append(value)
            }
        }
        return values
    }

    func pendingActivityDataDates() throws -> [String] {
        var dates: [String] = []
        try query("""
        SELECT days.date, aggregates.activityData,
            (SELECT COALESCE(MAX(position), 0) FROM events WHERE events.date = days.date AND events.kind = 'activityData')
        FROM days
        LEFT JOIN aggregates ON aggregates.date = days.date
        ORDER BY days.date
        """) { row in
            let aggregate = try? JSONLines.decoder.decode(ActivityDataAggregate.self, from: Self.data(row, at: 1))
            if let aggregate, aggregate.aggregationVersion == AggregationVersion.activityData,
               aggregate.position >= sqlite3_column_int64(row, 2) {
                return
            }
            dates.append(Self.text(row, at: 0))
        }
        return dates
    }

    /// 聚合和源位置在同一事务提交, 失败不会留下已推进的检查点
    func aggregateActivityData(date: String, rebuilding: Bool = false, now: Date = Date()) throws -> ActivityDataAggregate {
        try transaction {
            var hasSource = false
            try query("SELECT 1 FROM days WHERE date = ?", [.text(date)]) { _ in hasSource = true }
            guard hasSource else { throw HistoryDataRebuildError.sourceUnavailable }
            var base: ActivityDataAggregate?
            var position: Int64 = 0
            if !rebuilding {
                try query("SELECT activityData FROM aggregates WHERE date = ?", [.text(date)]) { row in
                    guard let aggregate = try? JSONLines.decoder.decode(ActivityDataAggregate.self, from: Self.data(row, at: 0)),
                          aggregate.aggregationVersion == AggregationVersion.activityData else { return }
                    base = aggregate
                    position = aggregate.position
                }
            }
            var accumulator = base.map { ActivityDataAccumulator(appending: $0) }
                ?? ActivityDataAccumulator(rebuilding: date)
            if let base, !base.supportsIncrementalAggregation {
                try entries(date: date, kind: .activityData) { entry in
                    if entry.position <= position, let event = entry.record.activityData {
                        accumulator.restoreIdentity(from: event)
                    }
                }
            }
            try entries(after: position, date: date, kind: .activityData) { entry in
                if let event = entry.record.activityData {
                    accumulator.record(event)
                }
                position = entry.position
            }
            let cutoff = HistoryStorage.dateKey(for: HistoryStorage.identifierRetentionCutoffDate(today: now))
            var aggregate = accumulator.finalized(identifierStorage: date >= cutoff ? .retained : .compacted)
            aggregate.position = position
            try execute("""
            INSERT INTO aggregates(date, activityData) VALUES (?, ?)
            ON CONFLICT(date) DO UPDATE SET activityData = excluded.activityData
            """, [.text(date), .data(JSONLines.stableEncoder.encode(aggregate))])
            return aggregate
        }
    }

    func tokenUsageDates(in dateKeys: [String]) throws -> [String] {
        let requested = Set(dateKeys).sorted()
        guard !requested.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: requested.count).joined(separator: ", ")
        var result: [String] = []
        try query("""
        SELECT date FROM days
        WHERE date IN (\(placeholders))
            AND EXISTS (SELECT 1 FROM events WHERE events.date = days.date AND events.kind = 'tokenUsage')
        ORDER BY date
        """, requested.map(Value.text)) { result.append(Self.text($0, at: 0)) }
        return result
    }

    func tokenUsageAggregates() throws -> [TokenUsageAggregate] {
        var result: [TokenUsageAggregate] = []
        try query("SELECT tokenUsage FROM aggregates WHERE tokenUsage IS NOT NULL ORDER BY date") {
            if let value = try? JSONLines.decoder.decode(TokenUsageAggregate.self, from: Self.data($0, at: 0)) {
                result.append(value)
            }
        }
        return result
    }

    func pendingTokenUsageDates() throws -> [String] {
        var dates: [String] = []
        try query("""
        SELECT days.date, aggregates.tokenUsage,
            (SELECT COALESCE(MAX(position), 0) FROM events WHERE events.date = days.date AND events.kind = 'tokenUsage')
        FROM days
        LEFT JOIN aggregates ON aggregates.date = days.date
        WHERE aggregates.tokenUsage IS NOT NULL
            OR EXISTS (SELECT 1 FROM events WHERE events.date = days.date AND events.kind = 'tokenUsage')
        ORDER BY days.date
        """) { row in
            let aggregate = try? JSONLines.decoder.decode(TokenUsageAggregate.self, from: Self.data(row, at: 1))
            if let aggregate, aggregate.aggregationVersion == AggregationVersion.tokenUsage,
               aggregate.position >= sqlite3_column_int64(row, 2) {
                return
            }
            dates.append(Self.text(row, at: 0))
        }
        return dates
    }

    /// 日期结果和读取位置共同提交, 重放失败时保留之前的日总量
    func aggregateTokenUsage(date: String, rebuilding: Bool = false) throws -> TokenUsageAggregate {
        try transaction {
            var baseline: TokenUsageAggregate?
            var position: Int64 = 0
            try query("SELECT tokenUsage FROM aggregates WHERE date = ?", [.text(date)]) {
                guard let aggregate = try? JSONLines.decoder.decode(TokenUsageAggregate.self, from: Self.data($0, at: 0)),
                      aggregate.aggregationVersion == AggregationVersion.tokenUsage else { return }
                baseline = aggregate
                if !rebuilding {
                    position = aggregate.position
                }
            }
            var aggregate = rebuilding ? TokenUsageAggregate(date: date) : baseline ?? TokenUsageAggregate(date: date)
            // 沿用数据库中保存的日期, 避免切换时区后误判历史记录
            try entries(after: position, date: date, kind: .tokenUsage) { entry in
                guard let observation = entry.record.tokenUsage, !observation.id.isEmpty else {
                    throw StorageCompatibilityError.incompleteSource
                }
                try aggregate.record(observation)
                position = entry.position
            }
            guard aggregate.eventCount > 0,
                  !rebuilding || aggregate.eventCount >= (baseline?.eventCount ?? 0) else {
                throw StorageCompatibilityError.incompleteSource
            }
            aggregate.position = position
            try execute("""
            INSERT INTO aggregates(date, tokenUsage) VALUES (?, ?)
            ON CONFLICT(date) DO UPDATE SET tokenUsage = excluded.tokenUsage
            """, [.text(date), .data(JSONLines.stableEncoder.encode(aggregate))])
            return aggregate
        }
    }

    func prune(now: Date) throws -> Int {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        return try transaction {
            try execute("DELETE FROM days WHERE date < ?", [.text(cutoff)])
            let removed = Int(sqlite3_changes(connection))
            for aggregate in try activityDataAggregates() {
                guard let normalized = ActivityDataAggregate.normalized(aggregates: [aggregate], today: now).first,
                      normalized != aggregate else { continue }
                try execute("UPDATE aggregates SET activityData = ? WHERE date = ?", [.data(JSONLines.stableEncoder.encode(normalized)), .text(aggregate.date)])
            }
            return removed
        }
    }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        try query(sql, values) { _ in }
    }

    private func scalar(_ sql: String) throws -> Int64 {
        var value: Int64 = 0
        try query(sql) { value = sqlite3_column_int64($0, 0) }
        return value
    }

    private func query(_ sql: String, _ values: [Value] = [], consume: (OpaquePointer) throws -> Void) throws {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure(prepared) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let parameter = Int32(index + 1)
            let bound: Int32 = switch value {
            case let .integer(value): sqlite3_bind_int64(statement, parameter, value)
            case let .text(value): sqlite3_bind_text(statement, parameter, value, -1, Self.transient)
            case let .data(value): value.withUnsafeBytes { sqlite3_bind_blob(statement, parameter, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, parameter)
            }
            guard bound == SQLITE_OK else { throw failure(bound) }
        }
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return
            }
            guard step == SQLITE_ROW else { throw failure(step) }
            try consume(statement)
        }
    }

    private func failure(_ code: Int32) -> Failure {
        Failure(code: code, message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open history database")
    }

    private static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func text(_ statement: OpaquePointer, at index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private static func data(_ statement: OpaquePointer, at index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
