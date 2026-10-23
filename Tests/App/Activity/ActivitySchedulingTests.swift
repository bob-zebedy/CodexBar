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
            try peer.reply(to: turns, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": timestamp]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let lifecycle = ActivityReaderProbe()
        var ready = false
        let reader = AppServerActivityReader(
            probe: lifecycle, socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if case .bootstrapEnd = batch.phase {
                ready = true
            }
            if batch.phase == .live, batch.graph.tasks.values.contains(where: { $0.lastProgressAt > Date(timeIntervalSince1970: timestamp) }) {
                observed.signal()
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        #expect(await reader.drainNow().status == .partial)
        #expect(lifecycle.graph.tasks[.init(thread: "thread", turn: "turn")]?.state == .waitingApproval)
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
            for total in [100, 120, 150] {
                let tokenUsage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
                try peer.send(["method": "thread/tokenUsage/updated", "params": ["threadId": "thread", "turnId": "turn", "tokenUsage": ["total": tokenUsage, "last": tokenUsage]]])
            }
            try peer.send(["method": "thread/status/changed", "params": ["threadId": "thread", "status": 123]])
            // 后续通知作为处理屏障, 避免在畸形消息被消费前结束测试
            try peer.send(["method": "account/updated", "params": [:]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var failed = false
        var receivedFollowup = false
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: store, activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            onAccountChange: { _ in receivedFollowup = true },
            onBatch: {
                if case .sourceUnavailable = $0.phase {
                    failed = true
                }
            }
        )
        await reader.start()
        for _ in 0 ..< 200 where !receivedFollowup && !failed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(receivedFollowup)
        #expect(!failed)
        await reader.stop()
        #expect(try await store.refresh().first?.tokenUsage.totalTokens == 50)
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
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url), onBatch: { _ in }
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
        let lifecycle = ActivityReaderProbe()
        var ready = false
        var disconnected = false
        var tools = 0
        let reader = AppServerActivityReader(
            probe: lifecycle, socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if case .bootstrapEnd = batch.phase {
                ready = true
            }
            if case .sourceUnavailable = batch.phase {
                disconnected = true
            }
            if batch.phase == .live {
                tools += batch.graph.tasks.values.filter { $0.snapshot.presentation?.current.key == "command" }.count
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
            #expect(await reader.drainNow().status == .completed)
            let key = ActivityTaskKey(thread: "a-missing", turn: "turn")
            #expect(lifecycle.graph.tasks[key]?.lifecycleCoverageCheckedAt != nil)
            #expect(!lifecycle.graph.unavailableTurns.contains(key))
            #expect(!disconnected)
        }
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func persistedEventIsPublishedOnceAfterMaintenanceWriteRecovers() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("block maintenance directory", to: "event.db")
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
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if case .sourceUnavailable = batch.phase {
                failures += 1
            }
            if batch.phase == .live {
                published += 1
            }
        }
        await reader.start()
        for _ in 0 ..< 100 where published == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(published == 1)
        #expect(failures == 0)
        try FileManager.default.removeItem(at: blocker)
        for _ in 0 ..< 150 where try HistoryDatabase(directoryURL: directory.url).dates().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try !HistoryDatabase(directoryURL: directory.url).dates().isEmpty)
        #expect(failures == 0)
        #expect(published == 1)
        await reader.stop()
        release.signal()
        try server.finish()
        let recorded = try directory.historyRecords().filter { $0.activityData != nil }.count
        #expect(recorded == 1)
    }

    private nonisolated static func serveMissingRollout(
        _ peer: SharedServerFixture.Peer,
        timestamp: Double,
        release: DispatchSemaphore,
        onDiscovery: @Sendable () -> Void
    ) throws {
        let initialize = try peer.readMessage()
        try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
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
        // 单会话失败后继续初始化其他会话, 不重新 initialize
        for method in ["thread/read", "thread/resume"] {
            let request = try peer.readMessage()
            #expect(request["method"] as? String == method)
            try peer.reply(to: request, result: ["thread": Self.thread(timestamp)])
        }
        let turns = try peer.readMessage()
        try peer.reply(to: turns, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": timestamp]]])
        try peer.send(["method": "item/started", "params": [
            "threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]
        ]])
        // 普通发现不立即重试不可用会话, 健康会话仍可接收推送
        for _ in 0 ..< 2 {
            let request = try peer.readMessage()
            #expect(request["method"] as? String == "thread/loaded/list")
            try peer.reply(to: request, result: ["data": ["a-missing", "thread"]])
            onDiscovery()
        }
        // 强制核对重新尝试失败会话, 服务端恢复后无需重连即可加入
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
            #expect((request["params"] as? [String: Any])?["itemsView"] as? String == "notLoaded")
            try peer.reply(to: request, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": timestamp]]])
        }
        _ = release.wait(timeout: .now() + 5)
    }

    private nonisolated static func thread(_ timestamp: Double, status: String = "active") -> [String: Any] {
        ["id": "thread", "source": "cli", "createdAt": timestamp, "cwd": "/tmp", "status": ["type": status, "activeFlags": []]]
    }

    private nonisolated static func bootstrap(_ peer: SharedServerFixture.Peer, timestamp: Double, idle: Bool = false) throws {
        let initialize = try peer.readMessage()
        try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
        _ = try peer.readMessage()
        let loaded = try peer.readMessage()
        try peer.reply(to: loaded, result: ["data": ["thread"]])
        for _ in 0 ..< 2 {
            let request = try peer.readMessage()
            try peer.reply(to: request, result: ["thread": thread(timestamp, status: idle ? "idle" : "active")])
        }
        let turns = try peer.readMessage()
        #expect(turns["method"] as? String == "thread/turns/list")
        #expect((turns["params"] as? [String: Any])?["itemsView"] as? String == "notLoaded")
        try peer.reply(to: turns, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": idle ? "completed" : "inProgress", "startedAt": timestamp]]])
    }
}

extension ActivitySchedulingTests {
    @Test(arguments: ["mcpServer/elicitation/request", "item/tool/requestUserInput", "item/completed"])
    func snapshotCannotDismissNewInputRequest(method: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: timestamp)
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": ["thread"]])
            let read = try peer.readMessage()
            var params: [String: Any] = ["threadId": "thread", "turnId": "turn", "mode": "form", "isBlocking": false]
            if method == "item/completed" {
                params["item"] = ["id": "input", "type": "agentMessage", "delivery": "async", "questions": [["title": "Test question?"]]]
            }
            try peer.send(["id": "input", "method": method, "params": params])
            try peer.reply(to: read, result: ["thread": Self.thread(timestamp, status: "idle")])
            let turns = try peer.readMessage()
            try peer.reply(to: turns, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": timestamp]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var ready = false
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil, tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            if $0.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await reader.drainNow().status == .partial)
        let state = await reader.lifecycleStatesForTesting(for: [.init(threadID: "thread", turnID: "turn")]).first
        #expect(state?.presentation?.summary.waiting != nil)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func staleTurnResponseCannotResurrectCompletedTurnOrReplaceNewTurn() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: timestamp)
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": ["thread"]])
            let read = try peer.readMessage()
            try peer.reply(to: read, result: ["thread": Self.thread(timestamp)])
            let turns = try peer.readMessage()
            try peer.send(["method": "turn/completed", "params": ["threadId": "thread", "turn": [
                "id": "turn", "rootTurnId": "turn", "status": "completed", "completedAt": timestamp + 20
            ]]])
            try peer.send(["method": "turn/started", "params": ["threadId": "thread", "turn": [
                "id": "new-turn", "rootTurnId": "new-turn", "status": "inProgress", "startedAt": timestamp + 30
            ]]])
            try peer.reply(to: turns, result: ["data": [[
                "id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": timestamp
            ]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let probe = ActivityReaderProbe()
        var ready = false
        let reader = AppServerActivityReader(
            probe: probe, socketURL: server.url, tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            if $0.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        #expect(await reader.drainNow().status == .partial)
        #expect(probe.graph.tasks[.init(thread: "thread", turn: "turn")] == nil)
        #expect(probe.graph.tasks[.init(thread: "thread", turn: "new-turn")]?.state == .running)
        #expect(probe.graph.completions.count == 1)
        let old = await reader.lifecycleStatesForTesting(for: [.init(threadID: "thread", turnID: "turn")]).first
        #expect(old?.terminal != nil)
        #expect(old?.turnStatus == .completed)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func tokenAndToolUpdatesDoNotPreventSuccessfulDrain() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: timestamp)
            var total = 100
            while let request = try? peer.readMessage() {
                let usage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
                try peer.send(["method": "thread/tokenUsage/updated", "params": [
                    "threadId": "thread", "turnId": "turn", "tokenUsage": ["total": usage, "last": usage]
                ]])
                try peer.send(["method": "item/started", "params": [
                    "threadId": "thread", "turnId": "turn", "item": ["id": "tool-\(total)", "type": "commandExecution"]
                ]])
                total += 10
                switch request["method"] as? String {
                case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["thread"]])
                case "thread/read": try peer.reply(to: request, result: ["thread": Self.thread(timestamp)])
                case "thread/turns/list": try peer.reply(to: request, result: ["data": [[
                        "id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": timestamp
                    ]]])
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let probe = ActivityReaderProbe()
        var ready = false
        let reader = AppServerActivityReader(
            probe: probe, socketURL: server.url, tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            if $0.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0 ..< 3 {
            #expect(await reader.drainNow().status == .completed)
        }
        for _ in 0 ..< 100 where probe.graph.tasks[.init(thread: "thread", turn: "turn")]?.tokenUsage?.totalTokens != 80 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(probe.graph.tasks[.init(thread: "thread", turn: "turn")]?.tokenUsage?.totalTokens == 80)
        #expect(probe.graph.unavailableTurns.isEmpty)
        await reader.stop()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func turnPaginationResumesAndDoesNotVerifyOmittedTurn(withUpdates: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: timestamp)
            for cycle in 0 ..< 2 {
                let loaded = try peer.readMessage()
                try peer.reply(to: loaded, result: ["data": ["thread"]])
                let read = try peer.readMessage()
                try peer.reply(to: read, result: ["thread": Self.thread(timestamp, status: "idle")])
                let first = try peer.readMessage()
                #expect((first["params"] as? [String: Any])?["cursor"] == nil)
                let recent = (0 ..< 10).map { ["id": "recent-\($0)", "status": "completed"] }
                try peer.reply(to: first, result: ["data": recent, "nextCursor": "page-1"])
                if cycle == 0 {
                    for page in 1 ... 8 {
                        let request = try peer.readMessage()
                        #expect((request["params"] as? [String: Any])?["cursor"] as? String == "page-\(page)")
                        if withUpdates {
                            let usage = ["inputTokens": page * 10, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": page * 10]
                            try peer.send(["method": "thread/tokenUsage/updated", "params": [
                                "threadId": "thread", "turnId": "turn", "tokenUsage": ["total": usage, "last": usage]
                            ]])
                            try peer.send(["method": "item/started", "params": [
                                "threadId": "thread", "turnId": "turn", "item": ["id": "live-\(page)", "type": "commandExecution"]
                            ]])
                        }
                        try peer.reply(to: request, result: ["data": [["id": "history-\(page)", "status": "completed"]], "nextCursor": "page-\(page + 1)"])
                    }
                } else {
                    let request = try peer.readMessage()
                    #expect((request["params"] as? [String: Any])?["cursor"] as? String == "page-9")
                    try peer.reply(to: request, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "completed", "completedAt": timestamp + 30]]])
                }
            }
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let cache = ActivityReaderProbe()
        var ready = false
        let reader = AppServerActivityReader(
            probe: cache,
            socketURL: server.url,
            logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            if case .bootstrapEnd = $0.phase {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        let key = ActivityTaskKey(thread: "thread", turn: "turn")
        #expect(await reader.drainNow().status == .partial)
        #expect(cache.graph.unavailableTurns.contains(key))
        #expect(await reader.drainNow().status == .completed)
        #expect(cache.graph.tasks[key] == nil)
        #expect(cache.graph.completions.count == 1)
        #expect(cache.graph.recentlyEndedTaskAt[key] != nil)
        #expect(await reader.stop())
        release.signal()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func stopWaitsForPendingWritesAndReportsPersistenceFailure(failFirstStop: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("block maintenance directory", to: "event.db")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            try Self.bootstrap(peer, timestamp: Date().addingTimeInterval(-60).timeIntervalSince1970)
            try peer.send(["method": "item/started", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var published = false
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(),
            socketURL: server.url,
            logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            if $0.phase == .live, !$0.graph.tasks.isEmpty {
                published = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !published {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(published)
        if failFirstStop {
            #expect(await reader.stop() == false)
        }
        try FileManager.default.removeItem(at: blocker)
        #expect(await reader.stop())
        let count = try directory.historyRecords().filter { $0.activityData != nil }.count
        #expect(count == 1)
        #expect(try !HistoryDatabase(directoryURL: directory.url).pendingActivityDataDates().isEmpty)
        release.signal()
        try server.finish()
    }
}
