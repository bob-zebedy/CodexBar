import Foundation
import Testing

struct AppServerActivityTests {
    private let now = TestFixtures.now

    private func thread(_ id: String = "main", source: String = #""cli""#) throws -> ActivityThread {
        try TestFixtures.decode(ActivityThread.self, """
        {"id":"\(id)","cwd":"/test","model":"gpt-5","reasoningEffort":"high","createdAt":\(now.timeIntervalSince1970),
        "status":{"type":"active","activeFlags":[]},"source":\(source)}
        """)
    }

    private func turn(_ id: String = "turn", status: String = "inProgress") -> ActivityTurn {
        ActivityTurn(id: id, status: status, startedAt: now.timeIntervalSince1970)
    }

    private func message(_ method: String, params: String, id: Int? = nil) throws -> ActivityNotification {
        let request = id.map { "\"id\":\($0)," } ?? ""
        return try TestFixtures.decode(ActivityNotification.self, "{\(request)\"method\":\"\(method)\",\"params\":\(params)}")
    }

    private func prepared() throws -> AppServerActivityReducer {
        var reducer = AppServerActivityReducer()
        _ = try reducer.reconcile(thread: thread(), turns: [turn()], reviewer: .user, now: now)
        return reducer
    }

    @Test(arguments: [
        "item/agentMessage/delta", "item/plan/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta",
        "item/commandExecution/outputDelta", "item/fileChange/outputDelta"
    ])
    func recognizedProgressOnlyRefreshesActivity(_ method: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/commandExecution/requestApproval", params: """
        {"threadId":"main","turnId":"turn","itemId":"command"}
        """, id: 1), now: now)
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        _ = try reducer.consume(tokenMessage(total: 110), now: now)
        let tokens = reducer.tokenTurns
        let later = now.addingTimeInterval(30)
        let events = try reducer.consume(message(method, params: """
        {"threadId":"main","turnId":"turn","itemId":"item","delta":"content"}
        """), now: later)
        let state = try #require(reducer.states.values.first)
        #expect(state.lastProgressAt == later)
        #expect(state.lastExecutionProgressAt == later)
        #expect(state.isWaitingApproval == true)
        #expect(state.approvalChangedAt == now)
        #expect(events.isEmpty)
        #expect(reducer.tokenTurns == tokens)
        #expect(state.tokenUsage?.totalTokens == 10)
    }

    @Test(arguments: [
        "item/future/delta", "item/future/outputDelta", "hook/delta", "command/exec/outputDelta",
        "process/outputDelta", "item/reasoning/textDelta/extra", "item/agentMessage/Delta"
    ])
    func unknownMethodsCannotRefreshActivity(_ method: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message(method, params: """
        {"threadId":"main","turnId":"turn","delta":"content"}
        """), now: now.addingTimeInterval(30))
        let state = try #require(reducer.states.values.first)
        #expect(ActivityNotification.category(for: method) == .ignored)
        #expect(state.lastProgressAt == now)
        #expect(state.lastExecutionProgressAt == nil)
        #expect(events.isEmpty)
        #expect(reducer.tokenTurns.isEmpty)
    }

    @Test(arguments: ["agentMessage", "reasoning", "userMessage", "plan", "subAgentActivity"])
    func nonToolsNeverIncreaseToolCalls(_ type: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/completed", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"item","type":"\(type)","kind":"interacted","agentThreadId":"child"}}
        """), now: now)
        #expect(events.isEmpty)
    }

    @Test(arguments: ["commandExecution", "fileChange", "webSearch", "imageView", "imageGeneration", "sleep", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall"], [false, true])
    func toolStartAndEndPreserveOneInvocation(_ type: String, hasToolName: Bool) throws {
        var reducer = try prepared()
        let expectedTool = hasToolName && type != "commandExecution" ? "test" : nil
        let toolField = hasToolName ? #""tool":"test","# : ""
        let params = """
        {"threadId":"main","turnId":"turn","item":{"id":"item","type":"\(type)",\(toolField)"status":"completed"}}
        """
        let started = try reducer.consume(message("item/started", params: params), now: now)
        let ended = try reducer.consume(message("item/completed", params: params), now: now)
        #expect(started.first?.eventKind == .toolStarted)
        #expect(started.first?.source?.method == "item/started")
        #expect(started.first?.source?.threadID == "main")
        #expect(started.first?.source?.itemType == type)
        #expect(started.first?.tool == expectedTool)
        #expect(ended.first?.tool == expectedTool)
        #expect(ended.first?.eventKind == .toolCompleted)
        #expect(started.first?.name == "toolStarted")
        #expect(started.first?.id == "main:turn:item:toolStarted")
        #expect(ended.first?.name == "toolCompleted")
        #expect(ended.first?.id == "main:turn:item:toolCompleted")
        #expect(try reducer.consume(message("item/completed", params: params), now: now).isEmpty)
        var accumulator = ActivityAccumulator(rebuilding: CodexDateFormat.dayString(from: now), generationID: nil, generationStartedEmpty: true, eventCountAvailability: .all)
        for event in started + ended {
            accumulator.record(event)
        }
        #expect(accumulator.finalized(identifierStorage: .retained).metrics.toolCallCount == 1)
        let event = try #require(started.first)
        let data = try AppServerEventRecord(activity: event, recordedAt: now).jsonLineData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let activity = try #require(object["activityPayload"] as? [String: Any])
        #expect(activity["tool"] as? String == expectedTool)
        #expect((object["source"] as? [String: Any])?["itemType"] as? String == type)
        let restored = try #require(AppServerEventRecord.decode(from: data).activity)
        var task = ActivityTask(
            displayID: UUID(), key: ActivityTaskKey(event: restored), event: restored,
            state: .running, latestEvent: .toolStarted, startedAt: now, progressGeneration: 0
        )
        #expect(task.snapshot.toolDisplayName == (expectedTool ?? type))
        #expect(ActivityDisplayFormat.eventText(for: task.snapshot).contains(expectedTool ?? type))
        try task.mergeMetadata(from: #require(ended.first))
        task.latestEvent = .toolFinished
        #expect(ActivityDisplayFormat.eventText(for: task.snapshot).contains(expectedTool ?? type))
    }

    @Test(arguments: ["item/started", "item/completed"])
    func commandActionsPreserveFirstOccurrenceOrderInDisplayedActivity(_ method: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message(method, params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution","commandActions":[
            {"type":"search","command":"private command","query":"private query"},
            {"type":"unknown","command":"private command"},
            {"type":"read","name":"private file","path":"/private/file"},
            {"type":"search"},{"type":"listFiles"},{"type":"read"}
        ]}}
        """), now: now)
        let event = try #require(events.first)
        let data = try AppServerEventRecord(activity: event, recordedAt: now).jsonLineData()
        let storedText = try #require(String(data: data, encoding: .utf8))
        #expect(!storedText.contains("private"))
        let restored = try #require(AppServerEventRecord.decode(from: data).activity)
        let task = ActivityTask(
            displayID: UUID(), key: ActivityTaskKey(event: restored), event: restored,
            state: .running, latestEvent: method == "item/started" ? .toolStarted : .toolFinished,
            startedAt: now, progressGeneration: 0
        )
        #expect(task.snapshot.toolDisplayName == "search/read/listFiles")
        #expect(ActivityDisplayFormat.eventText(for: task.snapshot).contains("search/read/listFiles"))
        #expect(restored.source?.itemType == "commandExecution")
        #expect(restored.eventKind == (method == "item/started" ? .toolStarted : .toolCompleted))
    }

    @Test(arguments: ["", #", "commandActions":null"#, #", "commandActions":[]"#, #", "commandActions":[{"type":"unknown"},{"type":"unknown"}]"#])
    func commandWithoutKnownActionsFallsBackToItemType(_ actions: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution"\(actions)}}
        """), now: now)
        let event = try #require(events.first)
        let task = ActivityTask(
            displayID: UUID(), key: ActivityTaskKey(event: event), event: event,
            state: .running, latestEvent: .toolStarted, startedAt: now, progressGeneration: 0
        )
        #expect(event.tool == nil)
        #expect(task.snapshot.toolDisplayName == "commandExecution")
    }

    @Test func commandActionsDoNotOverrideOtherToolNames() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"tool","type":"mcpToolCall","tool":"actual_tool","commandActions":[{"type":"read"}]}}
        """), now: now)
        #expect(events.first?.tool == "actual_tool")
    }

    @Test func approvalResolutionDoesNotInventAnotherToolCall() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/commandExecution/requestApproval", params: """
        {"threadId":"main","turnId":"turn","itemId":"command"}
        """, id: 1), now: now)
        #expect(events.first?.eventKind == .approvalRequested)
        #expect(events.first?.source?.requestID != nil)
        #expect(events.first?.source?.itemID == "command")
        #expect(events.first?.source?.itemType == "commandExecution")
        #expect(events.first?.tool == nil)
        let key = ActivityTurnReference(threadID: "main", turnID: "turn", startedAt: now)
        #expect(reducer.states[key]?.isWaitingApproval == true)
        #expect(try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":1}"#), now: now).isEmpty)
        #expect(reducer.states[key]?.isWaitingApproval == false)
    }

    @Test func automaticReviewCountsRequestWithoutWaitingForUser() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/autoApprovalReview/started", params: """
        {"threadId":"main","turnId":"turn","targetItemId":"command","reviewId":"review"}
        """), now: now)
        #expect(events.first?.approvalReviewer == .autoReview)
        #expect(reducer.states.values.first?.isWaitingApproval != true)
    }

    @Test func snapshotWaitingDoesNotInventHistoricalApprovalCount() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("thread/status/changed", params: """
        {"threadId":"main","status":{"type":"active","activeFlags":["waitingOnApproval"]}}
        """), now: now)
        #expect(events.isEmpty)
        #expect(reducer.states.values.first?.isWaitingApproval == true)
    }

    @Test func detachedHistoryWithoutTerminalTimestampDoesNotEndLiveTask() throws {
        var reducer = try prepared()
        var detached = try thread()
        detached.status = ActivityThreadStatus(type: "notLoaded")
        _ = reducer.reconcile(thread: detached, turns: [turn(status: "interrupted")], reviewer: nil, now: now)
        #expect(reducer.states.values.first?.terminal == nil)
        #expect(reducer.states.values.first?.readStatus == .unavailable)
    }

    @Test func reconnectRestoresActiveSnapshotWithoutRecountingPrompt() throws {
        var reducer = try prepared()
        reducer.reconnect()
        let events = try reducer.reconcile(thread: thread(), turns: [turn()], reviewer: .user, now: now, bootstrap: true)
        #expect(events.count == 1)
        #expect(events.first?.timestamp == now)
    }

    @Test func compactionAndSubagentActivitiesRetainTheirOwnMeaning() throws {
        var reducer = try prepared()
        let compact = try reducer.consume(message("item/completed", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"compact","type":"contextCompaction"}}
        """), now: now)
        #expect(compact.first?.eventKind == .compactionCompleted)
        let agent = try reducer.consume(message("item/completed", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"spawn","type":"subAgentActivity","kind":"started","agentThreadId":"child"}}
        """), now: now)
        #expect(agent.first?.eventKind == .subagentStarted)
        #expect(agent.first?.tool == nil)
    }

    private func tokenMessage(total: Int) throws -> ActivityNotification {
        try message("thread/tokenUsage/updated", params: """
        {"threadId":"main","turnId":"turn","tokenUsage":{
        "total":{"inputTokens":\(total),"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":\(total)},
        "last":{"inputTokens":10,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":10}}}
        """)
    }

    @Test func tokenTotalsUseDeltasAndReconnectDiscardsOfflineGap() throws {
        var reducer = try prepared()
        _ = try reducer.consume(tokenMessage(total: 1000), now: now)
        #expect(reducer.tokenTurns.isEmpty)
        _ = try reducer.consume(tokenMessage(total: 1100), now: now)
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 100)
        _ = try reducer.consume(tokenMessage(total: 1100), now: now)
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 100)
        reducer.reconnect()
        _ = try reducer.consume(tokenMessage(total: 5000), now: now)
        _ = try reducer.consume(tokenMessage(total: 5020), now: now)
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 120)
    }

    @Test func newThreadIncludesFirstResponseAndCounterResetDoesNotSubtractUsage() throws {
        var reducer = try prepared()
        reducer.markNewThread("main")
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 100)
        _ = try reducer.consume(tokenMessage(total: 20), now: now)
        _ = try reducer.consume(tokenMessage(total: 30), now: now)
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 110)
    }

    @Test func eventRecorderDeduplicatesAcrossInstancesAndRestarts() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = ActivityRecorder(directoryURL: directory.url)
        let second = ActivityRecorder(directoryURL: directory.url)
        var reducer = try prepared()
        let events = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution"}}
        """), now: now)
        let event = try #require(events.first)
        try await first.record(event: event)
        try await second.record(event: event)
        try await first.record(event: event)
        let url = directory.url.appendingPathComponent("Events/\(CodexDateFormat.dayString(from: now)).jsonl")
        var stored: [ActivityRecord] = []
        try AppServerEventJournal.read(at: url) {
            if let event = $0.activity {
                stored.append(event)
            }
        }
        #expect(stored.count == 1)
    }

    @Test func incrementalTokenStorageRetainsAllCountersAcrossRestart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let usage = TokenUsage(
            inputTokens: 100,
            cachedInputTokens: 50,
            cacheWriteInputTokens: 10,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            totalTokens: 120
        )
        let record = TokenTurn(id: "one", rootID: "one", startedAt: now, updatedAt: now, usage: usage)
        try await store.record([record, record], now: now)
        let restarted = TokenHistoryStore(directoryURL: directory.url)
        let records = try await restarted.refresh(now: now)
        #expect(records.count == 1)
        #expect(records.first?.usage == usage)
    }

    @Test func tokenWriterLeaseTransfersWithoutTwoWriters() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = TokenHistoryStore(directoryURL: directory.url)
        let second = TokenHistoryStore(directoryURL: directory.url)
        #expect(try await first.acquireRecordingLease())
        #expect(try await !second.acquireRecordingLease())
        await first.releaseRecordingLease()
        #expect(try await second.acquireRecordingLease())
        await second.releaseRecordingLease()
    }

    @Test func rebuildUsesObservedRecordsAndContinuesCollecting() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let usage = TokenUsage(
            inputTokens: 100,
            cachedInputTokens: 30,
            cacheWriteInputTokens: 10,
            outputTokens: 20,
            reasoningOutputTokens: 5,
            totalTokens: 120
        )
        let record = TokenTurn(id: "one", rootID: "one", startedAt: now, updatedAt: now)
        let first = TokenObservation(turn: record, rootStartedAt: now, streamID: "stream", sequence: 1, previous: .zero, current: usage)
        _ = try await store.recordObservations([first], now: now)
        let rebuilt = try await store.rebuild(for: [CodexDateFormat.dayString(from: now)], now: now.addingTimeInterval(1))
        #expect(rebuilt.turnCount == 1)
        let second = try TokenObservation(
            turn: record,
            rootStartedAt: now,
            streamID: "stream",
            sequence: 2,
            previous: usage,
            current: #require(usage.adding(usage))
        )
        _ = try await store.recordObservations([second], now: now.addingTimeInterval(2))
        let records = try await store.refresh(now: now.addingTimeInterval(2))
        #expect(records.first?.usage == usage.adding(usage))
        #expect(records.first?.rebuiltAt == now.addingTimeInterval(1))
        #expect(records.first?.generationID != "initial")
    }

    @Test func multipleApprovalRequestsResolveIndependently() throws {
        var reducer = try prepared()
        for id in [1, 2] {
            _ = try reducer.consume(message("item/commandExecution/requestApproval", params: """
            {"threadId":"main","turnId":"turn","itemId":"command-\(id)"}
            """, id: id), now: now)
        }
        _ = try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":1}"#), now: now)
        #expect(reducer.states.values.first?.isWaitingApproval == true)
        _ = try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":2}"#), now: now)
        #expect(reducer.states.values.first?.isWaitingApproval == false)
    }

    @Test func childKeepsItsOriginalRootAcrossParentTurns() throws {
        var reducer = try prepared()
        let child = try thread("child", source: #"{"subAgent":{"thread_spawn":{"parent_thread_id":"main"}}}"#)
        _ = reducer.reconcile(thread: child, turns: [turn("child-turn")], reviewer: .user, now: now)
        let next = ActivityTurn(id: "next", status: "inProgress", startedAt: now.addingTimeInterval(10).timeIntervalSince1970)
        _ = try reducer.reconcile(thread: thread(), turns: [next], reviewer: .user, now: now.addingTimeInterval(10))
        _ = reducer.reconcile(thread: child, turns: [turn("child-followup")], reviewer: .user, now: now.addingTimeInterval(11))
        let state = reducer.states[ActivityTurnReference(threadID: "child", turnID: "child-followup", startedAt: now)]
        #expect(state?.rootSessionID == "main")
        #expect(state?.rootTurnID == "turn")
    }

    @Test func settingsUpdateChangesMetadataWithoutInventingEvents() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("thread/settings/updated", params: """
        {"threadId":"main","threadSettings":{"model":"new-model","effort":"low","approvalsReviewer":"auto_review"}}
        """), now: now)
        #expect(events.isEmpty)
        var snapshot = try thread()
        snapshot.model = nil
        snapshot.reasoningEffort = nil
        _ = reducer.reconcile(thread: snapshot, turns: [turn()], reviewer: nil, now: now)
        let command = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution"}}
        """), now: now)
        #expect(command.first?.model == "new-model")
        #expect(command.first?.effort == "low")
        #expect(command.first?.approvalReviewer == .autoReview)
    }

    @Test func missingFirstTurnUsageDoesNotMoveItsTokensIntoNextTurn() throws {
        var reducer = try prepared()
        reducer.markNewThread("main")
        _ = try reducer.consume(message("turn/completed", params: """
        {"threadId":"main","turn":{"id":"turn","status":"completed"}}
        """), now: now)
        _ = try reducer.consume(message("turn/started", params: """
        {"threadId":"main","turn":{"id":"next","status":"inProgress"}}
        """), now: now)
        let raw = """
        {"threadId":"main","turnId":"next","tokenUsage":{
        "total":{"inputTokens":500,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":500},
        "last":{"inputTokens":100,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":100}}}
        """
        _ = try reducer.consume(message("thread/tokenUsage/updated", params: raw), now: now)
        #expect(reducer.tokenTurns.isEmpty)
    }
}

extension AppServerActivityTests {
    @Test(arguments: ["completed", "failed", "interrupted"])
    func loadedTerminalWithoutTimestampEndsLiveTurn(status: String) throws {
        var reducer = try prepared()
        let idle = ActivityThread(id: "main", status: ActivityThreadStatus(type: "idle"))
        _ = reducer.reconcile(thread: idle, turns: [ActivityTurn(id: "turn", status: status)], reviewer: nil, now: now.addingTimeInterval(30))
        let state = try #require(reducer.states.values.first { $0.turnID == "turn" })
        #expect(state.terminal != nil)
        #expect(state.readStatus == .complete)
        #expect(state.isHistoricalTerminal)
        if case let .completed(at, duration) = state.terminal {
            #expect(at == nil)
            #expect(duration == nil)
        }
    }

    @Test func unknownTurnStatusNeverFabricatesCompletion() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("turn/completed", params: #"{"threadId":"main","turn":{"id":"turn","status":"futureStatus"}}"#), now: now)
        #expect(events.isEmpty)
        #expect(reducer.states.values.first?.terminal == nil)
    }
}

extension AppServerActivityTests {
    @Test func collectorContinuesFromCommittedCorrectionWithoutResettingServerCounter() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        var reducer = try prepared()
        reducer.markNewThread("main")
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        let committed = try await store.recordObservations(reducer.takeTokenObservations(), now: now)
        reducer.acceptTokenTurns(committed)
        var correction = try #require(committed.first { $0.usage != nil })
        correction.usage = TokenUsage(
            inputTokens: 60,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
            totalTokens: 60
        )
        correction.startNewGeneration(at: now)
        try await store.record([correction], now: now)
        // 修正发生在采集器提交下一笔之前, 内存仍可能暂时持有旧累计值
        _ = try reducer.consume(tokenMessage(total: 110), now: now.addingTimeInterval(1))
        let result = try await store.recordObservations(reducer.takeTokenObservations(), now: now)
        reducer.acceptTokenTurns(result)
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 70)
        #expect(reducer.states.values.first?.tokenUsage?.totalTokens == 70)
        _ = try reducer.consume(tokenMessage(total: 120), now: now.addingTimeInterval(2))
        #expect(reducer.tokenTurns.first?.usage?.totalTokens == 80)
    }

    @Test func repeatedHistoricalTerminalKeepsObservationTimeAndNotificationPolicy() throws {
        var reducer = try prepared()
        let idle = ActivityThread(id: "main", status: ActivityThreadStatus(type: "idle"))
        let completed = ActivityTurn(id: "turn", status: "completed")
        _ = reducer.reconcile(thread: idle, turns: [completed], reviewer: nil, now: now)
        _ = reducer.reconcile(thread: idle, turns: [completed], reviewer: nil, now: now.addingTimeInterval(60))
        let state = try #require(reducer.states.values.first)
        #expect(state.terminalObservedAt == now)
        #expect(state.lastProgressAt == now)
        #expect(state.isHistoricalTerminal)
    }
}
