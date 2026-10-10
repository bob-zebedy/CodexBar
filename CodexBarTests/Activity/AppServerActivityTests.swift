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
        ActivityTurn(id: id, status: ActivityTurnStatus(rawValue: status == "inProgress" ? "running" : status) ?? .unknown, rootTurnId: id, startedAt: now)
    }

    private func message(_ method: String, params: String, id: Int? = nil) throws -> ActivityInput {
        var fields = try #require(JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any])
        if method.hasSuffix("/requestApproval"), fields["startedAtMs"] == nil {
            fields["startedAtMs"] = now.timeIntervalSince1970 * 1000
        }
        var envelope: [String: Any] = ["method": method, "params": fields]
        if let id {
            envelope["id"] = id
        }
        return try JSONDecoder().decode(ActivityInput.self, from: JSONSerialization.data(withJSONObject: envelope))
    }

    private func prepared() throws -> AppServerActivityReducer {
        var reducer = AppServerActivityReducer()
        _ = try reducer.reconcile(thread: thread(), turns: [turn()], now: now)
        return reducer
    }

    @Test(arguments: [
        "item/started", "item/completed", "thread/tokenUsage/updated",
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval",
        "item/agentMessage/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta"
    ], [nil, ""] as [String?])
    func turnScopedNotificationsRejectMissingIdentity(_ method: String, turnID: String?) throws {
        var params: [String: Any] = ["threadId": "main", "itemId": "item", "item": ["id": "item", "type": "commandExecution"]]
        if let turnID {
            params["turnId"] = turnID
        }
        let json = try #require(String(data: JSONSerialization.data(withJSONObject: params), encoding: .utf8))
        #expect(throws: DecodingError.self) { try message(method, params: json) }
    }

    @Test(arguments: [
        "item/agentMessage/delta", "item/reasoning/textDelta", "item/reasoning/summaryTextDelta",
        "item/commandExecution/outputDelta"
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
        #expect(state.isWaitingApproval == true)
        #expect(state.approvalChangedAt == now)
        #expect(events.isEmpty)
        #expect(reducer.tokenTurns == tokens)
        #expect(state.tokenUsage?.totalTokens == 10)
    }

    @Test(arguments: [
        "thread/settings/updated", "thread/environment/connected", "thread/environment/disconnected",
        "item/plan/delta", "item/tool/requestUserInput", "item/autoApprovalReview/started", "item/autoApprovalReview/completed",
        "item/fileChange/outputDelta", "item/future/delta", "item/future/outputDelta", "hook/delta", "command/exec/outputDelta",
        "process/outputDelta", "item/reasoning/textDelta/extra", "item/agentMessage/Delta"
    ])
    func unknownMethodsCannotRefreshActivity(_ method: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message(method, params: """
        {"threadId":"main","turnId":"turn","delta":"content"}
        """), now: now.addingTimeInterval(30))
        let state = try #require(reducer.states.values.first)
        #expect(AppServerActivityProtocol.kind(for: method).category == .ignored)
        #expect(state.lastProgressAt == now)
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

    @Test(
        arguments: ["commandExecution", "fileChange", "webSearch", "imageView", "imageGeneration", "sleep", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall"],
        [false, true]
    )
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
        #expect(started.first?.context?.method == "item/started")
        #expect(started.first?.context?.threadID == "main")
        #expect(started.first?.context?.itemType == type)
        #expect(started.first?.toolName == expectedTool)
        #expect(ended.first?.toolName == expectedTool)
        #expect(ended.first?.eventKind == .toolCompleted)
        #expect(started.first?.name == "toolStarted")
        #expect(started.first?.id == "main:turn:item:toolStarted")
        #expect(ended.first?.name == "toolCompleted")
        #expect(ended.first?.id == "main:turn:item:toolCompleted")
        #expect(try reducer.consume(message("item/completed", params: params), now: now).isEmpty)
        var accumulator = ActivityAccumulator(rebuilding: CodexDateFormat.dayString(from: now), generationID: nil, eventCountAvailability: .all)
        for event in started + ended {
            accumulator.record(event)
        }
        #expect(accumulator.finalized(identifierStorage: .retained).metrics.toolCallCount == 1)
        let event = try #require(started.first)
        let data = try AppServerEventRecord(activity: event, recordedAt: now).jsonLineData()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let activity = try #require(object["activityPayload"] as? [String: Any])
        #expect(activity["toolName"] as? String == expectedTool)
        #expect(activity["tool"] == nil)
        #expect(activity["commandActionTypes"] == nil)
        #expect((object["context"] as? [String: Any])?["itemType"] as? String == type)
        let restored = try #require(AppServerEventRecord.decode(from: data).activity)
        #expect(restored.toolName == expectedTool)
        #expect(restored.context?.itemType == type)
    }

    @Test(arguments: ["item/started", "item/completed"])
    func commandActionTypesKeepRawOrderAndLocalizeDisplay(_ method: String) throws {
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
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["activityPayload"] as? [String: Any])
        #expect(payload["commandActionTypes"] as? [String] == ["search", "unknown", "read", "search", "listFiles", "read"])
        #expect(payload["commandActions"] == nil)
        #expect(payload["toolName"] == nil)
        #expect(payload["tool"] == nil)
        let restored = try #require(AppServerEventRecord.decode(from: data).activity)
        let approval = ActivityApproval(
            requestedAt: now, toolName: restored.toolName, sequence: 0,
            itemType: restored.context?.itemType, commandActionTypes: restored.commandActionTypes
        )
        #expect(restored.toolName == nil)
        #expect(restored.commandActionTypes == ["search", "unknown", "read", "search", "listFiles", "read"])
        #expect(approval.commandActionTypes == restored.commandActionTypes)
        let expectedDisplay = String(localized: "activity.live.actions-read-listFiles-search")
        #expect(approval.actionText == expectedDisplay)
        #expect(restored.context?.itemType == "commandExecution")
        #expect(restored.eventKind == (method == "item/started" ? .toolStarted : .toolCompleted))
    }

    @Test(arguments: ["", #", "commandActions":null"#, #", "commandActions":[]"#, #", "commandActions":[{"type":"unknown"},{"type":"unknown"}]"#])
    func commandWithoutKnownActionsFallsBackToItemType(_ actions: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution"\(actions)}}
        """), now: now)
        let event = try #require(events.first)
        let approval = ActivityApproval(
            requestedAt: now, toolName: event.toolName, sequence: 0,
            itemType: event.context?.itemType, commandActionTypes: event.commandActionTypes
        )
        #expect(event.toolName == nil)
        #expect(approval.actionText == String(localized: "activity.action.command"))
    }

    @Test(arguments: ["actual_tool", "search/read"])
    func commandActionTypesDoNotOverrideOtherToolNames(_ name: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"tool","type":"mcpToolCall","tool":"\(name)","commandActions":[{"type":"read"}]}}
        """), now: now)
        let event = try #require(events.first)
        #expect(event.toolName == name)
        #expect(event.commandActionTypes == nil)
        let restored = try #require(AppServerEventRecord.decode(from: AppServerEventRecord(activity: event).jsonLineData()).activity)
        let approval = ActivityApproval(
            requestedAt: now, toolName: restored.toolName, sequence: 0,
            itemType: restored.context?.itemType, commandActionTypes: restored.commandActionTypes
        )
        #expect(approval.actionText == name)
    }

    @Test func approvalKeepsCommandActionTypesWhenAnotherToolUpdatesTheTask() throws {
        var reducer = try prepared()
        let started = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution","commandActions":[{"type":"read"},{"type":"search"}]}}
        """), now: now)
        let event = try #require(started.first)
        var task = try ActivityTask(
            displayID: UUID(), key: #require(ActivityTaskKey(event: event)), event: event,
            state: .running, startedAt: now, progressGeneration: 0
        )
        let approvals = try reducer.consume(message("item/commandExecution/requestApproval", params: """
        {"threadId":"main","turnId":"turn","itemId":"command","commandActions":[{"type":"read"},{"type":"search"}]}
        """, id: 1), now: now.addingTimeInterval(1))
        let approval = try #require(approvals.first)
        let restored = try #require(AppServerEventRecord.decode(from: AppServerEventRecord(activity: approval).jsonLineData()).activity)
        let enteredWaiting = task.recordApprovalRequest(from: restored)
        #expect(enteredWaiting)
        let others = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"other","type":"mcpToolCall","tool":"search/read"}}
        """), now: now.addingTimeInterval(2))
        try task.mergeMetadata(from: #require(others.first))
        try task.resumeExecution(from: #require(others.first))
        #expect(task.state == .waitingApproval)
        let lifecycle = try #require(reducer.states[ActivityTurnReference(threadID: "main", turnID: "turn")])
        task.mergeExecutionLifecycle(lifecycle, owner: ActivityExecutionKey(agentID: nil, turnID: "turn"))
        #expect(task.displayedApproval?.toolName == nil)
        #expect(task.displayedApproval?.commandActionTypes == ["read", "search"])
        #expect(task.snapshot.approvalActionText == String(localized: "activity.live.actions-read-search"))
        let notification = NotificationContent.taskWaiting(project: task.snapshot.projectName, actionText: task.snapshot.approvalActionText)
        #expect(notification.body.contains(String(localized: "activity.live.actions-read-search")))
    }

    @Test func approvalResolutionDoesNotInventAnotherToolCall() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/commandExecution/requestApproval", params: """
        {"threadId":"main","turnId":"turn","itemId":"command"}
        """, id: 1), now: now)
        #expect(events.first?.eventKind == .approvalRequested)
        #expect(events.first?.context?.requestID != nil)
        #expect(events.first?.context?.itemID == "command")
        #expect(events.first?.context?.itemType == "commandExecution")
        #expect(events.first?.toolName == nil)
        let key = ActivityTurnReference(threadID: "main", turnID: "turn")
        #expect(reducer.states[key]?.isWaitingApproval == true)
        #expect(try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":1}"#), now: now).isEmpty)
        #expect(reducer.states[key]?.isWaitingApproval == false)
    }

    @Test func automaticReviewDoesNotCountRequest() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/autoApprovalReview/started", params: """
        {"threadId":"main","turnId":"turn","targetItemId":"command","reviewId":"review"}
        """), now: now)
        #expect(events.isEmpty)
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
        detached.status = ActivityThreadStatus(type: .notLoaded)
        _ = reducer.reconcile(thread: detached, turns: [turn(status: "interrupted")], now: now)
        #expect(reducer.states.values.first?.terminal == nil)
        #expect(reducer.states.values.first?.readStatus == .unavailable)
    }

    @Test func reconnectRestoresActiveSnapshotWithoutRecountingPrompt() throws {
        var reducer = try prepared()
        reducer.reconnect()
        let events = try reducer.reconcile(thread: thread(), turns: [turn()], now: now, bootstrap: true)
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
        #expect(agent.first?.toolName == nil)
    }

    private func tokenMessage(total: Int) throws -> ActivityInput {
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
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 100)
        _ = try reducer.consume(tokenMessage(total: 1100), now: now)
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 100)
        reducer.reconnect()
        _ = try reducer.consume(tokenMessage(total: 5000), now: now)
        _ = try reducer.consume(tokenMessage(total: 5020), now: now)
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 120)
    }

    @Test func newThreadIncludesFirstResponseAndCounterResetDoesNotSubtractUsage() throws {
        var reducer = try prepared()
        reducer.markNewThread("main")
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 100)
        _ = try reducer.consume(tokenMessage(total: 20), now: now)
        _ = try reducer.consume(tokenMessage(total: 30), now: now)
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 110)
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
        let observation = TokenObservation(
            turn: TokenTurn(id: "one", rootID: "one", startedAt: now, updatedAt: now),
            rootStartedAt: now, streamID: "stream", sequence: 1, previous: .zero, current: usage
        )
        _ = try await store.recordObservations([observation, observation], now: now)
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
        let event = TestFixtures.event(at: now, thread: "main", turn: "turn")
        var task = ActivityTask(displayID: UUID(), key: .init(thread: "main", turn: "turn"), event: event, state: .running, startedAt: now, progressGeneration: 0)
        let reference = ActivityTurnReference(threadID: "main", turnID: "turn")
        let owner = ActivityExecutionKey(agentID: nil, turnID: "turn")
        for id in [1, 2] {
            let action = id == 1 ? "read" : "search"
            _ = try reducer.consume(message("item/commandExecution/requestApproval", params: """
            {"threadId":"main","turnId":"turn","itemId":"command-\(id)","commandActions":[{"type":"\(action)"}]}
            """, id: id), now: now)
        }
        try task.mergeExecutionLifecycle(#require(reducer.states[reference]), owner: owner)
        #expect(task.displayedApproval?.commandActionTypes == ["read"])
        _ = try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":999}"#), now: now)
        #expect(reducer.states[reference]?.pendingApprovals.count == 2)
        _ = try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":1}"#), now: now)
        #expect(reducer.states.values.first?.isWaitingApproval == true)
        try task.mergeExecutionLifecycle(#require(reducer.states[reference]), owner: owner)
        #expect(task.state == .waitingApproval)
        #expect(task.displayedApproval?.commandActionTypes == ["search"])
        _ = try reducer.consume(message("serverRequest/resolved", params: #"{"threadId":"main","requestId":2}"#), now: now)
        #expect(reducer.states.values.first?.isWaitingApproval == false)
        try task.mergeExecutionLifecycle(#require(reducer.states[reference]), owner: owner)
        #expect(task.state == .running)
        #expect(task.snapshot.approvalActionText == nil)
    }

    @Test(arguments: ["thread/status/changed", "turn/completed"])
    func authoritativeStateClearsPendingRequests(method: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/commandExecution/requestApproval", params: #"{"threadId":"main","turnId":"turn","itemId":"command"}"#, id: 1), now: now)
        let params = method == "turn/completed"
            ? #"{"threadId":"main","turn":{"id":"turn","status":"completed"}}"#
            : #"{"threadId":"main","status":{"type":"active","activeFlags":[]}}"#
        _ = try reducer.consume(message(method, params: params), now: now)
        let state = try #require(reducer.states[ActivityTurnReference(threadID: "main", turnID: "turn")])
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.isWaitingApproval == false)
    }

    @Test func eachChildTurnUsesItsDeclaredRoot() throws {
        var reducer = try prepared()
        var parentTurn = turn()
        parentTurn.items = [ActivityItem(id: "spawn", type: .subAgentActivity, agentThreadId: "child", kind: "started", reasoningEffort: "low")]
        _ = try reducer.reconcile(thread: thread(), turns: [parentTurn], now: now)
        let child = try thread("child", source: #"{"subAgent":{"thread_spawn":{"parent_thread_id":"main"}}}"#)
        var first = turn("child-turn")
        first.rootTurnId = "turn"
        _ = reducer.reconcile(thread: child, turns: [first], now: now)
        let next = ActivityTurn(id: "next", status: .running, rootTurnId: "next", startedAt: now.addingTimeInterval(10))
        _ = try reducer.reconcile(thread: thread(), turns: [next], now: now.addingTimeInterval(10))
        var followup = turn("child-followup")
        followup.rootTurnId = "next"
        _ = reducer.reconcile(thread: child, turns: [followup], now: now.addingTimeInterval(11))
        #expect(reducer.states[.init(threadID: "child", turnID: first.id)]?.rootTurnID == "turn")
        let state = reducer.states[ActivityTurnReference(threadID: "child", turnID: followup.id)]
        #expect(state?.rootThreadID == "main")
        #expect(state?.rootTurnID == "next")
        #expect(state?.effort == "high")
        #expect(reducer.states[.init(threadID: "child", turnID: first.id)]?.effort == "mixed")
    }

    @Test func absentRootDoesNotInferFromParentTime() throws {
        var reducer = try prepared()
        let child = try thread("child", source: #"{"subAgent":{"thread_spawn":{"parent_thread_id":"main"}}}"#)
        let unknown = ActivityTurn(id: "child-turn", status: .running, startedAt: now)
        _ = reducer.reconcile(thread: child, turns: [unknown], now: now)
        let state = reducer.states[.init(threadID: "child", turnID: unknown.id)]
        #expect(state?.rootTurnID == nil)
        #expect(state?.rootThreadID == nil)
    }

    @Test func lateRootResolvesNestedChildAndRetainsObservedTokens() throws {
        var reducer = AppServerActivityReducer()
        let child = try thread("child", source: #"{"subAgent":{"thread_spawn":{"parent_thread_id":"middle"}}}"#)
        var childTurn = turn("child-turn")
        childTurn.rootTurnId = "turn"
        _ = reducer.reconcile(thread: child, turns: [childTurn], now: now)
        #expect(reducer.missingRootTurns()["middle"] == ["turn"])
        reducer.markNewThread("child")
        _ = try reducer.consume(message("thread/tokenUsage/updated", params: """
        {"threadId":"child","turnId":"child-turn","tokenUsage":{
        "total":{"inputTokens":15,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":15},
        "last":{"inputTokens":15,"cachedInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0,"totalTokens":15}}}
        """), now: now)
        #expect(reducer.takeTokenObservations().isEmpty)
        _ = try reducer.reconcile(thread: thread(), turns: [turn()], now: now)
        let state = reducer.states[.init(threadID: "child", turnID: childTurn.id)]
        #expect(state?.rootThreadID == "main")
        let observation = try #require(reducer.takeTokenObservations().first)
        #expect(observation.turn.rootID == TokenTurn.identifier(thread: "main", turn: "turn"))
        #expect(observation.current.totalTokens == 15)
        _ = try reducer.reconcile(thread: thread(), turns: [turn()], now: now)
        #expect(reducer.takeTokenObservations().isEmpty)
    }

    @Test func creationMetadataUsesChildModelWithoutInventingChildTurn() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/completed", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"spawn","type":"subAgentActivity","kind":"started",
        "agentThreadId":"child","model":"child-model","reasoningEffort":"low"}}
        """), now: now)
        let event = try #require(events.first)
        #expect(event.model == "child-model")
        #expect(event.effort == "low")
        #expect(event.turnID == nil)
        #expect(event.context?.turnID == "turn")
        var accumulator = ActivityAccumulator(rebuilding: "2026-10-09", generationID: nil, eventCountAvailability: .all)
        accumulator.record(event)
        #expect(accumulator.finalized(identifierStorage: .retained).modelCounts == ["child-model": 1])
        let parentEvent = try #require(reducer.reconcile(thread: thread(), turns: [turn()], now: now, bootstrap: true).first)
        var task = ActivityTask(displayID: UUID(), key: .init(thread: "main", turn: "turn"), event: parentEvent, state: .running, startedAt: now, progressGeneration: 0)
        task.mergeMetadata(from: event)
        #expect(task.modelName == "gpt-5")
        #expect(task.effort == "mixed")
    }

    @Test func missingCreationMetadataDoesNotBorrowParentConfiguration() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("item/completed", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"spawn","type":"subAgentActivity","kind":"started","agentThreadId":"child"}}
        """), now: now)
        let event = try #require(events.first)
        #expect(event.model == nil)
        #expect(event.effort == nil)
        #expect(event.turnID == nil)
    }

    @Test func creationBeforeChildDiscoverySurvivesPruning() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"spawn","type":"subAgentActivity","kind":"started",
        "agentThreadId":"child","model":"child-model","reasoningEffort":"low"}}
        """), now: now)
        var child = try thread("child", source: #"{"subAgent":{"thread_spawn":{"parent_thread_id":"main"}}}"#)
        child.reasoningEffort = nil
        var childTurn = turn("child-turn")
        childTurn.rootTurnId = "turn"
        _ = reducer.reconcile(thread: child, turns: [childTurn], now: now)
        #expect(reducer.missingSubagentContexts(in: "main").isEmpty)
        #expect(reducer.states[.init(threadID: "child", turnID: "child-turn")]?.effort == "low")
    }

    @Test func snapshotCreationMetadataBackfillsKnownChildWithoutRecounting() throws {
        var reducer = try prepared()
        var child = try thread("child", source: #"{"subAgent":{"thread_spawn":{"parent_thread_id":"main"}}}"#)
        child.reasoningEffort = nil
        var childTurn = turn("child-turn")
        childTurn.rootTurnId = "turn"
        _ = reducer.reconcile(thread: child, turns: [childTurn], now: now)
        #expect(reducer.missingSubagentContexts(in: "main") == ["child"])
        var parentTurn = turn()
        parentTurn.items = [ActivityItem(id: "spawn", type: .subAgentActivity, agentThreadId: "child", kind: "started", model: "child-model", reasoningEffort: "low")]
        let events = try reducer.reconcile(thread: thread(), turns: [parentTurn], now: now)
        #expect(events.isEmpty)
        #expect(reducer.missingSubagentContexts(in: "main").isEmpty)
        #expect(reducer.states[.init(threadID: "child", turnID: "child-turn")]?.effort == "low")
    }

    @Test func threadReadReplacesConfigurationIncludingUnsetValues() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("thread/settings/updated", params: """
        {"threadId":"main","threadSettings":{"model":"new-model","effort":"low","approvalsReviewer":"auto_review"}}
        """), now: now)
        #expect(events.isEmpty)
        var snapshot = try thread()
        snapshot.cwd = "/updated"
        snapshot.model = nil
        snapshot.reasoningEffort = nil
        _ = reducer.reconcile(thread: snapshot, turns: [turn()], now: now)
        let command = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"command","type":"commandExecution"}}
        """), now: now)
        #expect(command.first?.cwd == "/updated")
        #expect(command.first?.model == nil)
        #expect(command.first?.effort == nil)
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
        let idle = ActivityThread(id: "main", status: ActivityThreadStatus(type: .idle))
        _ = reducer.reconcile(
            thread: idle,
            turns: [ActivityTurn(id: "turn", status: ActivityTurnStatus(rawValue: status == "inProgress" ? "running" : status) ?? .unknown)],
            now: now.addingTimeInterval(30)
        )
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
    @Test func refreshedHistoryReplaysOnlyUncommittedObservationsWithoutLosingLiveUsage() throws {
        var reducer = try prepared()
        reducer.markNewThread("main")
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        _ = reducer.takeTokenObservations()
        let snapshot = Array(reducer.tokenTurns.values)
        _ = try reducer.consume(tokenMessage(total: 120), now: now.addingTimeInterval(1))
        _ = try reducer.consume(tokenMessage(total: 150), now: now.addingTimeInterval(2))
        let pending = reducer.takeTokenObservations()
        try reducer.acceptTokenTurns(snapshot, replaying: pending)
        #expect(reducer.states.values.first?.tokenUsage?.totalTokens == 150)
        let committed = Array(reducer.tokenTurns.values)
        try reducer.acceptTokenTurns(committed, replaying: pending)
        #expect(reducer.states.values.first?.tokenUsage?.totalTokens == 150)
        _ = try reducer.consume(tokenMessage(total: 160), now: now.addingTimeInterval(3))
        #expect(reducer.states.values.first?.tokenUsage?.totalTokens == 160)
    }

    @Test func collectorContinuesFromCommittedCorrectionWithoutResettingServerCounter() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        var reducer = try prepared()
        reducer.markNewThread("main")
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        let committed = try await store.recordObservations(reducer.takeTokenObservations(), now: now)
        try reducer.acceptTokenTurns(committed)
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
        try await directory.seedTokenSnapshots([correction], now: now)
        // 修正发生在采集器提交下一笔之前, 内存仍可能暂时持有旧累计值
        _ = try reducer.consume(tokenMessage(total: 110), now: now.addingTimeInterval(1))
        let result = try await store.recordObservations(reducer.takeTokenObservations(), now: now)
        try reducer.acceptTokenTurns(result)
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 70)
        #expect(reducer.states.values.first?.tokenUsage?.totalTokens == 70)
        _ = try reducer.consume(tokenMessage(total: 120), now: now.addingTimeInterval(2))
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 80)
    }

    @Test func repeatedHistoricalTerminalKeepsObservationTimeAndNotificationPolicy() throws {
        var reducer = try prepared()
        let idle = ActivityThread(id: "main", status: ActivityThreadStatus(type: .idle))
        let completed = ActivityTurn(id: "turn", status: .completed)
        _ = reducer.reconcile(thread: idle, turns: [completed], now: now)
        _ = reducer.reconcile(thread: idle, turns: [completed], now: now.addingTimeInterval(60))
        let state = try #require(reducer.states.values.first)
        #expect(state.terminalObservedAt == now)
        #expect(state.lastProgressAt == now)
        #expect(state.isHistoricalTerminal)
    }
}

extension AppServerActivityTests {
    @Test(arguments: [true, false])
    func distinctApprovalCallbacksArePersistedButReplayIsDeduplicated(hasApprovalID: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        var reducer = try prepared()
        let recorder = ActivityRecorder(directoryURL: directory.url)
        let date = Date()
        var events: [ActivityRecord] = []
        for (index, callback) in [1, 2, 1].enumerated() {
            let started = date.timeIntervalSince1970 * 1000 + (hasApprovalID ? 0 : Double(callback))
            let approval = hasApprovalID ? ",\"approvalId\":\"callback-\(callback)\"" : ""
            let notification = try message("item/commandExecution/requestApproval", params: """
            {"threadId":"main","turnId":"turn","itemId":"command","startedAtMs":\(started)\(approval)}
            """, id: index)
            events += reducer.consume(notification, now: date)
        }
        #expect(events.count == 2)
        #expect(Set(events.compactMap(\.id)).count == 2)
        for event in events + events {
            try await recorder.record(event: event)
        }
        let url = HistoryStorage.eventLogURL(for: HistoryStorage.dateKey(for: date), in: HistoryStorage.eventsDirectoryURL(in: directory.url))
        var count = 0
        try AppServerEventJournal.read(at: url) {
            if $0.activity?.eventKind == .approvalRequested {
                count += 1
            }
        }
        #expect(count == 2)
    }

    @Test func inactiveThreadMetadataExpiresWhileRunningAndLoadedThreadsRemain() throws {
        var reducer = AppServerActivityReducer()
        for index in 0 ..< 100 {
            _ = try reducer.reconcile(thread: thread("old-\(index)"), turns: [turn(status: "completed")], now: now)
        }
        _ = try reducer.reconcile(thread: thread("running"), turns: [turn()], now: now)
        _ = try reducer.reconcile(thread: thread("loaded"), turns: [turn(status: "completed")], now: now)
        reducer.maintain(loadedThreads: ["loaded"], now: now.addingTimeInterval(2 * 86400))
        #expect(Set(reducer.threads.keys) == ["running", "loaded"])
        #expect(reducer.states.count == 1)
    }

    @Test func historyRetentionIsRecheckedOnNextDayAndAfterReplacingHistory() throws {
        var reducer = try prepared()
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        let retained = TokenTurn(id: "edge", rootID: "edge", updatedAt: cutoff)
        try reducer.acceptTokenTurns([retained])
        reducer.maintain(loadedThreads: ["main"], now: now)
        #expect(reducer.tokenTurns.count == 1)
        let expired = TokenTurn(id: "expired", rootID: "expired", updatedAt: cutoff.addingTimeInterval(-1))
        try reducer.acceptTokenTurns([retained, expired])
        reducer.maintain(loadedThreads: ["main"], now: now.addingTimeInterval(1))
        #expect(Set(reducer.tokenTurns.keys) == ["edge"])
        reducer.maintain(loadedThreads: ["main"], now: now.addingTimeInterval(86400))
        #expect(reducer.tokenTurns.isEmpty)
    }
}

extension AppServerActivityTests {
    @Test func retiringThreadDoesNotReuseTokenSequenceOnReobservation() throws {
        var reducer = try prepared()
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        _ = try reducer.consume(tokenMessage(total: 110), now: now)
        let first = try #require(reducer.takeTokenObservations().first)
        _ = try reducer.consume(message("turn/completed", params: """
        {"threadId":"main","turn":{"id":"turn","status":"completed","completedAt":\(now.timeIntervalSince1970)}}
        """), now: now)
        let later = now.addingTimeInterval(2 * 86400)
        reducer.maintain(loadedThreads: [], now: later)
        #expect(reducer.threads.isEmpty)
        _ = try reducer.reconcile(thread: thread(), turns: [turn()], now: later)
        _ = try reducer.consume(tokenMessage(total: 500), now: later)
        _ = try reducer.consume(tokenMessage(total: 520), now: later)
        let second = try #require(reducer.takeTokenObservations().first)
        #expect(second.sequence == 1)
        #expect(second.streamID != first.streamID)
        #expect(reducer.tokenTurns.values.first?.usage?.totalTokens == 30)
    }

    @Test func malformedApprovalCannotInventPersistentIdentity() throws {
        #expect(throws: DecodingError.self) {
            try TestFixtures.decode(ActivityInput.self, """
            {"id":1,"method":"item/commandExecution/requestApproval","params":{"threadId":"main","turnId":"turn","itemId":"command"}}
            """)
        }
    }
}

extension AppServerActivityTests {
    @Test func historyRecordingGapStartsNewTokenStreamWithoutCountingMissingUsage() throws {
        var reducer = try prepared()
        _ = try reducer.consume(tokenMessage(total: 100), now: now)
        _ = try reducer.consume(tokenMessage(total: 120), now: now)
        let first = try #require(reducer.takeTokenObservations().first)
        let persisted = try first.applying(to: nil)
        reducer.setTokenRecordingEnabled(false)
        _ = try reducer.consume(tokenMessage(total: 500), now: now)
        #expect(reducer.takeTokenObservations().isEmpty)
        let events = try reducer.consume(message("item/started", params: """
        {"threadId":"main","turnId":"turn","item":{"id":"tool","type":"commandExecution"}}
        """), now: now)
        #expect(!events.isEmpty)
        reducer.setTokenRecordingEnabled(true)
        _ = try reducer.consume(tokenMessage(total: 600), now: now)
        #expect(reducer.takeTokenObservations().isEmpty)
        _ = try reducer.consume(tokenMessage(total: 650), now: now)
        let resumed = try #require(reducer.takeTokenObservations().first)
        #expect(resumed.streamID != first.streamID)
        #expect(resumed.sequence == 1)
        let combined = try resumed.applying(to: persisted)
        #expect(combined.usage?.totalTokens == 70)
        #expect(try resumed.applying(to: combined) == combined)
    }
}
