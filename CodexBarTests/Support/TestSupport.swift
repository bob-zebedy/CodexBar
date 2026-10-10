import Foundation
import Testing

nonisolated enum TestFixtures {
    static let now = Date(timeIntervalSince1970: 1789459200)

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func event(
        _ name: ActivityEventKind = .turnStarted,
        at timestamp: Date = now,
        thread: String? = "thread-a",
        turn: String? = "turn-a",
        agent: String? = nil,
        origin: ActivityOrigin = .main
    ) -> ActivityRecord {
        var event = ActivityRecord(
            timestamp: timestamp, name: name.rawValue, origin: origin,
            cwd: "/projects/example", toolName: "exec_command", model: "gpt-5",
            effort: "high",
            threadID: thread, turnID: turn, agentID: agent
        )
        if name == .turnStarted, let thread {
            event.context = ActivityContext(
                method: "turn/started", threadID: agent ?? thread, turnID: turn, turnStartedAt: timestamp
            )
        }
        return event
    }

    static func tokenTurn(
        id: String, rootID: String, startedAt: Date? = nil, updatedAt: Date, usage: TokenUsage? = nil
    ) -> TokenTurn {
        TokenTurn(
            id: id, rootID: rootID, startedAt: startedAt, updatedAt: updatedAt, usage: usage,
            checkpoint: usage.map { ["test-stream": TokenObservationCheckpoint(sequence: 1, usage: $0)] } ?? [:]
        )
    }

    static func aggregate(
        generation: String? = "generation-a",
        events: Int = 2,
        turns: Int = 1
    ) -> ActivityAggregate {
        var aggregate = ActivityAggregate(date: "2026-09-15", generationID: generation)
        aggregate.sourceCheckpoint = ActivitySourceCheckpoint(byteCount: UInt64(events + 1), digest: String(repeating: "a", count: 64))
        aggregate.eventCount = events
        aggregate.turnCount = turns
        aggregate.threadCount = 1
        aggregate.threadIDs = nil
        aggregate.turnIDs = nil
        return aggregate
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

    func seedTokenSnapshots(_ turns: [TokenTurn], now: Date) async throws {
        try HistoryStorage.withExclusiveLock(in: url) {
            var journal = AppServerEventJournal()
            for turn in turns {
                try journal.append(AppServerEventRecord(token: turn, recordedAt: now), in: url)
            }
        }
        _ = try await TokenHistoryStore(directoryURL: url).refresh(now: now)
    }

    func remove() throws {
        try FileManager.default.removeItem(at: url)
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

nonisolated extension TestDirectory {
    @discardableResult
    func writeJournal(_ records: Data, to relativePath: String, generation: String? = nil) throws -> URL {
        let url = url.appendingPathComponent(relativePath)
        let date = url.deletingPathExtension().lastPathComponent
        let source = generation ?? (try? AppServerEventJournal.header(at: url).generationID) ?? UUID().uuidString.lowercased()
        let header = AppServerEventJournal.Header(version: 1, date: date, generationID: source)
        return try write(JSONLines.stableEncoder.encode(header) + Data([10]) + records, to: relativePath)
    }

    func activityAggregate(date: String, generation: String = "source", events: Int = 1) throws -> ActivityAggregate {
        let path = "Events/\(date).jsonl"
        let url = url.appendingPathComponent(path)
        if !FileManager.default.fileExists(atPath: url.path) {
            try writeJournal(Data(), to: path, generation: generation)
        }
        var aggregate = ActivityAggregate(date: date, generationID: generation)
        aggregate.eventCount = events
        aggregate.sourceCheckpoint = try ActivitySourceCheckpoint.read(at: url, byteCount: HistoryStorage.fileSize(at: url))
        return aggregate
    }
}

/// 测试夹具按采集器的原始记录与缓存聚合两个步骤写入
extension TokenHistoryStore {
    func recordObservations(_ observations: [TokenObservation], now: Date = Date()) throws -> [TokenTurn] {
        _ = try refresh(now: now)
        for observation in observations {
            try appendObservation(observation, now: now)
        }
        return try refresh(now: now)
    }
}
