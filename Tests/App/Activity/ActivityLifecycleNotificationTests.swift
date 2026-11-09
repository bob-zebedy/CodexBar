import Foundation
import Synchronization
import Testing

struct ActivityLifecycleNotificationTests {
    nonisolated static let methods = ["thread/closed", "thread/archived", "thread/deleted", "thread/reverted"]

    @Test(arguments: methods, [nil, "", "thread"] as [String?])
    func lifecycleIdentity(method: String, threadID: String?) throws {
        let params = threadID.map { ["threadId": $0] } ?? [:]
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        if threadID?.isEmpty == false {
            let input = try JSONDecoder().decode(ActivityInput.self, from: data)
            #expect(input.kind.isThreadLifecycleChange)
            #expect(input.params.turnId == nil)
        } else {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ActivityInput.self, from: data) }
        }
    }

    @Test(arguments: [false, true], ["before-publication", "after-publication", "unavailable-before-publication"])
    func retiredChildPreservesParentAndKnownUsage(removed: Bool, timing: String) throws {
        let now = Date()
        var reducer = AppServerActivityReducer()
        var graph = ActivityTaskGraph()
        let parent = ActivityThread(id: "parent", status: .init(type: .active), origin: .main)
        let child = ActivityThread(id: "child", status: .init(type: .active), origin: .auxiliary, parentThreadID: "parent")
        var events = reducer.reconcile(thread: parent, turns: [.init(id: "root", status: .running, rootTurnId: "root", startedAt: now)], now: now)
        events += reducer.reconcile(thread: child, turns: [.init(id: "child-turn", status: .running, rootTurnId: "root", startedAt: now)], now: now)
        reducer.applyTokenUsage(.init(threadID: "parent", position: 1, turns: ["root": TestFixtures.tokenUsage(100)]))
        reducer.applyTokenUsage(.init(threadID: "child", position: 2, turns: ["child-turn": TestFixtures.tokenUsage(50)]))
        let verified = Dictionary(uniqueKeysWithValues: reducer.states.keys.map { ($0, now) })
        if timing == "after-publication" {
            _ = graph.update(events: events, source: .live, lifecycle: .init(states: reducer.states, verifiedTurns: verified))
            events.removeAll()
        } else if timing == "unavailable-before-publication" {
            reducer.invalidateThread("child")
        }
        reducer.retireTurns(threadID: "child", removed: removed)
        reducer.retireTurns(threadID: "child", removed: false)
        #expect(reducer.states[.init(threadID: "child", turnID: "child-turn")]?.tracking == (removed ? .removed : .historyOnly))
        let snapshot = TurnLifecycleSnapshot(states: reducer.states, verifiedTurns: [.init(threadID: "parent", turnID: "root"): now])
        let transitions = graph.update(events: events, source: .live, lifecycle: snapshot)
        let task = try #require(graph.tasks[.init(thread: "parent", turn: "root")])
        #expect(task.tokenUsage?.totalTokens == 150)
        #expect(task.snapshot.activeSubagentCount == 0)
        #expect(task.state == .running)
        #expect(task.executions[.init(agentThreadID: "child", turnID: "child-turn")]?.isDetached == true)
        #expect(graph.unavailableTurns.isEmpty)
        #expect(transitions.isEmpty)
        #expect(graph.completions.isEmpty)
        #expect(graph.terminations.isEmpty)
        #expect(reducer.states[.init(threadID: "child", turnID: "child-turn")]?.terminal == nil)
    }

    @Test func retiredRootKeepsKnownChildUntilItRetires() throws {
        let now = Date()
        var reducer = AppServerActivityReducer()
        let events = reducer.reconcile(
            thread: .init(id: "parent", status: .init(type: .active), origin: .main),
            turns: [.init(id: "root", status: .running, rootTurnId: "root", startedAt: now)], now: now
        )
        _ = reducer.reconcile(
            thread: .init(id: "child", status: .init(type: .active), origin: .auxiliary, parentThreadID: "parent"),
            turns: [.init(id: "child-turn", status: .running, rootTurnId: "root", startedAt: now)], now: now
        )
        var graph = ActivityTaskGraph()
        let verified = Dictionary(uniqueKeysWithValues: reducer.states.keys.map { ($0, now) })
        _ = graph.update(events: events, source: .live, lifecycle: .init(states: reducer.states, verifiedTurns: verified))
        reducer.retireTurns(threadID: "parent", removed: false)
        _ = graph.update(events: [], source: .live, lifecycle: .init(states: reducer.states, verifiedTurns: verified))
        let task = try #require(graph.tasks[.init(thread: "parent", turn: "root")])
        #expect(task.snapshot.activeSubagentCount == 1)
        #expect(task.lifecycleCoverageCheckedAt == now)
        reducer.retireTurns(threadID: "child", removed: false)
        _ = graph.update(events: [], source: .live, lifecycle: .init(states: reducer.states, verifiedTurns: [:]))
        #expect(graph.tasks.isEmpty)
        #expect(graph.unavailableTurns.isEmpty)
    }

    @Test func removingOldTurnPreservesCurrentApprovalStart() throws {
        let now = Date()
        var reducer = AppServerActivityReducer()
        _ = reducer.reconcile(
            thread: .init(id: "main", status: .init(type: .active, activeFlags: [.waitingOnApproval]), origin: .main),
            turns: [
                .init(id: "old", status: .completed, rootTurnId: "old", completedAt: now.addingTimeInterval(-5)),
                .init(id: "current", status: .running, rootTurnId: "current", startedAt: now)
            ], now: now
        )
        reducer.retireTurns(threadID: "main", turnIDs: ["old"], removed: true)
        let request = try TestFixtures.decode(ActivityInput.self, """
        {"id":1,"method":"item/commandExecution/requestApproval","params":{
        "threadId":"main","turnId":"current","itemId":"tool","startedAtMs":\(now.addingTimeInterval(10).timeIntervalSince1970 * 1000)}}
        """)
        _ = reducer.consume(request, now: now.addingTimeInterval(10))
        let current = try #require(reducer.states[.init(threadID: "main", turnID: "current")])
        #expect(current.tracking == .live)
        #expect(current.pendingApprovals.count == 1)
        #expect(current.approvalChangedAt == now)
    }

    @MainActor
    @Test(.tags(.integration), arguments: methods, [false, true])
    func notificationDuringReadCannotRestoreOldTask(method: String, duringPagination: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let phase = Mutex(0)
        let reads = Mutex<[String: Int]>([:])
        let timestamp = Date().addingTimeInterval(30).timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            while let request = try? peer.readMessage() {
                let params = request["params"] as? [String: Any] ?? [:]
                let id = params["threadId"] as? String ?? ""
                let current = phase.withLock { $0 }
                switch request["method"] as? String {
                case "thread/loaded/list":
                    let loaded = current < 2 || current == 3 || method == "thread/reverted" ? ["main", "other"] : ["other"]
                    try peer.reply(to: request, result: ["data": loaded])
                case "thread/read", "thread/resume":
                    reads.withLock { $0[id, default: 0] += 1 }
                    try peer.reply(to: request, result: ["thread": Self.thread(id)])
                case "thread/turns/list":
                    if id == "main", current == 1, duringPagination, params["cursor"] == nil {
                        try peer.reply(to: request, result: ["data": [], "nextCursor": "older"])
                        continue
                    }
                    if id == "main", current == 1 {
                        phase.withLock { $0 = 2 }
                        try peer.send(["method": method, "params": ["threadId": id]])
                    }
                    let turn = current >= 2 && id == "main" ? "replacement" : "turn"
                    var result: [String: Any] = ["data": [Self.turn(turn, timestamp: timestamp)]]
                    if id == "main", current == 1, duringPagination {
                        result["nextCursor"] = "older"
                    }
                    try peer.reply(to: request, result: result)
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let probe = ActivityReaderProbe()
        var ready = false
        let reader = AppServerActivityReader(
            probe: probe, socketURL: server.url, logStorage: nil, tokenUsageHistory: .init(directoryURL: directory.url),
            activityDataRecorder: .init(directoryURL: directory.url)
        ) {
            if $0.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        defer { _ = await reader.stop() }
        for _ in 0 ..< 300 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        #expect(probe.graph.tasks[.init(thread: "main", turn: "turn")] != nil)
        phase.withLock { $0 = 1 }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .partial)
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(probe.graph.tasks[.init(thread: "main", turn: "turn")] == nil)
        #expect(probe.graph.tasks[.init(thread: "other", turn: "turn")] != nil)
        #expect((probe.graph.tasks[.init(thread: "main", turn: "replacement")] != nil) == (method == "thread/reverted"))
        #expect(probe.graph.completions.isEmpty)
        #expect(probe.graph.terminations.isEmpty)
        #expect(probe.graph.unavailableTurns.isEmpty)
        let before = reads.withLock { $0["main"] }
        _ = await reader.drainForRecovery(generation: UUID())
        if method != "thread/reverted" {
            #expect(reads.withLock { $0["main"] } == before)
        }
        if method == "thread/closed" || method == "thread/archived" {
            phase.withLock { $0 = 3 }
            #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
            #expect(probe.graph.tasks[.init(thread: "main", turn: "replacement")] != nil)
        }
        #expect(await reader.stop())
        try server.finish()
    }

    @MainActor
    @Test(.tags(.integration))
    func deletionDuringDiscoveryDoesNotResumeUnknownThread() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let requests = Mutex<[String]>([])
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            var first = true
            while let request = try? peer.readMessage() {
                let method = try #require(request["method"] as? String)
                requests.withLock { $0.append(method) }
                #expect(method == "thread/loaded/list")
                if first {
                    try peer.send(["method": "thread/deleted", "params": ["threadId": "gone"]])
                }
                try peer.reply(to: request, result: ["data": first ? ["gone"] : []])
                first = false
            }
        }
        defer { server.close() }
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil, tokenUsageHistory: .init(directoryURL: directory.url),
            activityDataRecorder: .init(directoryURL: directory.url), onBatch: { _ in }
        )
        await reader.start()
        defer { _ = await reader.stop() }
        for _ in 0 ..< 300 where requests.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(requests.withLock { $0.allSatisfy { $0 == "thread/loaded/list" } })
        #expect(await reader.stop())
        try server.finish()
    }

    @MainActor
    @Test(.tags(.integration), arguments: methods)
    func inFlightHistorySurvivesOnlyNonDestructiveChanges(method: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let phase = Mutex(0)
        let readingItems = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture(connections: 2, concurrentConnections: true) { peer in
            try Self.initialize(peer)
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/items/list":
                    readingItems.withLock { $0 = true }
                    #expect(release.wait(timeout: .now() + 5) == .success)
                    try peer.reply(to: request, result: ["data": [[
                        "turnId": "turn", "startedAtMs": timestamp * 1000,
                        "item": ["id": "history-tool", "type": "commandExecution"]
                    ]]])
                    return
                case "thread/loaded/list":
                    let current = phase.withLock { value in
                        let previous = value
                        if value == 1 {
                            value = 2
                        }
                        return previous
                    }
                    if current == 1 {
                        try peer.send(["method": method, "params": ["threadId": "main"]])
                    }
                    try peer.reply(to: request, result: ["data": current == 0 || method == "thread/reverted" ? ["main"] : []])
                case "thread/read", "thread/resume":
                    try peer.reply(to: request, result: ["thread": Self.thread("main", loaded: phase.withLock { $0 == 0 } || method == "thread/reverted")])
                case "thread/turns/list":
                    let turns = phase.withLock { $0 >= 2 } && method == "thread/reverted" ? [] : [Self.turn("turn", timestamp: timestamp)]
                    try peer.reply(to: request, result: ["data": turns])
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil, tokenUsageHistory: .init(directoryURL: directory.url),
            activityDataRecorder: .init(directoryURL: directory.url), onBatch: { _ in }
        )
        await reader.start()
        defer { _ = await reader.stop() }
        for _ in 0 ..< 300 where !readingItems.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(readingItems.withLock { $0 })
        phase.withLock { $0 = 1 }
        _ = await reader.drainForRecovery(generation: UUID())
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        release.signal()
        let preservesHistory = method == "thread/closed" || method == "thread/archived"
        for _ in 0 ..< (preservesHistory ? 300 : 30) {
            if preservesHistory, try directory.historyRecords().contains(where: { $0.context?.method == "thread/items/list" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await reader.stop())
        let records = try directory.historyRecords().filter { $0.context?.method == "thread/items/list" }
        #expect(!records.isEmpty == preservesHistory)
        try server.finish()
    }

    @MainActor
    @Test(.tags(.integration))
    func deletionWhilePreparingPreservesQueuedUsageAndRealCompletion() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let sent = Mutex(false)
        let timestamp = Date().timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/loaded/list":
                    try peer.reply(to: request, result: ["data": sent.withLock { $0 } ? [] : ["main"]])
                case "thread/read":
                    var turn = Self.turn("turn", timestamp: timestamp)
                    try peer.send(["method": "turn/started", "params": ["threadId": "main", "turn": turn]])
                    for total in [10, 25] {
                        let usage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
                        try peer.send(["method": "thread/tokenUsage/updated", "params": [
                            "threadId": "main", "turnId": "turn", "tokenUsage": ["total": usage, "last": usage]
                        ]])
                    }
                    turn["status"] = "completed"
                    turn["completedAt"] = timestamp + 1
                    try peer.send(["method": "turn/completed", "params": ["threadId": "main", "turn": turn]])
                    try peer.send(["method": "thread/deleted", "params": ["threadId": "main"]])
                    sent.withLock { $0 = true }
                    try peer.reply(to: request, result: ["thread": Self.thread("main")])
                default: Issue.record("Deleted thread must not be resumed or paged")
                }
            }
        }
        defer { server.close() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let probe = ActivityReaderProbe()
        var ready = false
        let reader = AppServerActivityReader(
            probe: probe, socketURL: server.url, tokenUsageHistory: store, activityDataRecorder: .init(directoryURL: directory.url)
        ) {
            if $0.phase == .bootstrapEnd {
                ready = true
            }
        }
        await reader.start()
        defer { _ = await reader.stop() }
        for _ in 0 ..< 300 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        #expect(await reader.drainForRecovery(generation: UUID()).status == .completed)
        #expect(probe.graph.tasks.isEmpty)
        #expect(probe.graph.completions.count == 1)
        #expect(await reader.stop())
        #expect(try await store.refresh().reduce(0) { $0 + $1.tokenUsage.totalTokens } == 15)
        #expect(try directory.historyRecords().contains(where: { $0.activityData?.eventKind == .turnCompleted }))
        try server.finish()
    }

    private nonisolated static func initialize(_ peer: SharedServerFixture.Peer) throws {
        let request = try peer.readMessage()
        #expect(request["method"] as? String == "initialize")
        try peer.reply(to: request, result: ["userAgent": "codex/0.167.0", "platformFamily": "unix", "platformOs": "macos"])
        #expect(try peer.readMessage()["method"] as? String == "initialized")
    }

    private nonisolated static func thread(_ id: String, loaded: Bool = true) -> [String: Any] {
        ["id": id, "source": "cli", "status": ["type": loaded ? "active" : "notLoaded"]]
    }

    private nonisolated static func turn(_ id: String, timestamp: Double) -> [String: Any] {
        ["id": id, "status": "inProgress", "rootTurnId": id, "startedAt": timestamp]
    }
}
