import Foundation
import Synchronization
import Testing

struct ActivityBackfillTests {
    nonisolated enum BackfillOutcome: CaseIterable { case complete, stop, invalidResponse, liveCreation }

    @Test(arguments: [false, true])
    func shrinksSameCursorAndStopsAtOversizedItem(singleItemTooLarge: Bool) async throws {
        let attempts = Mutex<[Int]>([])
        let server = try SharedServerFixture(connections: singleItemTooLarge ? 5 : 4) { peer in
            try Self.initialize(peer)
            let request = try peer.readMessage()
            let params = try #require(request["params"] as? [String: Any])
            #expect(request["method"] as? String == "thread/items/list")
            #expect(params["threadId"] as? String == "parent")
            #expect(params["turnId"] as? String == "root")
            #expect(params["sortDirection"] as? String == "desc")
            #expect(params["cursor"] as? String == "same-cursor")
            let limit = try #require(params["limit"] as? Int)
            attempts.withLock { $0.append(limit) }
            if limit > 2 || singleItemTooLarge {
                try peer.sendHeader(length: 4097)
            } else {
                try peer.reply(to: request, result: ["data": [["turnId": "root", "item": ["id": "tool", "type": "commandExecution"]]], "nextCursor": "next-page"])
            }
        }
        defer { server.close() }
        let backfill = AppServerActivityBackfill(socketURL: server.url, logStorage: nil, maximumMessageSize: 4096)
        do {
            let page = try await backfill.readPage(reference: .init(threadID: "parent", turnID: "root"), cursor: "same-cursor", limit: 20, timeout: 3)
            #expect(!singleItemTooLarge)
            #expect(page.nextCursor == "next-page")
            #expect(page.limit == 2)
            #expect(page.items.first?.item.id == "tool")
        } catch let error as CodexStatusError {
            #expect(singleItemTooLarge)
            guard case .messageTooLarge = error else { Issue.record("Wrong error: \(error)")
                return
            }
        }
        #expect(attempts.withLock { $0 } == (singleItemTooLarge ? [20, 10, 5, 2, 1] : [20, 10, 5, 2]))
        try server.finish()
    }

