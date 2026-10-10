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
            if case let .live(events) = batch, events.contains(where: { $0.threadID == "healthy" }) {
                observed = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !observed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed && !disconnected)
        let references = ["a-broken", "healthy"].map { ActivityTurnReference(threadID: $0, turnID: "turn") }
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
    func fullStorageBufferKeepsLiveReadingAndRetainsAcceptedEvents(byteLimit: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("blocked", to: "State")
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
        for _ in 0 ..< 200 where observed < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(failures == 0)
        #expect(observed == 3)
        #expect(await reader.drainNow() == .completed)
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

extension ActivityIsolationTests {
    @Test func busyHistoryLockDoesNotDelayLiveTasksOrDrain() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let lockURL = HistoryStorage.lockURL(in: directory.url)
        var descriptor = try JSONFileStorage.acquireLock(in: lockURL.deletingLastPathComponent(), name: lockURL.lastPathComponent, nonblocking: true)
        defer {
            if let descriptor {
                JSONFileStorage.releaseLock(descriptor)
            }
        }
        let phase = Mutex(0)
        let server = try Self.tokenServer(now: Date().addingTimeInterval(-60), phase: { phase.withLock { $0 } })
        defer { server.close() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        var observed = 0
        var disconnected = false
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url, logStorage: nil,
            tokenHistory: store, recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case let .live(events) = batch {
                observed += events.count
            }
            if case .sourceUnavailable = batch {
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
        #expect(await reader.drainNow() == .completed)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(observed == 2 && !disconnected)
        try JSONFileStorage.releaseLock(#require(descriptor))
        descriptor = nil
        #expect(await reader.stop())
        let observations = try Self.observations(in: directory.url)
        #expect(observations.map(\.current.totalTokens) == [120, 150])
        #expect(try await store.refresh().first?.usage?.totalTokens == 50)
        #expect(try await store.refresh().first?.usage?.totalTokens == 50)
        try server.finish()
    }

    @Test func stopDoesNotWaitIndefinitelyForBusyStorageOrPublishLateResults() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let blocked = Task { await store.holdForReaderTest(entered: { entered.withLock { $0 = true } }, release: release) }
        for _ in 0 ..< 100 where !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(entered.withLock { $0 })
        let server = try Self.tokenServer(now: Date().addingTimeInterval(-60), phase: { 0 })
        defer { server.close() }
        var observed = 0
        var batches = 0
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url, logStorage: nil,
            tokenHistory: store, recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            batches += 1
            if case let .live(events) = batch {
                observed += events.count
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
        await blocked.value
        // 再次停止等待旧工作循环释放资源, 不能发布已停止连接的状态
        _ = await reader.stop()
        #expect(batches == countAtStop)
        #expect(try await store.acquireRecordingLease())
        await store.releaseRecordingLease()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func brokenTokenCacheDoesNotInterruptLiveCollection(corruptWhileRunning: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date().addingTimeInterval(-60)
        let phase = Mutex(0)
        let store = TokenHistoryStore(directoryURL: directory.url)
        let oldDate = HistoryStorage.dateKey(for: now.addingTimeInterval(-86400))
        func corruptHistory() throws -> URL {
            _ = try directory.write("broken cache", to: "Aggregates/tokens.json")
            return try directory.writeJournal(Data("broken event\n".utf8), to: "Events/\(oldDate).jsonl")
        }
        var brokenJournal: URL?
        if !corruptWhileRunning {
            brokenJournal = try corruptHistory()
        }
        let server = try Self.tokenServer(now: now, phase: { phase.withLock { $0 } })
        defer { server.close() }
        var observed = 0
        var disconnected = false
        let lifecycle = SessionLifecycleCache()
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycle, socketURL: server.url, logStorage: nil,
            tokenHistory: store, recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .sourceUnavailable = batch {
                disconnected = true
            }
            if case let .live(events) = batch {
                observed += events.count
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where observed < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == 1)
        if corruptWhileRunning {
            brokenJournal = try corruptHistory()
        }
        phase.withLock { $0 = 1 }
        #expect(await reader.drainNow() == .completed)
        #expect(observed == 2)
        // 给周期缓存刷新一次触发机会, 失败不能使实时连接失效
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await reader.drainNow() == .completed)
        #expect(!disconnected)
        let states = await lifecycle.lifecycleStates(for: [.init(threadID: "healthy", turnID: "turn")])
        #expect(states.first?.readStatus == .complete)
        await #expect(throws: TokenCacheError.self) { try await store.refresh() }
        #expect(try String(contentsOf: directory.url.appendingPathComponent("Aggregates/tokens.json"), encoding: .utf8) == "broken cache")
        let observations = try Self.observations(in: directory.url)
        #expect(observations.map(\.sequence) == [1, 2])
        #expect(observations.map(\.current.totalTokens) == [120, 150])
        try FileManager.default.removeItem(at: #require(brokenJournal))
        let recovered = try await store.refresh()
        #expect(recovered.first?.usage?.totalTokens == 50)
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
                        for total in nextPhase == 1 ? [150] : [200, 250] {
                            try peer.send(Self.usage(total))
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
                        try peer.send(Self.usage(100))
                        try peer.send(Self.usage(120))
                        try peer.send(Self.tool(thread: "healthy", id: "first"))
                    }
                default: Issue.record("Unexpected request")
                }
            }
        }
    }

    private nonisolated static func observations(in directory: URL) throws -> [TokenObservation] {
        let url = HistoryStorage.eventLogURL(for: HistoryStorage.dateKey(for: Date()), in: directory.appendingPathComponent("Events"))
        var observations: [TokenObservation] = []
        try AppServerEventJournal.read(at: url) {
            if let observation = $0.observation {
                observations.append(observation)
            }
        }
        return observations
    }

    private nonisolated static func usage(_ total: Int) -> [String: Any] {
        let counts = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
        return ["method": "thread/tokenUsage/updated", "params": [
            "threadId": "healthy", "turnId": "turn", "tokenUsage": ["total": counts, "last": counts]
        ]]
    }
}

private extension TokenHistoryStore {
    func holdForReaderTest(entered: @Sendable () -> Void, release: DispatchSemaphore) {
        entered()
        _ = release.wait(timeout: .now() + 10)
    }
}

extension ActivityIsolationTests {
    @Test func fullObservationQueueResumesWithNewBaselineAfterStorageRecovery() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let blocker = try directory.write("blocked", to: "State")
        let phase = Mutex(0)
        let server = try Self.tokenServer(now: Date().addingTimeInterval(-60), phase: { phase.withLock { $0 } })
        defer { server.close() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        var observed = 0
        var disconnected = false
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url, logStorage: nil,
            tokenHistory: store, recorder: ActivityRecorder(directoryURL: directory.url), maximumPendingEvents: 1
        ) { batch in
            if case .sourceUnavailable = batch {
                disconnected = true
            }
            if case let .live(events) = batch {
                observed += events.count
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where observed < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observed == 1)
        phase.withLock { $0 = 1 }
        #expect(await reader.drainNow() == .completed)
        #expect(observed == 2)
        try FileManager.default.removeItem(at: blocker)
        for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: HistoryStorage.maintenanceURL(in: directory.url).path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await reader.drainNow() == .completed)
        phase.withLock { $0 = 2 }
        #expect(await reader.drainNow() == .completed)
        #expect(observed == 3)
        #expect(!disconnected)
        #expect(await reader.stop())
        let observations = try Self.observations(in: directory.url)
        #expect(observations.map(\.sequence) == [1, 1])
        #expect(Set(observations.map(\.streamID)).count == 2)
        let restored = try await store.refresh()
        #expect(restored.first?.usage?.totalTokens == 70)
        #expect(try await store.refresh() == restored)
        try server.finish()
    }
}
