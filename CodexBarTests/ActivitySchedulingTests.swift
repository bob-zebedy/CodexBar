import Foundation
import Synchronization
import Testing

struct ActivitySchedulingTests {
    @Test func slowQueryDoesNotBlockPushOrOverwriteNewerApproval() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let observed = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { observed.signal()
            release.signal()
        }
        let timestamp = Date().timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: timestamp)
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": ["thread"]])
            let read = try peer.readMessage()
            try peer.send(["method": "thread/status/changed", "params": ["threadId": "thread", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]]])
            try peer.send(["method": "item/started", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]]])
            // 如果客户端要等 read 响应才消费推送, 此处会超时
            #expect(observed.wait(timeout: .now() + 2) == .success)
            try peer.reply(to: read, result: ["thread": Self.thread(timestamp, status: "idle")])
            let turns = try peer.readMessage()
            try peer.reply(to: turns, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": timestamp]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let lifecycle = SessionLifecycleCache()
        var ready = false
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycle, socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .bootstrapEnd = batch {
                ready = true
            }
            if case let .live(events) = batch, events.contains(where: { $0.eventKind == .toolStarted }) {
                observed.signal()
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        #expect(await reader.drainNow() == .completed)
        let reference = ActivityTurnReference(threadID: "thread", turnID: "turn", startedAt: Date(timeIntervalSince1970: timestamp))
        #expect(await lifecycle.lifecycleStates(for: [reference]).first?.isWaitingApproval == true)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func tokenUpdatesBeforeMalformedMessageArePersisted() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: timestamp)
            for total in [100, 150] {
                let usage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
                try peer.send(["method": "thread/tokenUsage/updated", "params": ["threadId": "thread", "turnId": "turn", "tokenUsage": ["total": usage, "last": usage]]])
            }
            try peer.send(["method": "thread/status/changed", "params": ["threadId": "thread", "status": 123]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var failed = false
        let store = TokenHistoryStore(directoryURL: directory.url)
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url,
            tokenHistory: store, recorder: ActivityRecorder(directoryURL: directory.url)
        ) {
            if case .sourceUnavailable = $0 {
                failed = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !failed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!failed)
        await reader.stop()
        #expect(try await store.refresh().first?.usage?.totalTokens == 50)
        release.signal()
        try server.finish()
    }

    @Test func idleThreadsAreNotFullyReadOnEveryDiscovery() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: Date().timeIntervalSince1970, idle: true)
            for _ in 0 ..< 2 {
                let loaded = try peer.readMessage()
                #expect(loaded["method"] as? String == "thread/loaded/list")
                try peer.reply(to: loaded, result: ["data": ["thread"]])
            }
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url), onBatch: { _ in }
        )
        await reader.start()
        try await Task.sleep(for: .milliseconds(4400))
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func missingRolloutDoesNotDisconnectOtherThreadsAndCanRecover() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let discoveries = Mutex(0)
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.serveMissingRollout(peer, timestamp: timestamp, release: release) {
                discoveries.withLock { $0 += 1 }
            }
        }
        defer { server.close() }
        let lifecycle = SessionLifecycleCache()
        var ready = false
        var disconnected = false
        var tools = 0
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycle, socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .bootstrapEnd = batch {
                ready = true
            }
            if case .sourceUnavailable = batch {
                disconnected = true
            }
            if case let .live(events) = batch {
                tools += events.filter { $0.eventKind == .toolStarted }.count
            }
        }
        await reader.start()
        for _ in 0 ..< 600 where discoveries.withLock({ $0 }) < 2 && !disconnected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready)
        #expect(!disconnected)
        #expect(tools == 1)
        #expect(discoveries.withLock { $0 } == 2)
        if ready, !disconnected {
            #expect(await reader.drainNow() == .completed)
            let reference = ActivityTurnReference(threadID: "a-missing", turnID: "turn", startedAt: Date(timeIntervalSince1970: timestamp))
            #expect(await lifecycle.lifecycleStates(for: [reference]).first?.readStatus == .complete)
            #expect(!disconnected)
        }
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func persistedEventIsPublishedOnceAfterMaintenanceWriteRecovers() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("block maintenance directory", to: "State")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: Date().addingTimeInterval(-60).timeIntervalSince1970)
            try peer.send(["method": "item/started", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var failures = 0
        var published = 0
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .sourceUnavailable = batch {
                failures += 1
            }
            if case let .live(events) = batch {
                published += events.count
            }
        }
        await reader.start()
        for _ in 0 ..< 100 where published == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(published == 1)
        #expect(failures == 0)
        try FileManager.default.removeItem(at: blocker)
        for _ in 0 ..< 150 where HistoryStorage.loadMaintenanceState(in: directory.url).days.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!HistoryStorage.loadMaintenanceState(in: directory.url).days.isEmpty)
        #expect(failures == 0)
        #expect(published == 1)
        await reader.stop()
        release.signal()
        try server.finish()
        var recorded = 0
        let files = try FileManager.default.contentsOfDirectory(at: HistoryStorage.eventsDirectoryURL(in: directory.url), includingPropertiesForKeys: nil)
        for file in files {
            try AppServerEventJournal.read(at: file) {
                if $0.activity != nil {
                    recorded += 1
                }
            }
        }
        #expect(recorded == 1)
    }

    private nonisolated static func serveMissingRollout(
        _ peer: SharedServerFixture.Peer,
        timestamp: Double,
        release: DispatchSemaphore,
        onDiscovery: @Sendable () -> Void
    ) throws {
        let initialize = try peer.readMessage()
        try peer.reply(to: initialize, result: ["userAgent": "codex/0.160.0"])
        #expect(try peer.readMessage()["method"] as? String == "initialized")
        let loaded = try peer.readMessage()
        try peer.reply(to: loaded, result: ["data": ["a-missing", "thread"]])
        var missing = Self.thread(timestamp, status: "idle")
        missing["id"] = "a-missing"
        missing["ephemeral"] = false
        let read = try peer.readMessage()
        #expect(read["method"] as? String == "thread/read")
        try peer.reply(to: read, result: ["thread": missing])
        let resume = try peer.readMessage()
        #expect(resume["method"] as? String == "thread/resume")
        try peer.send(["id": #require(resume["id"]), "error": [
            "code": -32600, "message": "no rollout found for thread id a-missing"
        ]])
        // 单线程失败后继续初始化其他线程, 不重新 initialize
        for method in ["thread/read", "thread/resume"] {
            let request = try peer.readMessage()
            #expect(request["method"] as? String == method)
            try peer.reply(to: request, result: ["thread": Self.thread(timestamp)])
        }
        let turns = try peer.readMessage()
        try peer.reply(to: turns, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": timestamp]]])
        try peer.send(["method": "item/started", "params": [
            "threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]
        ]])
        // 普通发现不立即重试不可用线程, 健康线程仍可接收推送
        for _ in 0 ..< 2 {
            let request = try peer.readMessage()
            #expect(request["method"] as? String == "thread/loaded/list")
            try peer.reply(to: request, result: ["data": ["a-missing", "thread"]])
            onDiscovery()
        }
        // 强制对账重新尝试失败线程, 服务端恢复后无需重连即可加入
        let discovery = try peer.readMessage()
        #expect(discovery["method"] as? String == "thread/loaded/list")
        try peer.reply(to: discovery, result: ["data": ["a-missing", "thread"]])
        for id in ["a-missing", "thread"] {
            var thread = Self.thread(timestamp)
            thread["id"] = id
            let methods = id == "a-missing" ? ["thread/read", "thread/resume"] : ["thread/read"]
            for method in methods {
                let request = try peer.readMessage()
                #expect(request["method"] as? String == method)
                #expect((request["params"] as? [String: Any])?["threadId"] as? String == id)
                try peer.reply(to: request, result: ["thread": thread])
            }
            let request = try peer.readMessage()
            #expect(request["method"] as? String == "thread/turns/list")
            try peer.reply(to: request, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": timestamp]]])
        }
        _ = release.wait(timeout: .now() + 5)
    }

    private nonisolated static func thread(_ timestamp: Double, status: String = "active") -> [String: Any] {
        ["id": "thread", "source": "cli", "createdAt": timestamp, "cwd": "/tmp", "status": ["type": status, "activeFlags": []]]
    }

    private nonisolated static func bootstrap(_ peer: SharedServerFixture.Peer, timestamp: Double, idle: Bool = false) throws {
        let initialize = try peer.readMessage()
        try peer.reply(to: initialize, result: ["userAgent": "codex/0.160.0"])
        _ = try peer.readMessage()
        let loaded = try peer.readMessage()
        try peer.reply(to: loaded, result: ["data": ["thread"]])
        for _ in 0 ..< 2 {
            let request = try peer.readMessage()
            try peer.reply(to: request, result: ["thread": thread(timestamp, status: idle ? "idle" : "active")])
        }
        let turns = try peer.readMessage()
        try peer.reply(to: turns, result: ["data": [["id": "turn", "status": idle ? "completed" : "inProgress", "startedAt": timestamp]]])
    }
}
