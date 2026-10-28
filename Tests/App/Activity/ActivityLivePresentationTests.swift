import Foundation
import Testing

struct ActivityLivePresentationTests {
    private let now = TestFixtures.now

    private func message(_ method: String, _ fields: String = "", id: Int? = nil, turn: Bool = true) throws -> ActivityInput {
        let identity = id.map { "\"id\":\($0)," } ?? ""
        let turnField = turn ? #", "turnId":"turn-a""# : ""
        return try TestFixtures.decode(ActivityInput.self, """
        {\(identity)"method":"\(method)","params":{"threadId":"thread-a"\(turnField)\(fields.isEmpty ? "" : "," + fields)}}
        """)
    }

    private func prepared() throws -> AppServerActivityReducer {
        var reducer = AppServerActivityReducer()
        let thread = ActivityThread(id: "thread-a", status: ActivityThreadStatus(type: .active, activeFlags: []))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: .running)], now: now)
        _ = try reducer.consume(message("turn/started", #""turn":{"id":"turn-a","status":"inProgress"}"#), now: now)
        return reducer
    }

    private func summary(_ reducer: AppServerActivityReducer) throws -> ActivityLiveSummary {
        try #require(reducer.states.values.first?.presentation?.summary)
    }

    @Test func asyncQuestionMessageWaitsAfterItemCompletionAndActiveRefresh() throws {
        var reducer = try prepared()
        let item = """
        "item":{"id":"question-call","type":"agentMessage","phase":"final_answer","delivery":"async",
        "questions":[{"title":"Test question?","options":["Test option A","Test option B"]}]}
        """
        for method in ["item/started", "item/completed"] {
            #expect(try reducer.consume(message(method, item), now: now).isEmpty)
            #expect(try summary(reducer).current.key == "waiting-input")
        }
        _ = try reducer.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":[]}"#, turn: false), now: now.addingTimeInterval(1))
        _ = try reducer.consume(message("item/agentMessage/delta", #""itemId":"answer","delta":"Test response""#), now: now.addingTimeInterval(2))
        #expect(try summary(reducer).waiting?.since == now)
        #expect(try summary(reducer).current.key == "waiting-input")
        #expect(reducer.states.values.first?.isWaitingApproval == false)
    }

    private func userMessage(_ text: String, threadID: String = "thread-a", turnID: String = "turn-a") throws -> ActivityInput {
        try JSONDecoder().decode(ActivityInput.self, from: JSONSerialization.data(withJSONObject: [
            "method": "item/completed", "params": [
                "threadId": threadID, "turnId": turnID,
                "item": ["id": "reply", "type": "userMessage", "content": [["type": "text", "text": text]]]
            ]
        ]))
    }

    private func questionReply(_ itemID: String, index: Int) throws -> ActivityInput {
        let identity = try JSONSerialization.data(withJSONObject: ["request_user_input_async", itemID, index])
        let body = try JSONSerialization.data(withJSONObject: [["questionItemId": #require(String(data: identity, encoding: .utf8))]])
        return try userMessage("<send_user_message_question_reply>\n" + #require(String(data: body, encoding: .utf8)) + "\n</send_user_message_question_reply>")
    }

    @Test func asyncQuestionsResolveIndividuallyWithoutClearingOtherWaits() throws {
        var reducer = try prepared()
        for id in ["first", "second"] {
            _ = try reducer.consume(message("item/completed", """
            "item":{"id":"\(id)","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"},{"title":"Test question?"}]}
            """), now: now)
        }
        let progress = reducer.states.values.first?.lastProgressAt
        let unknown = try questionReply("unknown", index: 0)
        #expect(reducer.consume(unknown, now: now.addingTimeInterval(1)).isEmpty)
        for id in ["first", "second"] {
            let reply = try questionReply(id, index: 0)
            #expect(reply.params.item?.questionReplies == [.init(itemID: id, index: 0)])
            #expect(reducer.consume(reply, now: now.addingTimeInterval(2)).isEmpty)
            _ = reducer.consume(reply, now: now.addingTimeInterval(3))
            #expect(try summary(reducer).waiting?.since == now)
        }
        _ = try reducer.consume(questionReply("first", index: 1), now: now.addingTimeInterval(4))
        #expect(try summary(reducer).waiting != nil)
        _ = try reducer.consume(message("mcpServer/elicitation/request", #""mode":"form""#, id: 7), now: now.addingTimeInterval(5))
        _ = try reducer.consume(questionReply("second", index: 1), now: now.addingTimeInterval(6))
        #expect(try summary(reducer).current.key == "waiting-form")
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":7"#, turn: false), now: now.addingTimeInterval(7))
        #expect(try summary(reducer).waiting == nil)
        #expect(reducer.states.values.first?.lastProgressAt == progress)
        #expect(reducer.states.values.first?.isWaitingApproval == false)
    }

    @Test(arguments: [
        #""delivery":"async","questions":[]"#,
        #""delivery":"async","questions":null"#,
        #""questions":[{"title":"Test question?"}]"#
    ])
    func ordinaryAgentMessagesDoNotCreateQuestionWaits(fields: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", "\"item\":{\"id\":\"plain\",\"type\":\"agentMessage\",\(fields)}"), now: now)
        #expect(try summary(reducer).waiting == nil)
    }

    @Test(arguments: [
        "Test user message", "测试用户消息",
        #"Quoted: <send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"question\",0]"}]</send_user_message_question_reply>"#,
        "<send_user_message_question_reply>",
        "  <send_user_message_question_reply> 测试用户消息\n",
        "<send_user_message_question_reply>invalid</send_user_message_question_reply>",
        "<send_user_message_question_reply>[{}]</send_user_message_question_reply>",
        "<send_user_message_question_reply>[]</send_user_message_question_reply> 测试用户消息",
        #"<send_user_message_question_reply>[{"questionItemId":"[\"other_tool\",\"first\",0]"}]</send_user_message_question_reply>"#,
        #"<send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"\",0]"}]</send_user_message_question_reply>"#,
        #"<send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"first\",-1]"}]</send_user_message_question_reply>"#,
        #"<send_user_message_question_reply>[{"questionItemId":"[\"request_user_input_async\",\"first\",0.5]"}]</send_user_message_question_reply>"#,
        #"""
        <send_user_message_question_reply>[
            {"questionItemId":"[\"request_user_input_async\",\"first\",0]"},
            {"questionItemId":"invalid"}
        ]</send_user_message_question_reply>
        """#
    ])
    func ordinaryUserMessagesClearAsyncQuestionsAndAllowNewWaits(text: String) throws {
        var reducer = try prepared()
        for id in ["first", "second"] {
            _ = try reducer.consume(message("item/completed", """
            "item":{"id":"\(id)","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}
            """), now: now)
        }
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 9), now: now)
        _ = try reducer.consume(message("item/started", #""item":{"id":"cmd","type":"commandExecution"}"#), now: now.addingTimeInterval(1))
        #expect(try summary(reducer).current.key == "waiting-input")
        let progress = reducer.states.values.first?.lastProgressAt
        let reply = try userMessage(text)
        #expect(reply.params.item?.questionReplies == nil)
        #expect(reply.params.item?.affectsInputWait == true)
        #expect(reducer.consume(reply, now: now.addingTimeInterval(2)).isEmpty)
        #expect(try summary(reducer).waiting == nil)
        #expect(try summary(reducer).current.key == "command")
        #expect(reducer.states.values.first?.lastProgressAt == progress)
        #expect(reducer.states.values.first?.isWaitingApproval == false)

        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"third","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}
        """), now: now.addingTimeInterval(3))
        #expect(try summary(reducer).waiting?.since == now.addingTimeInterval(3))
        _ = try reducer.consume(questionReply("third", index: 0), now: now.addingTimeInterval(4))
        #expect(try summary(reducer).waiting == nil)
    }

    @Test(arguments: ["item/tool/requestUserInput", "item/commandExecution/requestApproval"], [
        "Test user message", "<send_user_message_question_reply> 测试用户消息"
    ])
    func ordinaryUserMessagesPreserveBlockingInputAndApproval(method: String, text: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", #""item":{"id":"question","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}"#), now: now)
        _ = try reducer.consume(message(method, #""itemId":"request","startedAtMs":1789459201000,"isBlocking":true"#, id: 7), now: now.addingTimeInterval(1))
        let approval = reducer.states.values.first?.isWaitingApproval
        _ = try reducer.consume(userMessage(text), now: now.addingTimeInterval(2))
        #expect(try summary(reducer).waiting?.since == now.addingTimeInterval(1))
        #expect(try summary(reducer).current.key == (method == "item/tool/requestUserInput" ? "waiting-input" : "waiting-approval"))
        #expect(try summary(reducer).hasBlockingInputRequest == (method == "item/tool/requestUserInput"))
        #expect(reducer.states.values.first?.isWaitingApproval == approval)
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":7"#, turn: false), now: now.addingTimeInterval(3))
        #expect(try summary(reducer).waiting == nil)
    }

    @Test(arguments: ["thread-a", "thread-b"])
    func ordinaryUserMessagesOnlyClearTheirOwnTurn(threadID: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", #""item":{"id":"question","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}"#), now: now)
        let otherThread = ActivityThread(id: threadID, status: ActivityThreadStatus(type: .active, activeFlags: []))
        _ = reducer.reconcile(thread: otherThread, turns: [ActivityTurn(id: "turn-b", status: .running)], now: now)
        _ = try reducer.consume(userMessage("Test user message", threadID: threadID, turnID: "turn-b"), now: now.addingTimeInterval(1))
        let key = ActivityTurnReference(threadID: "thread-a", turnID: "turn-a")
        #expect(reducer.states[key]?.presentation?.summary.waiting?.since == now)
        _ = try reducer.consume(userMessage("Test user message"), now: now.addingTimeInterval(2))
        #expect(reducer.states[key]?.presentation?.summary.waiting == nil)
    }

    @Test(arguments: [
        "[]",
        #"[{"questionItemId":"[\"request_user_input_async\",\"unknown\",0]"}]"#,
        #"[{"questionItemId":"[\"request_user_input_async\",\"question\",1]"}]"#
    ])
    func unmatchedQuestionRepliesDoNotClearAsyncQuestions(body: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", #""item":{"id":"question","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}"#), now: now)
        let reply = try userMessage("<send_user_message_question_reply>\(body)</send_user_message_question_reply>")
        #expect(reply.params.item?.questionReplies != nil)
        _ = reducer.consume(reply, now: now.addingTimeInterval(1))
        #expect(try summary(reducer).waiting?.since == now)
    }

    @Test func mixedContentQuestionRepliesOnlyResolveMatchingQuestions() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"question","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"},{"title":"Test question?"}]}
        """), now: now)
        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"other","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}
        """), now: now.addingTimeInterval(1))
        let reply = try message("item/completed", #"""
        "item":{"id":"reply","type":"userMessage","content":[
            {"type":"text","text":"Test user message"},
            {"type":"text",
             "text":"<send_user_message_question_reply>[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"question\\\",0]\"}]</send_user_message_question_reply>"},
            {"type":"text","text":"<send_user_message_question_reply>invalid</send_user_message_question_reply>"},
            {"type":"text",
             "text":"<send_user_message_question_reply>[{\"questionItemId\":\"[\\\"request_user_input_async\\\",\\\"question\\\",1]\"}]</send_user_message_question_reply>"}
        ]}
        """#)
        _ = reducer.consume(reply, now: now.addingTimeInterval(2))
        #expect(try summary(reducer).waiting?.since == now.addingTimeInterval(1))
        _ = try reducer.consume(questionReply("other", index: 0), now: now.addingTimeInterval(3))
        #expect(try summary(reducer).waiting == nil)
    }

    @Test(arguments: ["idle", "completed", "reconnect"])
    func asyncQuestionWaitsEndWithTheirTurnOrConnection(ending: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", #""item":{"id":"question","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}"#), now: now)
        #expect(try summary(reducer).waiting != nil)
        switch ending {
        case "idle":
            _ = try reducer.consume(message("thread/status/changed", #""status":{"type":"idle"}"#, turn: false), now: now.addingTimeInterval(1))
        case "completed":
            _ = try reducer.consume(message("turn/completed", #""turn":{"id":"turn-a","status":"completed"}"#), now: now.addingTimeInterval(1))
        default:
            reducer.reconnect()
        }
        #expect(reducer.states.values.first?.presentation?.summary.waiting == nil)
    }

    @Test func toolCompletionDoesNotMaskReasoningOrAnswerDeltas() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/started", #""item":{"id":"cmd","type":"commandExecution","commandActions":[{"type":"read"}]}"#), now: now)
        #expect(try summary(reducer).current.key == "command-read")
        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"cmd","type":"commandExecution","status":"completed","commandActions":[{"type":"read"}]}
        """), now: now.addingTimeInterval(1))
        #expect(try summary(reducer).current.key == "processing")
        let recent = try summary(reducer).recent
        #expect(recent?.label.key == "action-completed")
        let events = try reducer.consume(message("item/reasoning/summaryTextDelta", #""itemId":"reason","delta":"Test response""#), now: now.addingTimeInterval(2))
        #expect(events.isEmpty)
        #expect(try summary(reducer).current.key == "thinking")
        _ = try reducer.consume(message("item/started", #""item":{"id":"answer","type":"agentMessage","phase":"final_answer"}"#), now: now.addingTimeInterval(3))
        _ = try reducer.consume(message("item/agentMessage/delta", #""itemId":"answer","delta":"Test response""#), now: now.addingTimeInterval(4))
        #expect(try summary(reducer).current.key == "answering")
        #expect(try summary(reducer).recent == recent)
    }

    @Test func concurrentToolCompletionKeepsOtherToolAndNewerReplyVisible() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("turn/started"), at: now)
        try live.consume(message("item/started", #""item":{"id":"first","type":"fileChange"}"#), at: now)
        try live.consume(message("item/started", #""item":{"id":"second","type":"imageView"}"#), at: now.addingTimeInterval(1))
        #expect(live.summary.toolCount == 2)
        try live.consume(message("item/completed", #""item":{"id":"second","type":"imageView"}"#), at: now.addingTimeInterval(2))
        #expect(live.summary.current.key == "editing")
        try live.consume(message("item/agentMessage/delta", #""itemId":"answer""#), at: now.addingTimeInterval(3))
        try live.consume(message("item/completed", #""item":{"id":"first","type":"fileChange","status":"completed"}"#), at: now.addingTimeInterval(4))
        #expect(live.summary.current.key == "replying")
        #expect(live.summary.toolCount == 0)
    }

    @Test(arguments: [("commandExecution", "command")])
    func outputAfterReconnectRestoresToolPhaseWithoutInventingInventory(type: String, key: String) throws {
        var reducer = try prepared()
        reducer.reconnect()
        let thread = ActivityThread(id: "thread-a", status: ActivityThreadStatus(type: .active, activeFlags: []))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: .running)], now: now)
        let output = try message("item/\(type)/outputDelta", #""itemId":"tool","delta":"Test output""#)
        #expect(reducer.consume(output, now: now.addingTimeInterval(1)).isEmpty)
        #expect(try summary(reducer).current.key == key)
        #expect(try summary(reducer).toolCount == nil)
        _ = reducer.consume(output, now: now.addingTimeInterval(2))
        #expect(try summary(reducer).toolCount == nil)
        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"tool","type":"\(type)","status":"completed"}
        """), now: now.addingTimeInterval(3))
        #expect(try summary(reducer).current.key == "processing")
        #expect(try summary(reducer).toolCount == nil)
    }

    @Test func outputKeepsKnownActionsAndCompletesOnlyItsOwnItem() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("turn/started"), at: now)
        try live.consume(message("item/started", #""item":{"id":"cmd","type":"commandExecution","commandActions":[{"type":"read"}]}"#), at: now)
        try live.consume(message("item/commandExecution/outputDelta", #""itemId":"cmd""#), at: now.addingTimeInterval(1))
        #expect(live.summary.current.key == "command-read")
        try live.consume(message("item/started", #""item":{"id":"edit","type":"fileChange"}"#), at: now.addingTimeInterval(2))
        let beforeDeprecatedMessage = live.summary
        try live.consume(message("item/fileChange/outputDelta", #""itemId":"unknown""#), at: now.addingTimeInterval(3))
        #expect(live.summary == beforeDeprecatedMessage)
        #expect(live.summary.toolCount == 2)
        try live.consume(message("item/completed", #""item":{"id":"cmd","type":"commandExecution","status":"completed"}"#), at: now.addingTimeInterval(4))
        #expect(live.summary.current.key == "editing")
        #expect(live.summary.toolCount == 1)
        try live.consume(message("item/agentMessage/delta", #""itemId":"answer""#), at: now.addingTimeInterval(5))
        try live.consume(message("item/completed", #""item":{"id":"edit","type":"fileChange","status":"completed"}"#), at: now.addingTimeInterval(6))
        #expect(live.summary.current.key == "replying")
        #expect(live.summary.toolCount == 0)
    }

    @Test func recoveredToolOutputDoesNotClearUserWait() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":["waitingOnUserInput"]}"#, turn: false), at: now)
        try live.consume(message("item/commandExecution/outputDelta", #""itemId":"cmd""#), at: now.addingTimeInterval(1))
        #expect(live.summary.current.key == "waiting-input")
        #expect(live.summary.waiting?.since == now)
        try live.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":[]}"#, turn: false), at: now.addingTimeInterval(2))
        #expect(live.summary.current.key == "command")
    }

    @Test(arguments: ["completed", "failed", "declined"])
    func recentCommandOutcomesUseLocalizedActionDetails(status: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"cmd","type":"commandExecution","status":"\(status)","commandActions":[{"type":"search"},{"type":"read"},{"type":"read"}]}
        """), now: now)
        let recent = try #require(try summary(reducer).recent)
        #expect(recent.label.key == "action-" + status)
        #expect(recent.label.detail == String(localized: "activity.live.actions-read-search"))
        let action = String(localized: "activity.live.actions-read-search")
        let expected = switch status {
        case "completed": String(localized: "activity.live.action-completed", defaultValue: "\(action)")
        case "failed": String(localized: "activity.live.action-failed", defaultValue: "\(action)")
        default: String(localized: "activity.live.action-declined", defaultValue: "\(action)")
        }
        #expect(recent.label.text == expected)
        #expect(!recent.label.text.contains(" • "))
    }

    struct CommandPresentationCase {
        let command: String
        let started: ActivityLiveLabel
        let completionPrefix: String
    }

    @Test(arguments: [
        CommandPresentationCase(command: "python3 - <<'PY'\nprint('test')\nPY", started: .init("executing-tool", detail: "python3"), completionPrefix: "command-"),
        CommandPresentationCase(command: "git status; ls", started: .init("executing-tool", detail: "git, ls"), completionPrefix: "command-"),
        CommandPresentationCase(command: "git status; ls; pwd", started: .init("executing-tools", detail: "git, ls"), completionPrefix: "tools-"),
        CommandPresentationCase(command: "sed -n 1p a; sed -n 2p a; sed -n 3p a", started: .init("executing-tool", detail: "sed"), completionPrefix: "command-"),
        CommandPresentationCase(command: "sed -n 1p a; sed -n 2p a; git status", started: .init("executing-tool", detail: "sed, git"), completionPrefix: "command-"),
        CommandPresentationCase(command: "sed -n 1p a; sed -n 2p a; git status; ls", started: .init("executing-tools", detail: "sed, git"), completionPrefix: "tools-"),
        CommandPresentationCase(command: "\"$CMD\" status", started: .init("command"), completionPrefix: "command-"),
        CommandPresentationCase(command: "python3 'unfinished", started: .init("command"), completionPrefix: "command-")
    ], ["completed", "failed", "declined"])
    func parsedCommandsKeepStartedProgressAndCompletedConsistent(example: CommandPresentationCase, status: String) throws {
        var item: [String: Any] = [
            "id": "cmd", "type": "commandExecution", "commandActions": [["type": "unknown", "command": example.command]]
        ]
        func fields() throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["item": item])
            let text = try #require(String(data: data, encoding: .utf8))
            return String(text.dropFirst().dropLast())
        }
        var reducer = try prepared()
        _ = try reducer.consume(message("item/started", fields()), now: now)
        #expect(try summary(reducer).current == example.started)
        _ = try reducer.consume(message("item/commandExecution/outputDelta", #""itemId":"cmd""#), now: now.addingTimeInterval(1))
        #expect(try summary(reducer).current == example.started)
        item["status"] = status
        _ = try reducer.consume(message("item/completed", fields()), now: now.addingTimeInterval(2))
        #expect(try summary(reducer).recent?.label == ActivityLiveLabel(example.completionPrefix + status, detail: example.started.detail))
        #expect(try summary(reducer).current.key == "processing")
    }

    @Test func currentToolDetailsUseLocalizedTemplates() throws {
        let name = "server.tools"
        var reducer = try prepared()
        _ = try reducer.consume(message("item/started", """
        "item":{"id":"tool","type":"mcpToolCall","server":"server","tool":"tools","status":"inProgress","arguments":{"limit":1}}
        """), now: now)
        #expect(try summary(reducer).current.text == String(localized: "activity.live.calling-named-tool", defaultValue: "\(name)"))
        _ = try reducer.consume(message("item/completed", """
        "item":{"id":"tool","type":"mcpToolCall","server":"server","tool":"tools","status":"completed"}
        """), now: now.addingTimeInterval(1))
        #expect(try summary(reducer).recent?.label.detail == name)
    }

    @Test func modelChangePreservesRouteDetails() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("model/rerouted", #""fromModel":"model-a","toModel":"model-b""#), now: now)
        let label = try #require(try summary(reducer).recent?.label)
        let route = "model-a → model-b"
        #expect(label.text == String(localized: "activity.live.model-changed-detail", defaultValue: "\(route)"))
        #expect(label.key == "model-changed")
        #expect(label.detail == route)
    }

    @Test(arguments: ["spawnAgent", "wait", "sendInput", "future"], ["running", "errored"])
    func interruptedCollabUpdatesRecentEvent(tool: String, childStatus: String) throws {
        var reducer = try prepared()
        for (method, status) in [("item/started", "inProgress"), ("item/completed", "interrupted")] {
            _ = try reducer.consume(message(method, """
            "item":{"id":"collab","type":"collabAgentToolCall","tool":"\(tool)","status":"\(status)",
            "agentsStates":{"child":{"status":"\(childStatus)"}}}
            """), now: now)
        }
        let presentation = try summary(reducer)
        let detail = String(localized: ActivityDisplayFormat.agentAction(tool: tool).action)
        #expect(presentation.current.key == "processing")
        #expect(presentation.toolCount == 0)
        #expect(presentation.recent?.label == ActivityLiveLabel("action-interrupted", detail: detail))
        #expect(presentation.recent?.label.text == String(localized: "activity.live.action-interrupted", defaultValue: "\(detail)"))
        #expect(ActivityItem(id: "child", type: .subAgentActivity, kind: "interrupted").liveCompletionLabel?.key == "agent-interrupted")
    }

    @Test(arguments: [
        ("form", "waiting-form"), ("openai/form", "waiting-form"), ("openaiForm", "waiting-form"),
        ("url", "waiting-external"), ("future", "waiting-service")
    ])
    func elicitationWaitsAreSpecificAndEndByRequestID(mode: String, key: String) throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("mcpServer/elicitation/request", "\"mode\":\"\(mode)\"", id: 7), now: now)
        #expect(events.isEmpty)
        #expect(try summary(reducer).waiting?.label.key == key)
        #expect(try summary(reducer).waiting?.since == now)
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":7"#, turn: false), now: now.addingTimeInterval(4))
        #expect(try summary(reducer).waiting == nil)
        #expect(try summary(reducer).recent?.label.key == "request-ended")
    }

    @Test func unrelatedOutputAndResolvedRequestDoNotClearConcurrentWait() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("mcpServer/elicitation/request", #""mode":"form""#, id: 1), at: now)
        try live.consume(message("mcpServer/elicitation/request", #""mode":"url""#, id: 2), at: now.addingTimeInterval(1))
        try live.consume(message("item/agentMessage/delta", #""itemId":"answer""#), at: now.addingTimeInterval(2))
        try live.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), at: now.addingTimeInterval(3))
        #expect(live.summary.waiting?.label.key == "waiting-external")
        try live.consume(message("serverRequest/resolved", #""requestId":999"#, turn: false), at: now.addingTimeInterval(4))
        #expect(live.summary.waiting?.since == now.addingTimeInterval(1))
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func userInputWaitsEndByRequestIDWithoutChangingLifecycle(isBlocking: Bool?) throws {
        var reducer = try prepared()
        let before = try #require(reducer.states.values.first)
        let blocking = isBlocking.map { String($0) } ?? "null"
        let input = try message("item/tool/requestUserInput", """
        "itemId":"question","isBlocking":\(blocking),"autoResolutionMs":null,
        "questions":[{"id":"q","header":"Test header","question":"Test question?","isOther":true,"isSecret":true,"options":null}]
        """, id: 1)
        #expect(input.kind.category == .presentation)
        #expect(reducer.consume(input, now: now).isEmpty)
        #expect(try summary(reducer).current.key == "waiting-input")
        #expect(try summary(reducer).current.detail == nil)
        #expect(try summary(reducer).waiting?.isBlocking == isBlocking)
        #expect(try summary(reducer).hasBlockingInputRequest == (isBlocking == true))
        #expect(try summary(reducer).waiting?.since == now)
        #expect(reducer.consume(input, now: now.addingTimeInterval(1)).isEmpty)
        #expect(try summary(reducer).waiting?.since == now)
        let state = try #require(reducer.states.values.first)
        #expect(state.isWaitingApproval == before.isWaitingApproval)
        #expect(state.pendingApprovals.isEmpty)
        #expect(state.lastProgressAt == before.lastProgressAt)
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":99"#, turn: false), now: now.addingTimeInterval(2))
        #expect(try summary(reducer).waiting != nil)
        #expect(try reducer.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), now: now.addingTimeInterval(3)).isEmpty)
        #expect(try summary(reducer).waiting == nil)
        #expect(try summary(reducer).hasBlockingInputRequest == false)
        #expect(try summary(reducer).recent?.label.key == "request-ended")
    }

    @Test func earlierAsyncWaitDoesNotMaskBlockingRequests() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/completed", #""item":{"id":"async","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}"#), now: now)
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 1), now: now.addingTimeInterval(1))
        for id in [2, 3] {
            _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: id), now: now.addingTimeInterval(Double(id)))
        }
        #expect(try summary(reducer).waiting?.since == now)
        #expect(try summary(reducer).waiting?.isBlocking == false)
        #expect(try summary(reducer).hasBlockingInputRequest == true)
        for id in [99, 1, 2] {
            _ = try reducer.consume(message("serverRequest/resolved", "\"requestId\":\(id)", turn: false), now: now.addingTimeInterval(4))
            #expect(try summary(reducer).hasBlockingInputRequest == true)
        }
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":3"#, turn: false), now: now.addingTimeInterval(5))
        #expect(try summary(reducer).hasBlockingInputRequest == false)
        #expect(try summary(reducer).waiting?.since == now)
    }

    @Test(arguments: ["active", "idle", "completed", "failed", "interrupted", "reconnect"])
    func blockingInputEndsWithAuthoritativeStateOrConnection(ending: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), now: now)
        #expect(try summary(reducer).hasBlockingInputRequest == true)
        switch ending {
        case "active", "idle":
            _ = try reducer.consume(message("thread/status/changed", "\"status\":{\"type\":\"\(ending)\",\"activeFlags\":[]}", turn: false), now: now.addingTimeInterval(1))
        case "reconnect":
            reducer.reconnect()
        default:
            _ = try reducer.consume(message("turn/completed", "\"turn\":{\"id\":\"turn-a\",\"status\":\"\(ending)\"}"), now: now.addingTimeInterval(1))
        }
        #expect(reducer.states.values.first?.presentation?.summary.hasBlockingInputRequest != true)
    }

    @Test func nonblockingQuestionsSurviveActiveStatusAndResolveIndependently() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 1), now: now)
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 2), now: now.addingTimeInterval(1))
        _ = try reducer.consume(message("item/agentMessage/delta", #""itemId":"answer""#), now: now.addingTimeInterval(2))
        _ = try reducer.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":[]}"#, turn: false), now: now.addingTimeInterval(3))
        let thread = ActivityThread(id: "thread-a", status: ActivityThreadStatus(type: .active, activeFlags: []))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: .running)], now: now.addingTimeInterval(4))
        #expect(try summary(reducer).waiting?.since == now)
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), now: now.addingTimeInterval(5))
        #expect(try summary(reducer).waiting?.since == now.addingTimeInterval(1))
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":2"#, turn: false), now: now.addingTimeInterval(6))
        #expect(try summary(reducer).waiting == nil)
        #expect(try summary(reducer).current.key == "replying")
    }

    @Test func activeStatusClearsBlockingRequestsButKeepsNonblockingQuestions() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), at: now)
        try live.consume(message("mcpServer/elicitation/request", #""mode":"form""#, id: 2), at: now)
        try live.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 3), at: now.addingTimeInterval(1))
        live.reconcile(status: ActivityThreadStatus(type: .active, activeFlags: []))
        #expect(live.requests.count == 1)
        #expect(live.summary.waiting?.since == now.addingTimeInterval(1))
        try live.consume(message("serverRequest/resolved", #""requestId":3"#, turn: false), at: now.addingTimeInterval(2))
        #expect(live.summary.waiting == nil)
    }

    @Test(arguments: ["mcpServer/elicitation/request", "item/tool/requestUserInput"])
    func uncorrelatedInputNeverBecomesWaiting(method: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message(method, #""mode":"url","isBlocking":false"#, id: 1, turn: false), now: now)
        #expect(try summary(reducer).waiting == nil)
        _ = try reducer.consume(message(method, #""mode":"url","isBlocking":false"#), now: now)
        #expect(try summary(reducer).waiting == nil)
    }

    @Test func reconnectDropsUnverifiablePhasesAndWaitingDuration() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":["waitingOnUserInput"]}"#, turn: false), now: now)
        reducer.reconnect()
        #expect(reducer.states.values.first?.presentation == nil)
        let thread = ActivityThread(id: "thread-a", status: ActivityThreadStatus(type: .active, activeFlags: [.waitingOnUserInput]))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: .running)], now: now.addingTimeInterval(12))
        #expect(try summary(reducer).waiting?.label.key == "waiting-input")
        #expect(try summary(reducer).waiting?.since == nil)
        #expect(try summary(reducer).toolCount == nil)
    }

    @Test(arguments: ["approved", "denied", "timedOut", "aborted"])
    func automaticReviewHasNoPresentationOrHistory(status: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/autoApprovalReview/started", #""reviewId":"review","review":{"status":"inProgress"}"#), now: now)
        #expect(try summary(reducer).current.key == "processing")
        #expect(try summary(reducer).waiting == nil)
        let events = try reducer.consume(
            message("item/autoApprovalReview/completed", "\"reviewId\":\"review\",\"review\":{\"status\":\"\(status)\"}"),
            now: now.addingTimeInterval(1)
        )
        #expect(events.isEmpty)
        #expect(try summary(reducer).current.key == "processing")
        #expect(try summary(reducer).recent == nil)
    }

    @Test func presentationEventsNeverProduceHistoricalRecords() throws {
        var reducer = try prepared()
        let messages = try [
            message("turn/plan/updated", #""plan":[{"step":"Test plan step","status":"completed"}]"#),
            message("turn/diff/updated", #""diff":"Test diff""#),
            message("model/rerouted", #""fromModel":"old","toModel":"new""#),
            message("modelProvider/authRecoveryStarted"),
            message("modelProvider/authRecoveryCompleted"),
            message("model/safetyBuffering/updated", #""showBufferingUi":true"#),
            message("hook/started", #""run":{"id":"hook","status":"running","executionMode":"sync"}"#)
        ]
        for notification in messages {
            #expect(notification.kind.category == .presentation)
            #expect(reducer.consume(notification, now: now).isEmpty)
        }
        #expect(try summary(reducer).planCompleted == 1)
        #expect(try summary(reducer).planTotal == 1)
        #expect(try summary(reducer).waiting == nil)
        #expect(reducer.tokenUsageTurns.isEmpty)
    }

    @Test(arguments: [
        ("thread/status/changed", false), ("mcpServer/elicitation/request", false),
        ("item/tool/requestUserInput", false), ("item/tool/requestUserInput", true), ("item/completed", false)
    ])
    func displayWaitingDoesNotChangeApprovalOrProtectionState(method: String, isBlocking: Bool) throws {
        let event = TestFixtures.event()
        var task = try ActivityTask(
            displayID: UUID(),
            key: #require(ActivityTaskKey(event: event)),
            event: event,
            state: .running,
            startedAt: now,
            progressGeneration: 0
        )
        var reducer = try prepared()
        _ = try reducer.consume(message(method, """
        "status":{"type":"active","activeFlags":["waitingOnUserInput"]},"isBlocking":\(isBlocking),
        "item":{"id":"question","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}
        """, id: 1), now: now)
        let state = try #require(reducer.states.values.first)
        task.mergeExecutionLifecycle(state, owner: ActivityExecutionKey(agentThreadID: nil, turnID: "turn-a"))
        let snapshot = ActivitySnapshot(waitingTasks: [], runningTasks: [task.snapshot], recentCompletions: [], recentTerminations: [])
        #expect(task.state == .running)
        #expect(snapshot.waitingCount == 0)
        #expect(snapshot.panelWaitingTasks.count == 1)
        #expect(snapshot.panelRunningTasks.isEmpty)
        #expect(snapshot.primaryActivity == .running(task.snapshot))
        #expect(snapshot.panelPrimaryActivity == .waiting(task.snapshot))
        #expect(snapshot.keepAliveTaskIDs.waiting == (isBlocking ? [task.displayID] : []))
        #expect(snapshot.keepAliveTaskIDs.running == (isBlocking ? [] : [task.displayID]))
        let summary = ActivityDisplayFormat.liveSummaryComponents(for: task.snapshot, now: now)
        #expect(summary.count == 2)
        #expect(summary.first == ActivityLiveLabel("elapsed-running").text + " " + CodexDurationFormat.activityText(for: 0))
        #expect(summary.last == ActivityLiveLabel("elapsed-waiting").text + " " + CodexDurationFormat.activityText(for: 0))
    }

    @Test(arguments: [false, true])
    func keepAliveFindsBlockingInputAcrossExecutions(blockingInChild: Bool) throws {
        let event = TestFixtures.event()
        var task = try ActivityTask(
            displayID: UUID(), key: #require(ActivityTaskKey(event: event)), event: event,
            state: .running, startedAt: now, progressGeneration: 0
        )
        var nonblocking = ActivityLivePresentation()
        try nonblocking.consume(message("item/completed", #""item":{"id":"async","type":"agentMessage","delivery":"async","questions":[{"title":"Test question?"}]}"#), at: now)
        var blocking = ActivityLivePresentation()
        try blocking.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), at: now.addingTimeInterval(1))
        let rootOwner = ActivityExecutionKey(agentThreadID: nil, turnID: "turn-a")
        let childOwner = ActivityExecutionKey(agentThreadID: "child", turnID: "child-turn")
        task.executions[rootOwner] = ActivityExecution(presentation: blockingInChild ? nonblocking : blocking)
        task.executions[childOwner] = ActivityExecution(presentation: blockingInChild ? blocking : nonblocking)
        let waiting = task.snapshot
        #expect(waiting.presentation?.waiting?.isBlocking == false)
        #expect(waiting.presentation?.hasBlockingInputRequest == true)
        let snapshot = ActivitySnapshot(waitingTasks: [], runningTasks: [waiting], recentCompletions: [], recentTerminations: [])
        #expect(snapshot.keepAliveTaskIDs.waiting == [task.displayID])
        #expect(snapshot.keepAliveTaskIDs.running.isEmpty)

        let concurrent = ActivityTaskSnapshot(
            id: UUID(), projectName: nil, modelName: nil, effort: nil,
            startedAt: now, stateChangedAt: now, activeSubagentCount: nil
        )
        let mixed = ActivitySnapshot(waitingTasks: [], runningTasks: [waiting, concurrent], recentCompletions: [], recentTerminations: [])
        #expect(mixed.keepAliveTaskIDs.running == [concurrent.id])
        #expect(mixed.keepAliveTaskIDs.waiting == [task.displayID])
        let approval = ActivitySnapshot(waitingTasks: [concurrent], runningTasks: [waiting], recentCompletions: [], recentTerminations: [])
        #expect(approval.keepAliveTaskIDs.running.isEmpty)
        #expect(approval.keepAliveTaskIDs.waiting == [concurrent.id, task.displayID])

        task.finishExecution(blockingInChild ? childOwner : rootOwner, at: now.addingTimeInterval(2))
        #expect(task.snapshot.presentation?.waiting != nil)
        #expect(task.snapshot.presentation?.hasBlockingInputRequest == false)
        let resumed = ActivitySnapshot(waitingTasks: [], runningTasks: [task.snapshot], recentCompletions: [], recentTerminations: [])
        #expect(resumed.keepAliveTaskIDs.running == [task.displayID])
        #expect(resumed.keepAliveTaskIDs.waiting.isEmpty)
    }

    @Test func authoritativeIdleClearsRequestsWithoutInventingApproval() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("mcpServer/elicitation/request", #""mode":"form""#, id: 1), at: now)
        try live.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 2), at: now)
        live.reconcile(status: ActivityThreadStatus(type: .idle))
        #expect(live.summary.waiting == nil)
        #expect(live.summary.recent == nil)
    }

    @Test func temporaryOperationsEndWithoutClearingOtherOperations() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("modelProvider/authRecoveryStarted"), at: now)
        try live.consume(message("model/safetyBuffering/updated", #""showBufferingUi":true"#), at: now.addingTimeInterval(1))
        #expect(live.summary.current.key == "buffering")
        try live.consume(message("model/safetyBuffering/updated", #""showBufferingUi":false"#), at: now.addingTimeInterval(2))
        #expect(live.summary.current.key == "recovering-auth")
        try live.consume(message("modelProvider/authRecoveryCompleted"), at: now.addingTimeInterval(3))
        #expect(live.summary.current.key == "processing")
        #expect(live.summary.recent?.label.key == "auth-recovery-ended")
        #expect(live.summary.waiting == nil)
    }

    @Test func childWaitSurvivesRootOutputUntilChildLifecycleResolvesIt() throws {
        let event = TestFixtures.event()
        var task = try ActivityTask(
            displayID: UUID(),
            key: #require(ActivityTaskKey(event: event)),
            event: event,
            state: .running,
            startedAt: now,
            progressGeneration: 0
        )
        var root = ActivityLivePresentation()
        try root.consume(message("item/agentMessage/delta", #""itemId":"answer""#), at: now.addingTimeInterval(4))
        var child = ActivityLivePresentation()
        try child.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":["waitingOnUserInput"]}"#, turn: false), at: now)
        task.executions[ActivityExecutionKey(agentThreadID: nil, turnID: "turn-a")] = ActivityExecution(presentation: root)
        let childOwner = ActivityExecutionKey(agentThreadID: "child", turnID: "child-turn")
        task.executions[childOwner] = ActivityExecution(presentation: child)
        #expect(task.snapshot.presentation?.waiting?.since == now)
        #expect(task.snapshot.presentation?.current.key == "waiting-input")
        try child.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":[]}"#, turn: false), at: now.addingTimeInterval(5))
        task.executions[childOwner]?.presentation = child
        #expect(task.snapshot.presentation?.waiting == nil)
        #expect(task.snapshot.presentation?.current.key == "replying")
    }

    @Test func failedTurnKeepsItsOutcomeWithoutChangingTerminalPolicy() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 1), now: now)
        let events = try reducer.consume(message("turn/completed", #""turn":{"id":"turn-a","status":"failed"}"#), now: now)
        let state = try #require(reducer.states.values.first)
        #expect(state.turnStatus == .failed)
        #expect(state.presentation == nil)
        #expect(events.first?.eventKind == .turnAborted)
        #expect(events.first?.context?.turnStatus == .failed)
        let event = TestFixtures.event()
        var task = try ActivityTask(
            displayID: UUID(),
            key: #require(ActivityTaskKey(event: event)),
            event: event,
            state: .running,
            startedAt: now,
            progressGeneration: 0
        )
        ActivityTaskGraph.mergeLifecycleBackfill(from: state, into: &task)
        #expect(task.terminalFailed)
    }

    @Test func reconnectDiscardsPendingNonblockingQuestions() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 1), now: now)
        reducer.reconnect()
        let thread = ActivityThread(id: "thread-a", status: ActivityThreadStatus(type: .active, activeFlags: []))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: .running)], now: now.addingTimeInterval(1))
        #expect(try summary(reducer).waiting == nil)
    }

    @Test func resolvedRequestDoesNotClearThreadInputWait() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":["waitingOnUserInput"]}"#, turn: false), at: now)
        try live.consume(message("mcpServer/elicitation/request", #""mode":"form""#, id: 1), at: now)
        try live.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), at: now.addingTimeInterval(2))
        #expect(live.summary.waiting?.label.key == "waiting-input")
        #expect(live.summary.waiting?.since == now)
        try live.consume(message("thread/status/changed", #""status":{"type":"active","activeFlags":[]}"#, turn: false), at: now.addingTimeInterval(3))
        #expect(live.summary.waiting == nil)
    }

    @Test func verificationRequestDoesNotCreateWaitingOrRecentEvent() throws {
        var reducer = try prepared()
        let before = try summary(reducer)
        #expect(try reducer.consume(message("mcpServer/elicitation/request", #""mode":"openai/userVerification""#, id: 1), now: now).isEmpty)
        _ = try reducer.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), now: now)
        #expect(try summary(reducer) == before)
    }

    @Test(arguments: ["item/started", "item/completed"])
    func planItemsDoNotChangePresentationOrProgress(method: String) throws {
        var reducer = try prepared()
        let before = try summary(reducer)
        let progress = reducer.states.values.first?.lastProgressAt
        #expect(try reducer.consume(message(method, #""item":{"id":"plan","type":"plan"}"#), now: now.addingTimeInterval(10)).isEmpty)
        #expect(try summary(reducer) == before)
        #expect(reducer.states.values.first?.lastProgressAt == progress)
    }
}
