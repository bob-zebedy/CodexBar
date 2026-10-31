import Foundation
import Synchronization
import Testing

@Suite(.tags(.integration))
struct ActivityIsolationTests {
    @Test func cumulativeTokenNotificationsReachLogsStorageAndLiveTasks() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date().addingTimeInterval(-60)
        let server = try SharedServerFixture { peer in
            try peer.reply(to: peer.readMessage(), result: ["userAgent": "codex/0.162.1"])
            _ = try peer.readMessage()
            var emitted = false
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["healthy"]])
                case "thread/read", "thread/resume":
                    try peer.reply(to: request, result: ["thread": Self.thread("healthy", now: now)])
                case "thread/turns/list":
                    try peer.reply(to: request, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
                    if !emitted {
                        emitted = true
                        for total in [100, 100, 120, 120, 150] {
                            let tokenUsage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
                            try peer.send(["method": "thread/tokenUsage/updated", "params": [
                                "threadId": "healthy", "turnId": "turn", "tokenUsage": ["total": tokenUsage, "last": tokenUsage]
                            ]])
                        }
                        try peer.send(Self.tool(thread: "healthy", id: "received"))
                    }
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let logs = AppServerLogStore(directoryURL: directory.url.appendingPathComponent("Logs"))
        defer { await #expect(throws: Never.self) { try await logs.close() } }
        var received = false
        var liveUsage: Int64?
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: logs, tokenUsageHistory: store,
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { update in
            if update.phase == .live, !update.graph.tasks.isEmpty {
                received = true
            }
            liveUsage = update.graph.tasks[.init(thread: "healthy", turn: "turn")]?.tokenUsage?.totalTokens
        }
        await reader.start()
        for _ in 0 ..< 200 where !received || liveUsage != 50 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(received)
        #expect(await reader.stop())
        #expect(liveUsage == 50)
        #expect(try await store.refresh().first?.tokenUsage.totalTokens == 50)
        #expect(try await logs.page(limit: 100).entries.filter { $0.method == "thread/tokenUsage/updated" }.count == 5)
        try server.finish()
    }

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
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
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
                    try peer.reply(to: request, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
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
        let lifecycle = ActivityReaderProbe()
        var observed = false
        var disconnected = false
        let reader = AppServerActivityReader(
            probe: lifecycle, socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url), activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if case .sourceUnavailable = batch.phase {
                disconnected = true
            }
            if batch.phase == .live, batch.graph.tasks.keys.contains(where: { $0.threadID == "healthy" }) {
                observed = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !observed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed && !disconnected)
        let keys = ["a-broken", "healthy"].map { ActivityTaskKey(thread: $0, turn: "turn") }
        #expect(lifecycle.graph.tasks[keys[1]]?.lifecycleCoverageCheckedAt != nil)
        #expect(lifecycle.graph.tasks[keys[0]]?.lifecycleCoverageCheckedAt == nil)
        repaired.withLock { $0 = true }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(keys.allSatisfy { lifecycle.graph.tasks[$0]?.lifecycleCoverageCheckedAt != nil })
        #expect(lifecycle.graph.unavailableTurns.isDisjoint(with: keys))
        #expect(!disconnected)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func fullStorageBufferKeepsLiveReadingAndRetainsAcceptedEvents(byteLimit: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("blocked", to: "event.db")
        let now = Date().addingTimeInterval(-60)
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            try peer.reply(to: peer.readMessage(), result: ["data": ["healthy"]])
            for _ in 0 ..< 2 {
                try peer.reply(to: peer.readMessage(), result: ["thread": Self.thread("healthy", now: now)])
            }
            try peer.reply(to: peer.readMessage(), result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
            for id in ["one", "two", "three"] {
                try peer.send(Self.tool(thread: "healthy", id: id))
            }
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["healthy"]])
                case "thread/read", "thread/resume": try peer.reply(to: request, result: ["thread": Self.thread("healthy", now: now)])
                case "thread/turns/list":
                    try peer.reply(to: request, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        var failures = 0
        var observed = 0
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url), activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            maximumPendingEvents: byteLimit ? 4096 : 2, maximumPendingBytes: byteLimit ? 1 : 8 * 1024 * 1024
        ) { batch in
            if case .sourceUnavailable = batch.phase {
                failures += 1
            }
            if batch.phase == .live {
                observed += 1
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where observed < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failures == 0)
        #expect(observed == 3)
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        try FileManager.default.removeItem(at: blocker)
        await reader.stop()
        let recorded = try directory.historyRecords().filter { $0.activityData != nil }.count
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

extension ActivityIsolationTests {
    @Test func busyHistoryLockDoesNotDelayLiveTasksOrDrain() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let database = try HistoryDatabase(directoryURL: directory.url)
        try database.execute("BEGIN IMMEDIATE")
        defer { try? database.execute("ROLLBACK") }
        let phase = Mutex(0)
        let server = try Self.tokenServer(now: Date().addingTimeInterval(-60), phase: { phase.withLock { $0 } })
        defer { server.close() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        var observed = 0
        var disconnected = false
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url, logStorage: nil,
            tokenUsageHistory: store, activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if batch.phase == .live {
                observed += 1
            }
            if case .sourceUnavailable = batch.phase {
                disconnected = true
            }
        }
        await reader.start()
        for _ in 0 ..< 100 where observed == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == 1)
        phase.withLock { $0 = 1 }
        let started = ContinuousClock.now
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(observed == 2 && !disconnected)
        try database.execute("COMMIT")
        #expect(await reader.stop())
        let observations = try Self.observations(in: directory.url)
        #expect(observations.map { $0.delta?.totalTokens } == [0, 20, 30])
        #expect(try await store.refresh().first?.tokenUsage.totalTokens == 50)
        #expect(try await store.refresh().first?.tokenUsage.totalTokens == 50)
        try server.finish()
    }

    @Test func stopDoesNotWaitIndefinitelyForBusyStorageOrPublishLateResults() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let database = HistoryDatabaseStore.shared(in: directory.url)
        let blocked = Task {
            try await database.access { _ in
                entered.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 10)
            }
        }
        for _ in 0 ..< 100 where !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 })
        let server = try Self.tokenServer(now: Date().addingTimeInterval(-60), phase: { 0 })
        defer { server.close() }
        var observed = 0
        var batches = 0
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url, logStorage: nil,
            tokenUsageHistory: store, activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            batches += 1
            if batch.phase == .live {
                observed += 1
            }
        }
        await reader.start()
        for _ in 0 ..< 100 where observed == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == 1)
        let started = ContinuousClock.now
        #expect(await reader.stop() == false)
        #expect(ContinuousClock.now - started < .seconds(3))
        let countAtStop = batches
        release.signal()
        try await blocked.value
        // 再次停止等待旧工作循环释放资源, 不能发布已停止连接的状态
        _ = await reader.stop()
        #expect(batches == countAtStop)
        #expect(try store.acquireRecordingLease())
        store.releaseRecordingLease()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func brokenTokenCacheDoesNotInterruptLiveCollection(corruptWhileRunning: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date().addingTimeInterval(-60)
        let phase = Mutex(0)
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let oldDate = HistoryStorage.dateKey(for: now.addingTimeInterval(-86400))
        func corruptHistory() throws {
            let database = try HistoryDatabase(directoryURL: directory.url)
            try database.execute("INSERT OR IGNORE INTO days(date) VALUES (?)", [.text(oldDate)])
            try database.execute("INSERT INTO events(date, kind, payload) VALUES (?, 'tokenUsage', ?)", [.text(oldDate), .data(Data("broken".utf8))])
        }
        if !corruptWhileRunning {
            try corruptHistory()
        }
        let server = try Self.tokenServer(now: now, phase: { phase.withLock { $0 } })
        defer { server.close() }
        var observed = 0
        var disconnected = false
        let lifecycle = ActivityReaderProbe()
        let reader = AppServerActivityReader(
            probe: lifecycle, socketURL: server.url, logStorage: nil,
            tokenUsageHistory: store, activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if case .sourceUnavailable = batch.phase {
                disconnected = true
            }
            if batch.phase == .live {
                observed += 1
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where observed < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == 1)
        if corruptWhileRunning {
            try corruptHistory()
        }
        phase.withLock { $0 = 1 }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(observed == 2)
        // 给周期缓存刷新一次触发机会, 失败不能使实时连接失效
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(!disconnected)
        let key = ActivityTaskKey(thread: "healthy", turn: "turn")
        #expect(lifecycle.graph.tasks[key]?.lifecycleCoverageCheckedAt != nil)
        #expect(!lifecycle.graph.unavailableTurns.contains(key))
        #expect(try await store.refresh().first?.tokenUsage.totalTokens == 50)
        #expect(try await store.loadSnapshot().coverage == .partial)
        let observations = try Self.observations(in: directory.url)
        #expect(Set(observations.map(\.id)).count == 3)
        #expect(observations.map { $0.delta?.totalTokens } == [0, 20, 30])
        try HistoryDatabase(directoryURL: directory.url).execute("DELETE FROM days WHERE date = ?", [.text(oldDate)])
        let recovered = try await store.refresh()
        #expect(recovered.first?.tokenUsage.totalTokens == 50)
        #expect(try await store.refresh() == recovered)
        #expect(await reader.stop())
        try server.finish()
    }

    private nonisolated static func tokenServer(now: Date, phase: @escaping @Sendable () -> Int) throws -> SharedServerFixture {
        try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            var emitted = false
            var emittedPhase = 0
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/loaded/list":
                    let nextPhase = phase()
                    if nextPhase > emittedPhase {
                        emittedPhase = nextPhase
                        try peer.send(Self.tokenUsage(nextPhase == 1 ? 50 : 80))
                        if nextPhase == 2 {
                            try peer.send(Self.tokenUsage(130))
                        }
                        try peer.send(Self.tool(thread: "healthy", id: "phase-\(nextPhase)"))
                    }
                    try peer.reply(to: request, result: ["data": ["healthy"]])
                case "thread/read", "thread/resume":
                    try peer.reply(to: request, result: ["thread": Self.thread("healthy", now: now)])
                case "thread/turns/list":
                    try peer.reply(to: request, result: ["data": [["id": "turn", "rootTurnId": "turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]])
                    if !emitted {
                        emitted = true
                        try peer.send(Self.tokenUsage(0))
                        try peer.send(Self.tokenUsage(20))
                        try peer.send(Self.tool(thread: "healthy", id: "first"))
                    }
                default: Issue.record("Unexpected request")
                }
            }
        }
    }

    private nonisolated static func observations(in directory: URL) throws -> [TokenUsageObservation] {
        var observations: [TokenUsageObservation] = []
        try HistoryDatabase(directoryURL: directory).entries(date: HistoryStorage.dateKey(for: Date())) {
            if let observation = $0.record.tokenUsage {
                observations.append(observation)
            }
        }
        return observations
    }

    private nonisolated static func tokenUsage(_ total: Int) -> [String: Any] {
        let counts = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
        return ["method": "thread/tokenUsage/updated", "params": [
            "threadId": "healthy", "turnId": "turn", "tokenUsage": ["total": counts, "last": counts]
        ]]
    }
}

extension ActivityIsolationTests {
    @Test func fullObservationQueueContinuesBaselineAfterStorageRecovery() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("blocked", to: "event.db")
        let phase = Mutex(0)
        let server = try Self.tokenServer(now: Date().addingTimeInterval(-60), phase: { phase.withLock { $0 } })
        defer { server.close() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        var observed = 0
        var disconnected = false
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url, logStorage: nil,
            tokenUsageHistory: store, activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url), maximumPendingEvents: 1
        ) { batch in
            if case .sourceUnavailable = batch.phase {
                disconnected = true
            }
            if batch.phase == .live {
                observed += 1
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where observed < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == 1)
        phase.withLock { $0 = 1 }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(observed == 2)
        try FileManager.default.removeItem(at: blocker)
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("event.db").path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        phase.withLock { $0 = 2 }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(observed == 3)
        #expect(!disconnected)
        #expect(await reader.stop())
        let observations = try Self.observations(in: directory.url)
        #expect(observations.map { $0.delta?.totalTokens } == [0, 80])
        #expect(Set(observations.map(\.id)).count == 2)
        let restored = try await store.refresh()
        #expect(restored.first?.tokenUsage.totalTokens == 80)
        #expect(try await store.refresh() == restored)
        try server.finish()
    }
}
