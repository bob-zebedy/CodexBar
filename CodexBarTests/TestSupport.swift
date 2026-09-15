import Foundation
import Testing

nonisolated enum TestFixtures {
    static let now = Date(timeIntervalSince1970: 1789459200)

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func event(
        _ name: CodexHookEvent = .userPromptSubmit,
        at timestamp: Date = now,
        session: String? = "session-a",
        turn: String? = "turn-a",
        agent: String? = nil,
        origin: WorkflowEventOrigin = .main,
        reviewer: CodexApprovalReviewer? = .user
    ) -> WorkflowHookEvent {
        WorkflowHookEvent(
            timestamp: timestamp, name: name.rawValue, origin: origin,
            directoryPath: "/projects/example", toolName: "exec_command", modelName: "gpt-5",
            effort: "high", permissionMode: nil, approvalReviewer: reviewer,
            sessionId: session, turnId: turn, agentId: agent
        )
    }

    static func aggregate(
        generation: String? = "generation-a",
        fresh: Bool = false,
        events: Int = 2,
        turns: Int = 1
    ) -> WorkflowDailyAggregate {
        var aggregate = WorkflowDailyAggregate(date: "2026-09-15", sourceGeneration: generation, sourceIsFresh: fresh)
        aggregate.eventCount = events
        aggregate.turnCount = turns
        aggregate.sessionCount = 1
        aggregate.sessionIds = nil
        aggregate.turnIds = nil
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

    func remove() throws {
        try FileManager.default.removeItem(at: url)
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
