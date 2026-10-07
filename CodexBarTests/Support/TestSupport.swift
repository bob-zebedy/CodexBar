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
        session: String? = "session-a",
        turn: String? = "turn-a",
        agent: String? = nil,
        origin: ActivityOrigin = .main,
        reviewer: ApprovalReviewer? = .user
    ) -> ActivityRecord {
        ActivityRecord(
            timestamp: timestamp, name: name.rawValue, origin: origin,
            cwd: "/projects/example", tool: "exec_command", model: "gpt-5",
            effort: "high", approvalReviewer: reviewer,
            sessionID: session, turnID: turn, agentID: agent
        )
    }

    static func aggregate(
        generation: String? = "generation-a",
        fresh: Bool = false,
        events: Int = 2,
        turns: Int = 1
    ) -> ActivityAggregate {
        var aggregate = ActivityAggregate(date: "2026-09-15", generationID: generation, generationStartedEmpty: fresh)
        aggregate.eventCount = events
        aggregate.turnCount = turns
        aggregate.sessionCount = 1
        aggregate.sessionIDs = nil
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
