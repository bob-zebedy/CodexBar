import Foundation
import Testing

struct ActivityRecoveryTests {
    @Test func damagedDerivedCacheRecoversRefreshAndRebuild() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        try await store.appendObservation(TestFixtures.tokenUsageObservation(at: now, tokenUsage: .zero), now: now)
        _ = try await store.refresh(now: now)
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("UPDATE aggregates SET tokenUsage = ?", [.data(Data("broken".utf8))])
        var refreshFailed = false
        var rebuildFailed = false
        do { _ = try await store.refresh(now: now) } catch { refreshFailed = true }
        try database.execute("UPDATE aggregates SET tokenUsage = ?", [.data(Data("broken".utf8))])
        do { _ = try await store.rebuild(for: [CodexDateFormat.dayString(from: now)]) } catch { rebuildFailed = true }
        #expect(!refreshFailed && !rebuildFailed)
        try database.execute("""
        UPDATE aggregates SET tokenUsage = NULL
        """)
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
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
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
            probe: ActivityReaderProbe(),
            socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            switch batch.phase {
            case .sourceUnavailable: failed = true
            case .live: live += batch.graph.tasks.count
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
        let recorded = try directory.historyRecords().filter { $0.activityData != nil }.count
        #expect(recorded == 1)
        #expect(live == 1)
        #expect(!failed)
    }
}
