import Foundation
import Synchronization
import Testing

struct ActivityIsolationTests {
    @Test(arguments: [false, true])
    func brokenThreadDoesNotStopHealthyThreadAndCanRecover(brokenQuery: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let repaired = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let now = Date().addingTimeInterval(-60)
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.160.0"])
            _ = try peer.readMessage()
            var emitted = false
            while let request = try? peer.readMessage() {
                let method = request["method"] as? String
                let id = (request["params"] as? [String: Any])?["threadId"] as? String ?? ""
                switch method {
                case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["a-broken", "healthy"]])
                case "thread/read", "thread/resume":
                    if id == "a-broken", brokenQuery, !repaired.withLock({ $0 }) {
                        try peer.reply(to: request, result: ["thread": 123])
                    } else {
                        try peer.reply(to: request, result: ["thread": Self.thread(id, now: now)])
                    }
                case "thread/turns/list":
                    try peer.reply(to: request, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
                    if id == "healthy", !emitted {
                        emitted = true
                        if !brokenQuery {
                            try peer.send(["method": "thread/status/changed", "params": ["threadId": "a-broken", "status": 123]])
                        }
                        try peer.send(Self.tool(thread: "healthy", id: "tool"))
                    }
                    if id == "healthy", repaired.withLock({ $0 }) {
                        _ = release.wait(timeout: .now() + 5)
                        return
                    }
                default: Issue.record("Unexpected request: \(String(describing: method))")
                }
            }
        }
        defer { server.close() }
        let lifecycle = SessionLifecycleCache()
        var observed = false
        var disconnected = false
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycle, socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url), recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .sourceUnavailable = batch {
                disconnected = true
            }
            if case let .live(events) = batch, events.contains(where: { $0.sessionID == "healthy" }) {
                observed = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !observed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed && !disconnected)
        let references = ["a-broken", "healthy"].map { ActivityTurnReference(threadID: $0, turnID: "turn", startedAt: now) }
        let states = await lifecycle.lifecycleStates(for: references)
        #expect(states.first { $0.requestedThreadID == "healthy" }?.readStatus == .complete)
        #expect(states.first { $0.requestedThreadID == "a-broken" }?.readStatus == .unavailable)
        repaired.withLock { $0 = true }
        #expect(await reader.drainNow() == .completed)
        #expect(await lifecycle.lifecycleStates(for: references).allSatisfy { $0.readStatus == .complete })
        #expect(!disconnected)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func fullStorageBufferStopsReadingAndKeepsAcceptedEvents(byteLimit: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("blocked", to: "State")
        let now = Date().addingTimeInterval(-60)
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.160.0"])
            _ = try peer.readMessage()
            try peer.reply(to: peer.readMessage(), result: ["data": ["healthy"]])
            for _ in 0 ..< 2 {
                try peer.reply(to: peer.readMessage(), result: ["thread": Self.thread("healthy", now: now)])
            }
            try peer.reply(to: peer.readMessage(), result: ["data": [["id": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
            for id in ["one", "two", "three"] {
                try peer.send(Self.tool(thread: "healthy", id: id))
            }
            _ = try? peer.readMessage()
        }
        defer { server.close() }
        var failures = 0
        var observed = 0
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url), recorder: ActivityRecorder(directoryURL: directory.url),
            maximumPendingEvents: byteLimit ? 4096 : 2, maximumPendingBytes: byteLimit ? 1 : 8 * 1024 * 1024
        ) { batch in
            if case .sourceUnavailable = batch {
                failures += 1
            }
            if case let .live(events) = batch {
                observed += events.count
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where failures == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failures == 1)
        #expect(observed == (byteLimit ? 1 : 2))
        #expect(await reader.drainNow() == .sourceUnavailable)
        try FileManager.default.removeItem(at: blocker)
        await reader.stop()
        var recorded = 0
        let files = try FileManager.default.contentsOfDirectory(at: directory.url.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
        for file in files {
            try AppServerEventJournal.read(at: file) {
                if $0.activity != nil {
                    recorded += 1
                }
            }
        }
        #expect(recorded == (byteLimit ? 1 : 2))
        try server.finish()
    }

    private nonisolated static func thread(_ id: String, now: Date) -> [String: Any] {
        ["id": id, "source": "cli", "createdAt": now.timeIntervalSince1970, "cwd": "/tmp", "status": ["type": "active", "activeFlags": []]]
    }

    private nonisolated static func tool(thread: String, id: String) -> [String: Any] {
        ["method": "item/started", "params": ["threadId": thread, "turnId": "turn", "item": ["id": id, "type": "commandExecution"]]]
    }
}
