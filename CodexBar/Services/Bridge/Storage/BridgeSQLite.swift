import Foundation
import SQLite3

/// 主库由 BridgeRuntime 串行使用, 客户端握手使用独立只读连接
final nonisolated class BridgeSQLite {
    enum Value {
        case text(String)
        case integer(Int64)
        case blob(Data)
        case null

        static func optional(_ value: String?) -> Self {
            value.map(text) ?? .null
        }
    }

    struct Failure: Error {
        let code: Int32
        var isBusy: Bool {
            code == SQLITE_BUSY || code == SQLITE_LOCKED
        }
    }

    private let db: OpaquePointer
    private static let busyTimeoutMilliseconds: Int32 = 2000
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let code = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw Failure(code: code)
        }
        db = handle
        if readOnly {
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds)
        try run("PRAGMA foreign_keys = ON")
        try run("PRAGMA journal_mode = WAL")
        try run("PRAGMA synchronous = FULL")
    }

    deinit {
        sqlite3_close(db)
    }

    func withoutWaitingForLock<T>(_ body: () throws -> T) rethrows -> T {
        sqlite3_busy_timeout(db, 0)
        defer { sqlite3_busy_timeout(db, Self.busyTimeoutMilliseconds) }
        return try body()
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        try rows(sql, values) { _ in }
    }

    func updateOne(_ sql: String, _ values: [Value]) throws {
        try run(sql, values)
        guard sqlite3_changes(db) == 1 else { throw BridgeFailure("outcome_unknown") }
    }

    func number(_ sql: String, _ values: [Value] = []) throws -> Int64 {
        var result: Int64 = 0
        try rows(sql, values) { result = sqlite3_column_int64($0, 0) }
        return result
    }

    func rows(_ sql: String, _ values: [Value] = [], read: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw Failure(code: prepared) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32 = switch value {
            case let .text(text): sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), Self.transient)
            case let .integer(number): sqlite3_bind_int64(statement, index, number)
            case let .blob(data): data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
            guard code == SQLITE_OK else { throw Failure(code: code) }
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                return
            }
            guard step == SQLITE_ROW else { throw Failure(code: step) }
            try read(statement)
        }
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(row, column) else { return "" }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, column))), encoding: .utf8) ?? ""
    }

    static func optionalText(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_type(row, column) == SQLITE_NULL ? nil : text(row, column)
    }

    static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }
}
