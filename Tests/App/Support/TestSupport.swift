import Darwin
import Foundation
import Testing

extension Tag {
    @Tag static var integration: Self
}

nonisolated enum TestFixtures {
    static let now = Date(timeIntervalSince1970: 1789459200)

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func event(
        _ name: ActivityDataEventKind = .turnStarted,
        at timestamp: Date = now,
        thread: String? = "thread-a",
        turn: String? = "turn-a",
        agentThreadID: String? = nil,
        origin: ActivityDataOrigin = .main
    ) -> ActivityDataRecord {
        var event = ActivityDataRecord(
            timestamp: timestamp, name: name.rawValue, origin: origin,
            cwd: "/projects/example", toolName: "exec_command", model: "gpt-5",
            effort: "high",
            threadID: thread, turnID: turn, agentThreadID: agentThreadID
        )
        if name == .turnStarted, let thread {
            event.context = ActivityDataContext(
                method: "turn/started", threadID: agentThreadID ?? thread, turnID: turn, turnStartedAt: timestamp
            )
        }
        return event
    }

    static func tokenUsageAggregate(at date: Date = now, tokenUsage: TokenUsage = .zero, eventCount: Int = 1) -> TokenUsageAggregate {
        TokenUsageAggregate(date: HistoryStorage.dateKey(for: date), tokenUsage: tokenUsage, eventCount: eventCount)
    }

    static func tokenUsageObservation(id: String = UUID().uuidString, at date: Date = now, tokenUsage: TokenUsage, previous: TokenUsage = .zero) -> TokenUsageObservation {
        TokenUsageObservation(id: id, observedAt: date, previous: previous, current: TokenUsageUpdate(total: previous.adding(tokenUsage)!, last: tokenUsage))
    }

    static func activityDataAggregate(date: String, events: Int = 1) -> ActivityDataAggregate {
        var aggregate = ActivityDataAggregate(date: date)
        aggregate.eventCount = events
        return aggregate
    }

    static func aggregate(
        events: Int = 2,
        turns: Int = 1
    ) -> ActivityDataAggregate {
        var aggregate = ActivityDataAggregate(date: "2026-09-15")
        aggregate.eventCount = events
        aggregate.turnCount = turns
        aggregate.threadCount = 1
        aggregate.threadIDs = nil
        aggregate.turnIDs = nil
        return aggregate
    }

    static func tokenUsage(_ total: Int64) -> TokenUsage {
        TokenUsage(inputTokens: total, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: total)
    }

    static func tokenSample(_ total: Int64, thread: String = "main", turn: String = "root", at: Date = now, start: Date? = nil) -> TokenUsageSample {
        TokenUsageSample(observedAt: at, threadID: thread, turnID: turn, turnStartedAt: start, current: TokenUsageUpdate(total: tokenUsage(total), last: tokenUsage(1)))
    }
}

nonisolated struct TestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, to relativePath: String) throws -> URL {
        let destination = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        return destination
    }

    func write(_ text: String, to relativePath: String) throws -> URL {
        try write(Data(text.utf8), to: relativePath)
    }

    func seedTokenUsageAggregates(_ aggregates: [TokenUsageAggregate]) throws {
        let database = try HistoryDatabase(directoryURL: url)
        for var aggregate in aggregates {
            aggregate.position = 0
            try database.entries(date: aggregate.date, kind: .tokenUsage) { aggregate.position = $0.position }
            try database.execute("INSERT OR IGNORE INTO days(date) VALUES (?)", [.text(aggregate.date)])
            try database.execute("""
            INSERT INTO aggregates(date, tokenUsage) VALUES (?, ?)
            ON CONFLICT(date) DO UPDATE SET tokenUsage = excluded.tokenUsage
            """, [.text(aggregate.date), .data(JSONLines.stableEncoder.encode(aggregate))])
        }
    }

    func historyRecords() throws -> [AppServerEventRecord] {
        var records: [AppServerEventRecord] = []
        try HistoryDatabase(directoryURL: url).entries { records.append($0.record) }
        return records
    }

    func replaceHistory(_ data: Data, date: String) throws {
        let database = try HistoryDatabase(directoryURL: url)
        try database.execute("DELETE FROM events WHERE date = ?", [.text(date)])
        for line in data.split(separator: JSONLines.newlineByte) {
            try database.append(AppServerEventRecord.decode(from: Data(line)))
        }
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
    }

    func removeAfterClosingHistory() async throws {
        await HistoryDatabaseStore.shared(in: url).releaseConnection()
        try #require(openFilePaths().isEmpty)
        try remove()
    }

    func openFilePaths() throws -> [String] {
        let byteCount = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount > 0 else { throw POSIXError(.EIO) }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(byteCount) / MemoryLayout<proc_fdinfo>.stride)
        let written = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { throw POSIXError(.EIO) }
        let prefix = url.resolvingSymlinksInPath().path + "/"
        return descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor.proc_fd, F_GETPATH, &path) == 0 else { return nil }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let value = String(bytes: bytes, encoding: .utf8) else { return nil }
            let normalized = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
            return normalized.hasPrefix(prefix) ? value : nil
        }
    }

    func executable(_ body: String, named name: String = "test command") throws -> URL {
        let command = try write("#!/bin/sh\n\(body)\n", to: name)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        return command
    }

    func waitForFile(_ name: String) async throws {
        let path = url.appendingPathComponent(name).path
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(FileManager.default.fileExists(atPath: path), "Test process did not create \(name)")
    }
}

struct TestPreferences {
    let suite = "app.zabrian.codexbar.tests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
    }
}

nonisolated extension HistoryDatabase {
    func exportJSONLines(date: String) throws -> Data {
        var result = Data()
        try entries(date: date) { try result.append($0.record.jsonLineData()) }
        return result
    }
}

nonisolated extension ActivityDataAggregate {
    func jsonLineData() throws -> Data {
        try JSONLines.stableEncoder.encode(self) + Data([JSONLines.newlineByte])
    }
}

nonisolated extension SyncedActivityData {
    func jsonLineData() throws -> Data {
        try JSONLines.stableEncoder.encode(self) + Data([JSONLines.newlineByte])
    }
}

/// 测试夹具按采集器的原始记录与缓存聚合两个步骤写入
extension TokenUsageHistoryStore {
    func recordObservations(_ observations: [TokenUsageObservation], now: Date = Date()) async throws -> [TokenUsageAggregate] {
        _ = try await refresh(now: now)
        for observation in observations {
            try await appendObservation(observation, now: now)
        }
        return try await refresh(now: now)
    }
}
