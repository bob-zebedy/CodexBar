import Foundation
import Testing

struct ActivityRecoveryTests {
    @Test func damagedDerivedCacheRecoversRefreshAndRebuild() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let store = TokenHistoryStore(directoryURL: directory.url)
        let id = TokenTurn.identifier(thread: "t", turn: "u")
        let record = TokenTurn(id: id, rootID: id, startedAt: now, updatedAt: now, usage: .zero)
        try await store.record([record], now: now)
        let cache = try directory.write("broken", to: "Aggregates/tokens.json")
        var refreshFailed = false
        var rebuildFailed = false
        do { _ = try await store.refresh(now: now) } catch { refreshFailed = true }
        try Data("broken".utf8).write(to: cache)
        do { _ = try await store.rebuild(for: [CodexDateFormat.dayString(from: now)], now: now) } catch { rebuildFailed = true }
        #expect(!refreshFailed && !rebuildFailed)
        try FileManager.default.removeItem(at: cache)
        let recovered = try await store.refresh(now: now)
        #expect(recovered.count == 1)
    }

    @Test(arguments: [false, true])
    func laterMalformedMessagePreservesEarlierValidEvent(_ malformed: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.160.0"])
            _ = try peer.readMessage()
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": ["thread"]])
            let thread: [String: Any] = ["id": "thread", "source": "cli", "createdAt": timestamp, "cwd": "/tmp", "status": ["type": "active", "activeFlags": []]]
            let read = try peer.readMessage()
            try peer.reply(to: read, result: ["thread": thread])
            let resume = try peer.readMessage()
            try peer.reply(to: resume, result: ["thread": thread])
            let turns = try peer.readMessage()
            try peer.send(["method": "item/started", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]]])
            if malformed {
                try peer.send(["method": "thread/status/changed", "params": ["threadId": "thread", "status": 123]])
            }
            try peer.reply(to: turns, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": timestamp]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var failed = false
        var live = 0
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(),
            socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            switch batch {
            case .sourceUnavailable: failed = true
            case let .live(events): live += events.count
            default: break
            }
        }
        await reader.start()
        for _ in 0 ..< 100 {
            if failed || live > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await reader.stop()
        release.signal()
        try server.finish()
        var recorded = 0
        let events = directory.url.appendingPathComponent("Events")
        if FileManager.default.fileExists(atPath: events.path) {
            for file in try FileManager.default.contentsOfDirectory(at: events, includingPropertiesForKeys: nil) {
                try AppServerEventJournal.read(at: file) {
                    if $0.activity != nil {
                        recorded += 1
                    }
                }
            }
        }
        #expect(recorded == 1)
        #expect(live == 1)
        #expect(!failed)
    }
}
