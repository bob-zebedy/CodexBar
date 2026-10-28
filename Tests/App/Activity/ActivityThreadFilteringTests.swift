import Foundation
import Synchronization
import Testing

struct ActivityThreadFilteringTests {
    @Test(arguments: [false, true])
    func titleThreadsDoNotBlockRecoveryOrProduceActivity(discoveredByNotification: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let requests = Mutex([String: Int]())
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            var discovery = 0
            while let request = try? peer.readMessage() {
                let method = request["method"] as? String ?? ""
                let id = (request["params"] as? [String: Any])?["threadId"] as? String ?? ""
                requests.withLock { $0[method + ":" + id, default: 0] += 1 }
                switch method {
                case "thread/loaded/list":
                    discovery += 1
                    if discoveredByNotification, discovery == 1 {
                        try peer.send(["method": "thread/started", "params": ["thread": Self.thread("title", source: "thread_title")]])
                        try Self.sendTitleActivity(peer)
                    }
                    try peer.reply(to: request, result: ["data": ["title", "normal"]])
                case "thread/read":
                    if id == "title" {
                        // 在元数据返回前到达的通知也必须随过滤结果丢弃
                        try Self.sendTitleActivity(peer)
                    }
                    try peer.reply(to: request, result: ["thread": Self.thread(id, source: id == "title" ? "thread_title" : "future_source")])
                case "thread/resume":
                    if id == "title" {
                        try peer.send(["id": #require(request["id"]), "error": ["code": -32600, "message": "no rollout found for thread id title"]])
                    } else {
                        try peer.reply(to: request, result: ["thread": Self.thread(id, source: "future_source")])
                    }
                case "thread/turns/list":
                    try peer.reply(to: request, result: ["data": []])
                default:
                    Issue.record("Unexpected method: \(method)")
                }
            }
        }
        defer { server.close() }
        var ready = false
        var complete = false
        var disconnected = false
        let probe = ActivityReaderProbe()
        let reader = AppServerActivityReader(
            probe: probe, socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { update in
            if update.phase == .bootstrapEnd {
                ready = true
                complete = update.isComplete
            }
            if update.phase == .sourceUnavailable {
                disconnected = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready && !disconnected {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        #expect(complete)
        for _ in 0 ..< 3 where ready {
            #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        }
        await reader.stop()
        try server.finish()
        #expect(!disconnected)
        #expect(probe.graph.tasks.isEmpty)
        #expect(try directory.historyRecords().isEmpty)
        let counts = requests.withLock { $0 }
        #expect(counts["thread/read:title", default: 0] == (discoveredByNotification ? 0 : 1))
        #expect(counts["thread/resume:title", default: 0] == 0)
        #expect(counts["thread/turns/list:title", default: 0] == 0)
        #expect(counts["thread/resume:normal"] == 1)
        #expect(counts["thread/turns/list:normal"] == 4)
    }

    @Test(arguments: ["missing", "null", "future_source", "THREAD_TITLE"])
    func otherSourcesKeepNormalSubscription(source: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let requests = Mutex([String: Int]())
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            while let request = try? peer.readMessage() {
                let method = request["method"] as? String ?? ""
                requests.withLock { $0[method, default: 0] += 1 }
                switch method {
                case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["normal"]])
                case "thread/read", "thread/resume": try peer.reply(to: request, result: ["thread": Self.thread("normal", source: source)])
                case "thread/turns/list": try peer.reply(to: request, result: ["data": []])
                default: Issue.record("Unexpected method: \(method)")
                }
            }
        }
        defer { server.close() }
        var ready = false
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { update in
            if update.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        if ready {
            #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        }
        await reader.stop()
        try server.finish()
        #expect(requests.withLock { $0["thread/resume"] } == 1)
        #expect(requests.withLock { $0["thread/turns/list"] } == 2)
    }

    @Test(arguments: [false, true])
    func ignoredThreadIsReconsideredAfterItsLoadingEnds(reconnect: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let stage = Mutex(0)
        let requests = Mutex([String: Int]())
        let server = try SharedServerFixture(connections: reconnect ? 2 : 1) { peer in
            try Self.initialize(peer)
            while let request = try? peer.readMessage() {
                let method = request["method"] as? String ?? ""
                requests.withLock { $0[method, default: 0] += 1 }
                let current = stage.withLock { $0 }
                switch method {
                case "thread/loaded/list":
                    try peer.reply(to: request, result: ["data": current == 1 ? [] : ["thread"]])
                case "thread/read", "thread/resume":
                    try peer.reply(to: request, result: ["thread": Self.thread("thread", source: current == 0 ? "thread_title" : "future_source")])
                case "thread/turns/list":
                    try peer.reply(to: request, result: ["data": []])
                default:
                    Issue.record("Unexpected method: \(method)")
                }
            }
        }
        defer { server.close() }
        var ready = false
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { update in
            if update.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        #expect(requests.withLock { $0["thread/resume", default: 0] } == 0)
        if reconnect {
            await reader.stop()
            stage.withLock { $0 = 2 }
            ready = false
            await reader.start()
            for _ in 0 ..< 200 where !ready {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(ready)
        } else {
            stage.withLock { $0 = 1 }
            #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
            stage.withLock { $0 = 2 }
            #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        }
        await reader.stop()
        try server.finish()
        #expect(requests.withLock { $0["thread/read"] } == 2)
        #expect(requests.withLock { $0["thread/resume"] } == 1)
        #expect(requests.withLock { $0["thread/turns/list"] } == 1)
    }

    private nonisolated static func initialize(_ peer: SharedServerFixture.Peer) throws {
        let request = try peer.readMessage()
        try peer.reply(to: request, result: ["userAgent": "codex/0.165.0"])
        _ = try peer.readMessage()
    }

    private nonisolated static func thread(_ id: String, source: String) -> [String: Any] {
        var thread: [String: Any] = ["id": id, "source": "vscode", "status": ["type": "idle"]]
        if source != "missing" {
            thread["threadSource"] = source == "null" ? NSNull() : source
        }
        return thread
    }

    private nonisolated static func sendTitleActivity(_ peer: SharedServerFixture.Peer) throws {
        try peer.send(["method": "turn/started", "params": [
            "threadId": "title", "turn": ["id": "title-turn", "status": "inProgress", "startedAt": Date().timeIntervalSince1970]
        ]])
        try peer.send(["method": "thread/tokenUsage/updated", "params": [
            "threadId": "title", "turnId": "title-turn", "tokenUsage": ["total": ["totalTokens": 10], "last": ["totalTokens": 10]]
        ]])
    }
}