    @Test func shrinkingRetriesShareOneDeadline() async throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let requests = Mutex(0)
        let server = try SharedServerFixture(connections: 2) { peer in
            try Self.initialize(peer)
            _ = try peer.readMessage()
            let attempt = requests.withLock { $0 += 1
                return $0
            }
            if attempt == 1 {
                Thread.sleep(forTimeInterval: 0.15)
                try peer.sendHeader(length: 4097)
            } else {
                _ = release.wait(timeout: .now() + 2)
            }
        }
        defer { server.close() }
        let backfill = AppServerActivityBackfill(socketURL: server.url, logStorage: nil, maximumMessageSize: 4096)
        let started = Date()
        do {
            _ = try await backfill.readPage(reference: .init(threadID: "parent", turnID: "root"), cursor: nil, limit: 20, timeout: 0.3)
            Issue.record("Expected shared deadline")
        } catch let error as CodexStatusError {
            guard case .serverTimeout = error else {
                Issue.record("Wrong error: \(error)")
                return
            }
        }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(requests.withLock { $0 } == 2)
        release.signal()
        try server.finish()
    }

    @Test(arguments: BackfillOutcome.allCases)
    func slowItemResponseDoesNotBlockLiveCollectionOrDrain(outcome: BackfillOutcome) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let itemsStarted = DispatchSemaphore(value: 0)
        let releaseItems = DispatchSemaphore(value: 0)
        defer { itemsStarted.signal()
            releaseItems.signal()
        }
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture(connections: outcome == .stop ? 2 : 3, concurrentConnections: true) { peer in
            try Self.serveLiveDuringBackfill(peer, itemsStarted: itemsStarted, releaseItems: releaseItems, timestamp: timestamp, outcome: outcome)
        }
        defer { server.close() }
        let store = TokenUsageHistoryStore(directoryURL: directory.url)
        let logs = AppServerLogStore(directoryURL: directory.url.appendingPathComponent("Logs"))
        defer { await #expect(throws: Never.self) { try await logs.close() } }
        let probe = ActivityReaderProbe()
        var ready = false
        var updates = 0
        var unavailable = false
        let reader = AppServerActivityReader(
            probe: probe, socketURL: server.url, logStorage: logs, tokenUsageHistory: store, activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            updates += 1
            if $0.phase == .bootstrapEnd {
                ready = true
            }
            if $0.phase == .sourceUnavailable {
                unavailable = true
            }
        }
        await reader.start()
        let key = ActivityTaskKey(thread: "parent", turn: "root-turn")
        for _ in 0 ..< 300 {
            if ready, probe.graph.tasks[key]?.tokenUsage?.totalTokens == 50 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready)
        #expect(probe.graph.tasks[key]?.tokenUsage?.totalTokens == 50)
        #expect(await reader.drainNow().status == .completed)
        #expect(!unavailable)
        #expect(probe.graph.tasks[key]?.state == .running)
        let progress = probe.graph.tasks[key]?.progressGeneration
        let references = [ActivityTurnReference(threadID: "child", turnID: "child-turn")]
        let before = await reader.lifecycleSnapshot.lifecycleStates(for: references).first
        #expect(before?.effort == "high")
        if outcome == .stop {
            await reader.stop()
            let stoppedUpdates = updates
            releaseItems.signal()
            try await Task.sleep(for: .milliseconds(200))
            #expect(updates == stoppedUpdates)
        } else {
            let beforeBackfillUpdates = updates
            releaseItems.signal()
            if outcome == .invalidResponse {
                try await Self.waitForBackfillFailure(logs)
            } else {
                for _ in 0 ..< 200 {
                    if updates > beforeBackfillUpdates {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(updates > beforeBackfillUpdates)
            }
            let after = await reader.lifecycleSnapshot.lifecycleStates(for: references).first
            #expect(after?.effort == (outcome == .complete ? "mixed" : "high"))
            #expect(after?.verifiedAt == before?.verifiedAt)
            #expect(probe.graph.tasks[key]?.progressGeneration == progress)
            #expect(probe.graph.tasks[key]?.state == .running)
            #expect(probe.graph.tasks[key]?.tokenUsage?.totalTokens == 50)
            #expect(await reader.drainNow().status == .completed)
            #expect(!unavailable)
            try await Self.waitForItemReads(logs, count: 2)
            await reader.stop()
        }
        #expect(try await store.refresh().first?.tokenUsage.totalTokens == 50)
        try server.finish()
    }

    private static func waitForItemReads(_ logs: AppServerLogStore, count: Int) async throws {
        for _ in 0 ..< 200 {
            let successes = try await logs.page().entries.filter { $0.method == "thread/items/list" && $0.status == .success }.count
            if successes >= count {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Item pages did not finish")
    }

    private static func waitForBackfillFailure(_ logs: AppServerLogStore) async throws {
        for _ in 0 ..< 200 {
            if try await logs.page().entries.contains(where: { $0.method == "activity/backfill" && $0.status == .failure }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await logs.page().entries.contains { $0.method == "activity/backfill" && $0.status == .failure })
    }

    private nonisolated static func serveLiveDuringBackfill(
        _ peer: SharedServerFixture.Peer, itemsStarted: DispatchSemaphore, releaseItems: DispatchSemaphore, timestamp: Double, outcome: BackfillOutcome
    ) throws {
        let name = try Self.initialize(peer)
        if name == "codex_bar_activity_backfill" {
            let request = try peer.readMessage()
            let params = try #require(request["params"] as? [String: Any])
            #expect(request["method"] as? String == "thread/items/list")
            if params["threadId"] as? String == "child" {
                try peer.reply(to: request, result: ["data": []])
                return
            }
            var body = try JSONSerialization.data(withJSONObject: ["id": #require(request["id"]), "result": ["data": [[
                "turnId": "root-turn", "startedAtMs": timestamp * 1000, "completedAtMs": (timestamp + 1) * 1000,
                "item": [
                    "id": "spawn",
                    "type": "subAgentActivity",
                    "kind": "started",
                    "agentThreadId": "child",
                    "reasoningEffort": "low",
                    "ignoredOutput": String(repeating: "a", count: 200000)
                ]
            ]]]])
            if outcome == .invalidResponse {
                body = try JSONSerialization.data(withJSONObject: ["id": #require(request["id"]), "result": ["data": "invalid", "padding": String(repeating: "a", count: 200000)]])
            }
            try peer.sendHeader(length: UInt64(body.count))
            try peer.sendBytes(body.prefix(100))
            itemsStarted.signal()
            #expect(releaseItems.wait(timeout: .now() + 5) == .success)
            if outcome == .stop {
                try? peer.sendBytes(body.dropFirst(100))
            } else {
                try peer.sendBytes(body.dropFirst(100))
            }
            return
        }
        var sent = false
        while let request = try? peer.readMessage() {
            let params = request["params"] as? [String: Any] ?? [:]
            let id = params["threadId"] as? String ?? ""
            switch request["method"] as? String {
            case "thread/loaded/list":
                try peer.reply(to: request, result: ["data": ["parent", "child"]])
            case "thread/read", "thread/resume":
                var thread: [String: Any] = ["id": id, "source": "cli", "status": ["type": "active"], "reasoningEffort": "high"]
                if id == "child" {
                    thread["parentThreadId"] = "parent"
                }
                try peer.reply(to: request, result: ["thread": thread])
            case "thread/turns/list":
                #expect(params["itemsView"] as? String == "notLoaded")
                try peer.reply(to: request, result: ["data": [[
                    "id": id == "parent" ? "root-turn" : "child-turn", "rootTurnId": "root-turn", "status": "inProgress", "startedAt": timestamp
                ]]])
                if id == "parent", !sent {
                    sent = true
                    #expect(itemsStarted.wait(timeout: .now() + 3) == .success)
                    try Self.sendLiveUpdates(peer, timestamp: timestamp)
                    if outcome == .liveCreation {
                        try peer.send(["method": "item/completed", "params": ["threadId": "parent", "turnId": "root-turn", "item": [
                            "id": "live-spawn", "type": "subAgentActivity", "kind": "started", "agentThreadId": "child", "reasoningEffort": "high"
                        ]]])
                    }
                }
            default: Issue.record("Unexpected request")
            }
        }
    }

    @discardableResult
    private nonisolated static func initialize(_ peer: SharedServerFixture.Peer) throws -> String? {
        let request = try peer.readMessage()
        #expect(request["method"] as? String == "initialize")
        let client = (request["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        try peer.reply(to: request, result: ["userAgent": "codex/0.162.0"])
        #expect(try peer.readMessage()["method"] as? String == "initialized")
        return client?["name"] as? String
    }

    private nonisolated static func sendLiveUpdates(_ peer: SharedServerFixture.Peer, timestamp: Double) throws {
        for index in 0 ..< 30 {
            try peer.send(["method": "item/started", "params": [
                "threadId": "parent", "turnId": "root-turn", "item": ["id": "tool-\(index)", "type": "commandExecution"]
            ]])
        }
        try peer.send(["id": "approval", "method": "item/commandExecution/requestApproval", "params": [
            "threadId": "parent", "turnId": "root-turn", "itemId": "approval-tool", "startedAtMs": (timestamp + 10) * 1000
        ]])
        try peer.send(["method": "serverRequest/resolved", "params": ["threadId": "parent", "requestId": "approval"]])
        try peer.send(["method": "thread/status/changed", "params": ["threadId": "parent", "status": ["type": "active", "activeFlags": []]]])
        for total in [100, 120, 150] {
            let usage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
            try peer.send(["method": "thread/tokenUsage/updated", "params": [
                "threadId": "parent", "turnId": "root-turn", "tokenUsage": ["total": usage, "last": usage]
            ]])
        }
    }
}

extension ActivityBackfillTests {
    @Test func newSubagentDoesNotRestartCurrentHistoryScan() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let firstPage = DispatchSemaphore(value: 0)
        let releasePage = DispatchSemaphore(value: 0)
        defer { firstPage.signal()
            releasePage.signal()
        }
        let cursors = Mutex<[String?]>([])
        let queriedThreads = Mutex<Set<String>>([])
        let timestamp = Date().addingTimeInterval(-60).timeIntervalSince1970
        let server = try SharedServerFixture(connections: 4, concurrentConnections: true) { peer in
            if try Self.initialize(peer) == "codex_bar_activity_backfill" {
                let request = try peer.readMessage()
                let params = try #require(request["params"] as? [String: Any])
                let threadID = try #require(params["threadId"] as? String)
                _ = queriedThreads.withLock { $0.insert(threadID) }
                if params["threadId"] as? String == "child" {
                    try peer.reply(to: request, result: ["data": []])
                    return
                }
                let cursor = params["cursor"] as? String
                let index = cursors.withLock { $0.append(cursor)
                    return $0.count
                }
                if index == 1 {
                    firstPage.signal()
                    #expect(releasePage.wait(timeout: .now() + 3) == .success)
                    try peer.reply(to: request, result: ["data": [], "nextCursor": "older"])
                } else {
                    let items = ["child", "new-child"].map { child in
                        ["turnId": "root", "item": [
                            "id": "spawn-" + child,
                            "type": "subAgentActivity",
                            "kind": "started",
                            "agentThreadId": child,
                            "reasoningEffort": "low"
                        ]] as [String: Any]
                    }
                    try peer.reply(to: request, result: ["data": items])
                }
            } else {
                try Self.serveNewSubagent(peer, timestamp: timestamp, firstPage: firstPage)
            }
        }
        defer { server.close() }
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil, tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url), onBatch: { _ in }
        )
        await reader.start()
        let references = [ActivityTurnReference(threadID: "new-child", turnID: "new-child-turn"), .init(threadID: "child", turnID: "child-turn")]
        for _ in 0 ..< 200 {
            if await reader.lifecycleSnapshot.lifecycleStates(for: references).contains(where: { $0.requestedThreadID == "new-child" && $0.startedAt != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await reader.lifecycleSnapshot.lifecycleStates(for: references).contains { $0.requestedThreadID == "new-child" && $0.startedAt != nil })
        releasePage.signal()
        for _ in 0 ..< 200 {
            if await reader.lifecycleSnapshot.lifecycleStates(for: references).allSatisfy({ $0.effort == "low" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await reader.lifecycleSnapshot.lifecycleStates(for: references).allSatisfy { $0.effort == "low" })
        #expect(cursors.withLock { $0 } == [nil, "older"])
        await reader.stop()
        try server.finish()
        #expect(queriedThreads.withLock { $0 } == ["parent", "child"])
    }

    private nonisolated static func serveNewSubagent(_ peer: SharedServerFixture.Peer, timestamp: Double, firstPage: DispatchSemaphore) throws {
        var sent = false
        while let request = try? peer.readMessage() {
            let id = (request["params"] as? [String: Any])?["threadId"] as? String ?? ""
            switch request["method"] as? String {
            case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["parent", "child"]])
            case "thread/read", "thread/resume":
                var thread: [String: Any] = ["id": id, "source": "cli", "status": ["type": "active"]]
                if id != "parent" {
                    thread["parentThreadId"] = "parent"
                }
                try peer.reply(to: request, result: ["thread": thread])
            case "thread/turns/list":
                try peer.reply(to: request, result: ["data": [[
                    "id": id == "parent" ? "root" : id + "-turn", "rootTurnId": "root", "status": "inProgress", "startedAt": timestamp
                ]]])
                if id == "parent", !sent {
                    sent = true
                    #expect(firstPage.wait(timeout: .now() + 3) == .success)
                    try peer.send(["method": "thread/started", "params": ["thread": [
                        "id": "new-child", "parentThreadId": "parent", "source": "cli", "status": ["type": "active"]
                    ]]])
                    try peer.send(["method": "turn/started", "params": ["threadId": "new-child", "turn": [
                        "id": "new-child-turn", "rootTurnId": "root", "status": "inProgress", "startedAt": Date().timeIntervalSince1970
                    ]]])
                }
            default: Issue.record("Unexpected request")
            }
        }
    }
}

extension ActivityBackfillTests {
    @Test(arguments: [false, true])
    func historyAndLiveActivityShareIdentityWithoutReplayingState(historyFirst: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let reference = ActivityTurnReference(threadID: "main", turnID: "root")
        var reducer = AppServerActivityReducer()
        _ = reducer.reconcile(
            thread: .init(id: "main", status: .init(type: .active), origin: .main),
            turns: [.init(id: "root", status: .running, rootTurnId: "root", startedAt: now.addingTimeInterval(-60))],
            now: now
        )
        let started = try TestFixtures.decode(ActivityInput.self, """
        {"method":"item/started","params":{"threadId":"main","turnId":"root","item":{"id":"tool","type":"commandExecution","commandActions":[
        {"type":"search"},{"type":"read"},{"type":"read"}]}}}
        """)
        let live = reducer.consume(started, now: now)
        let before = try #require(reducer.states[reference])
        let entry = ActivityItemEntry(
            turnId: "root",
            item: ActivityItem(
                id: "tool",
                type: .commandExecution,
                status: "completed",
                commandActions: [.init(type: "search"), .init(type: "read"), .init(type: "read")]
            ),
            startedAtMs: now.addingTimeInterval(-30).timeIntervalSince1970 * 1000,
            completedAtMs: now.addingTimeInterval(-20).timeIntervalSince1970 * 1000
        )
        let history = reducer.historicalEvents([entry], reference: reference, now: now.addingTimeInterval(10))
        #expect(history.first?.id == live.first?.id)
        #expect(reducer.states[reference]?.lastProgressAt == before.lastProgressAt)
        #expect(reducer.states[reference]?.isWaitingApproval == before.isWaitingApproval)
        #expect(reducer.states[reference]?.terminal == nil)
        let recorder = ActivityDataRecorder(directoryURL: directory.url)
        try await recorder.record(events: historyFirst ? history : live)
        try await recorder.record(events: historyFirst ? live : history)
        try await ActivityDataRecorder(directoryURL: directory.url).record(events: history)
        let database = try HistoryDatabase(directoryURL: directory.url)
        let aggregate = try database.aggregateActivityData(date: HistoryStorage.dateKey(for: now))
        #expect(aggregate.toolStartedCount == 3)
        #expect(aggregate.toolCompletedCount == 3)
        #expect(aggregate.eventCount == 2)
        #expect(aggregate.approvalRequestedCount == 0)
    }

    @Test func consecutiveReaderRestartsDeduplicateActivityAndContinueTokenBaseline() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let start = Date().addingTimeInterval(-3600)
        let initial = TokenUsageHistoryStore(directoryURL: directory.url)
        _ = try await initial.record(TestFixtures.tokenSample(100, at: start, start: start))
        _ = try await initial.record(TestFixtures.tokenSample(150, at: start, start: start))
        for (count, total) in [(2, 200), (3, 300)] {
            let server = try SharedServerFixture(connections: 2, concurrentConnections: true) { peer in
                let client = try Self.initialize(peer)
                if client == "codex_bar_activity_backfill" {
                    let request = try peer.readMessage()
                    #expect(request["method"] as? String == "thread/items/list")
                    let entries = (1 ... count).map { index in
                        [
                            "turnId": "root",
                            "startedAtMs": start.timeIntervalSince1970 * 1000,
                            "item": ["id": "tool-\(index)", "type": "commandExecution", "status": "inProgress"]
                        ] as [String: Any]
                    }
                    try peer.reply(to: request, result: ["data": entries])
                    return
                }
                var emitted = false
                while let request = try? peer.readMessage() {
                    switch request["method"] as? String {
                    case "thread/loaded/list": try peer.reply(to: request, result: ["data": ["main"]])
                    case "thread/read", "thread/resume":
                        try peer.reply(to: request, result: ["thread": ["id": "main", "source": "cli", "status": ["type": "active"]]])
                    case "thread/turns/list":
                        #expect((request["params"] as? [String: Any])?["itemsView"] as? String == "notLoaded")
                        try peer.reply(to: request, result: ["data": [["id": "root", "rootTurnId": "root", "status": "inProgress", "startedAt": start.timeIntervalSince1970]]])
                        if !emitted {
                            emitted = true
                            let usage = ["inputTokens": total, "cachedInputTokens": 0, "outputTokens": 0, "reasoningOutputTokens": 0, "totalTokens": total]
                            try peer.send(["method": "thread/tokenUsage/updated", "params": ["threadId": "main", "turnId": "root", "tokenUsage": ["total": usage, "last": usage]]])
                            try peer.send(["method": "item/started", "params": ["threadId": "main", "turnId": "root", "item": ["id": "tool-\(count)", "type": "commandExecution"]]])
                        }
                    default: Issue.record("Unexpected request")
                    }
                }
            }
            defer { server.close() }
            let probe = ActivityReaderProbe()
            let store = TokenUsageHistoryStore(directoryURL: directory.url)
            let reader = AppServerActivityReader(
                probe: probe,
                socketURL: server.url,
                logStorage: nil,
                tokenUsageHistory: store,
                activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
                onBatch: { _ in }
            )
            await reader.start()
            for _ in 0 ..< 300 {
                let tools = try directory.historyRecords().filter { $0.activityData?.eventKind == .toolStarted }.count
                if tools == count, probe.graph.tasks[.init(thread: "main", turn: "root")]?.tokenUsage?.totalTokens == Int64(total - 100) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(probe.graph.tasks[.init(thread: "main", turn: "root")]?.tokenUsage?.totalTokens == Int64(total - 100))
            #expect(await reader.stop())
            let database = try HistoryDatabase(directoryURL: directory.url)
            let aggregate = try database.aggregateActivityData(date: HistoryStorage.dateKey(for: start))
            #expect(aggregate.toolStartedCount == count)
            #expect(aggregate.turnStartedCount == 1)
            #expect(try await store.refresh().first?.tokenUsage.totalTokens == Int64(total - 100))
            try server.finish()
        }
    }
}

extension ActivityBackfillTests {
    @Test func taskStartedWhileReaderIsConnectedDoesNotQueryHistory() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let logs = AppServerLogStore(directoryURL: directory.url.appendingPathComponent("Logs"))
        defer { await #expect(throws: Never.self) { try await logs.close() } }
        let startTask = Mutex(false)
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            var startedAt: Double?
            while let request = try? peer.readMessage() {
                switch request["method"] as? String {
                case "thread/loaded/list":
                    if startTask.withLock({ $0 }), startedAt == nil {
                        let timestamp = Date().timeIntervalSince1970
                        startedAt = timestamp
                        try peer.send(["method": "thread/started", "params": ["thread": ["id": "main", "source": "cli", "status": ["type": "active"]]]])
                        try peer.send(["method": "turn/started", "params": ["threadId": "main", "turn": [
                            "id": "root", "rootTurnId": "root", "status": "inProgress", "startedAt": timestamp
                        ]]])
                    }
                    try peer.reply(to: request, result: ["data": startedAt == nil ? [] : ["main"]])
                case "thread/read", "thread/resume":
                    try peer.reply(to: request, result: ["thread": ["id": "main", "source": "cli", "status": ["type": "active"]]])
                case "thread/turns/list":
                    #expect((request["params"] as? [String: Any])?["itemsView"] as? String == "notLoaded")
                    try peer.reply(to: request, result: ["data": [[
                        "id": "root", "rootTurnId": "root", "status": "inProgress", "startedAt": #require(startedAt)
                    ]]])
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        var ready = false
        let probe = ActivityReaderProbe()
        let reader = AppServerActivityReader(
            probe: probe,
            socketURL: server.url,
            logStorage: logs,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
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
        startTask.withLock { $0 = true }
        #expect(await reader.drainNow().status == .completed)
        #expect(probe.graph.tasks[.init(thread: "main", turn: "root")]?.state == .running)
        #expect(await reader.stop())
        #expect(try await !logs.page().entries.contains { $0.method == "thread/items/list" })
        #expect(try directory.historyRecords().allSatisfy { $0.context?.method != "thread/items/list" })
        try server.finish()
    }

    @Test(arguments: [false, true])
    func invalidHistoryCursorOrTurnFailsWithoutAcceptingPage(wrongTurn: Bool) async throws {
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            let request = try peer.readMessage()
            try peer.reply(to: request, result: [
                "data": [["turnId": wrongTurn ? "other" : "root", "item": ["id": "item", "type": "commandExecution"]]],
                "nextCursor": wrongTurn ? "next" : "cursor"
            ])
        }
        defer { server.close() }
        let backfill = AppServerActivityBackfill(socketURL: server.url, logStorage: nil)
        await #expect(throws: CodexStatusError.self) {
            try await backfill.readPage(reference: .init(threadID: "main", turnID: "root"), cursor: "cursor", limit: 20, timeout: 3)
        }
        try server.finish()
    }
}
