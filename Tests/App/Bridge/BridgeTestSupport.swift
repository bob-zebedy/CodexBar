import Foundation
import Testing

final nonisolated class BridgeFixture: BridgeUpstream, @unchecked Sendable {
    let losesTurnResponse: Bool
    private let beforeCall: @Sendable (String, BridgeJSON) throws -> Void

    init(losesTurnResponse: Bool = false, beforeCall: @escaping @Sendable (String, BridgeJSON) throws -> Void = { _, _ in }) {
        self.beforeCall = beforeCall
        self.losesTurnResponse = losesTurnResponse
    }

    private let lock = NSLock()
    private var count = 0
    private var turns: [String: [String]] = [:]
    private var turnPagesRead = 0
    var turnPageReads: Int {
        lock.withLock { turnPagesRead }
    }

    private var history: [String: [BridgeJSON]] = [:]
    private var failures: [String: String] = [:]
    private var unsubscribed: [String] = []
    var subscriptionsRemoved: [String] {
        lock.withLock { unsubscribed }
    }

    func setHistory(_ turn: String, items: [BridgeJSON], failure: String? = nil) {
        lock.withLock { history[turn] = items
            failures[turn] = failure
        }
    }

    private var captured: BridgeJSON?
    var starts: Int {
        lock.withLock { count }
    }

    var answer: BridgeJSON? {
        lock.withLock { captured }
    }

    func call(_ method: String, _ params: BridgeJSON) throws -> BridgeJSON {
        try beforeCall(method, params)
        switch method {
        case "thread/start", "thread/resume":
            let id = lock.withLock {
                if method == "thread/resume" {
                    return params["threadId"]
                }
                count += 1
                return BridgeJSON.string("thread-\(count)")
            }
            let profile = params["config"]["permissions.codexbar-bridge"]
            let sandbox: BridgeJSON = profile["filesystem"][":project_roots"] == "write" ? "workspaceWrite" : "readOnly"
            return [
                "thread": ["id": id],
                "activePermissionProfile": ["id": "codexbar-bridge"],
                "approvalPolicy": params["approvalPolicy"],
                "approvalsReviewer": "user",
                "cwd": params["cwd"],
                "sandbox": [
                    "type": sandbox, "writableRoots": [], "excludeTmpdirEnvVar": .bool(true), "excludeSlashTmp": .bool(true), "networkAccess": profile["network"]["enabled"]
                ]
            ]
        case "turn/start":
            if losesTurnResponse {
                throw AppServerError.serverConnectionClosed
            }
            let thread = try params.required("threadId")
            return lock.withLock {
                let id = "turn-\(thread)-\(turns[thread, default: []].count)"
                turns[thread, default: []].append(id)
                captured = ["method": .string(method), "params": params]
                return ["turn": ["id": .string(id), "status": "inProgress"]]
            }
        case "thread/turns/list":
            let thread = try params.required("threadId")
            let entries: [BridgeJSON] = lock.withLock {
                turnPagesRead += 1
                return turns[thread, default: []].map { id in
                    if let failure = failures[id] {
                        return ["id": .string(id), "status": "failed", "error": ["message": .string(failure)]]
                    }
                    return ["id": .string(id), "status": "completed"]
                }
            }
            let index = params["cursor"].text.flatMap(Int.init) ?? 0
            let page = entries.reversed().dropFirst(index).prefix(1)
            return ["data": .array(Array(page)), "nextCursor": index + 1 < entries.count ? .string(String(index + 1)) : .null]
        case "thread/items/list":
            let turn = try params.required("turnId")
            let items = lock.withLock { history[turn] ?? [] }
            let offset = params["cursor"].text.flatMap(Int.init) ?? 0
            let page: [BridgeJSON] = items.reversed().dropFirst(offset).prefix(2).map { ["turnId": .string(turn), "item": $0] }
            let next = offset + page.count
            return ["data": .array(page), "nextCursor": next < items.count ? .string(String(next)) : .null]
        case "thread/unsubscribe":
            let task = try params.required("threadId")
            lock.withLock { unsubscribed.append(task) }
            return [:]
        case "turn/steer":
            lock.withLock { captured = ["method": .string(method), "params": params] }
            return ["turnId": params["expectedTurnId"]]
        case "turn/interrupt": return [:]
        default: throw BridgeFailure("unexpected_method", method)
        }
    }

    func next() throws -> BridgeJSON? {
        nil
    }

    func answer(_: BridgeRPCRequest.Method, id: BridgeJSON, result: BridgeJSON) throws {
        lock.withLock { captured = ["id": id, "result": result] }
    }

    func reject(_: String, id _: BridgeJSON) throws {
        throw BridgeFailure("unexpected_request")
    }

    func close() {}
}

extension TestPreferences {
    func makeBridgeRuntime(in directory: URL, connect: @escaping BridgeRuntime.Connector) throws -> BridgeRuntime {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileReadUnknown) }
        return BridgeRuntime(directory: directory, defaults: defaults, connect: connect)
    }
}

extension BridgeRuntime {
    func createConfigurationToken(name: String, writable: Bool = false) throws -> String {
        let configuration = try createConfiguration(name: name, permissions: .init(writable: writable))
        let config = try JSONDecoder().decode(BridgeJSON.self, from: Data(exportMCPConfiguration(for: configuration.id, format: .genericJSON).utf8))
        return try #require(config["mcpServers"]["codex"]["env"]["CODEXBAR_BRIDGE_TOKEN"].text)
    }

    func execute(_ tool: BridgeTool, args: BridgeJSON, configurationID: UUID) async throws -> BridgeJSON {
        try await execute(tool.parse(args), configurationID: configurationID) { _ in throw BridgeFailure("unexpected_form") }
    }

    func respond(_ args: BridgeJSON, configurationID: UUID, response: BridgeJSON) async throws -> BridgeJSON {
        try await execute(BridgeTool.respond.parse(args), configurationID: configurationID) { _ in response }
    }
}
