import Foundation
import Testing

struct ActivityLivePresentationTests {
    private let now = TestFixtures.now

    private func message(_ method: String, _ fields: String = "", id: Int? = nil, turn: Bool = true) throws -> ActivityNotification {
        let identity = id.map { "\"id\":\($0)," } ?? ""
        let turnField = turn ? #", "turnId":"turn-a""# : ""
        return try TestFixtures.decode(ActivityNotification.self, """
        {\(identity)"method":"\(method)","params":{"threadId":"session-a"\(turnField)\(fields.isEmpty ? "" : "," + fields)}}
        """)
    }

    private func prepared() throws -> AppServerActivityReducer {
        var reducer = AppServerActivityReducer()
        let thread = ActivityThread(id: "session-a", status: ActivityThreadStatus(type: "active", activeFlags: []))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: "inProgress")], reviewer: .user, now: now)
        _ = try reducer.consume(message("turn/started", #""turn":{"id":"turn-a","status":"inProgress"}"#), now: now)
        return reducer
    }

    private func summary(_ reducer: AppServerActivityReducer) throws -> ActivityLiveSummary {
        try #require(reducer.states.values.first?.presentation?.summary)
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
        let events = try reducer.consume(message("item/reasoning/summaryTextDelta", #""itemId":"reason","delta":"private text""#), now: now.addingTimeInterval(2))
        #expect(events.isEmpty)
        #expect(try summary(reducer).current.key == "thinking")
        _ = try reducer.consume(message("item/started", #""item":{"id":"answer","type":"agentMessage","phase":"final_answer"}"#), now: now.addingTimeInterval(3))
        _ = try reducer.consume(message("item/agentMessage/delta", #""itemId":"answer","delta":"private answer""#), now: now.addingTimeInterval(4))
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

    @Test(arguments: [("commandExecution", "command"), ("fileChange", "editing")])
    func outputAfterReconnectRestoresToolPhaseWithoutInventingInventory(type: String, key: String) throws {
        var reducer = try prepared()
        reducer.reconnect(now: now)
        let thread = ActivityThread(id: "session-a", status: ActivityThreadStatus(type: "active", activeFlags: []))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: "inProgress")], reviewer: .user, now: now)
        let output = try message("item/\(type)/outputDelta", #""itemId":"tool","delta":"output""#)
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
        try live.consume(message("item/fileChange/outputDelta", #""itemId":"edit""#), at: now.addingTimeInterval(2))
        try live.consume(message("item/fileChange/outputDelta", #""itemId":"edit""#), at: now.addingTimeInterval(3))
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
        try live.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), at: now)
        try live.consume(message("item/commandExecution/outputDelta", #""itemId":"cmd""#), at: now.addingTimeInterval(1))
        #expect(live.summary.current.key == "waiting-input")
        #expect(live.summary.waiting?.since == now)
        try live.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), at: now.addingTimeInterval(2))
        #expect(live.summary.current.key == "command")
    }

    @Test(arguments: [
        (["read"], "command-read"), (["listFiles"], "command-listFiles"), (["search"], "command-search"),
        (["search", "read", "read"], "command-read-search"), (["search", "listFiles"], "command-listFiles-search"),
        (["listFiles", "read"], "command-read-listFiles"), (["search", "listFiles", "read"], "command-read-listFiles-search"),
        (["read", "unknown"], "command"), (["future"], "command"), ([], "command")
    ])
    func commandActionsUseServerClassification(actions: [String], key: String) {
        let item = ActivityItem(id: "cmd", type: "commandExecution", commandActions: actions.map { .init(type: $0) })
        #expect(item.liveLabel?.key == key)
        if actions.contains("read"), actions.contains("unknown") {
            #expect(item.liveLabel?.detail != nil)
        }
    }

    @Test(arguments: [
        (["search", "read"], "actions-read-search"),
        (["read", "search"], "actions-read-search"),
        (["search", "unknown", "read", "read"], "actions-read-search"),
        (["search", "listFiles", "read", "listFiles"], "actions-read-listFiles-search"),
        ([], nil), (["unknown", "future"], nil)
    ] as [([String], String?)])
    func commandCompletionLocalizesAndOrdersKnownActions(actions: [String], detailKey: String?) {
        let item = ActivityItem(
            id: "cmd", type: "commandExecution", status: "failed",
            commandActions: actions.map { .init(type: $0) }
        )
        #expect(item.liveCompletionLabel?.key == (detailKey == nil ? "tool-failed" : "action-failed"))
        #expect(item.liveCompletionLabel?.detail == detailKey.map { ActivityLiveLabel($0).text })
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

    @Test(arguments: ["mcpToolCall", "dynamicToolCall"])
    func completionPreservesActualToolNames(type: String) {
        let item = ActivityItem(
            id: "tool", type: type, status: "failed", tool: "search/read",
            commandActions: [.init(type: "read")]
        )
        #expect(item.liveCompletionLabel?.key == "tool-failed")
        #expect(item.liveCompletionLabel?.detail == "search/read")
        let name = "search/read"
        #expect(item.liveCompletionLabel?.text == String(localized: "activity.live.named-tool-failed", defaultValue: "\(name)"))
    }

    @Test func currentToolDetailsUseLocalizedTemplates() throws {
        let name = "web.search"
        let tool = ActivityItem(id: "tool", type: "mcpToolCall", tool: name)
        #expect(tool.liveLabel?.text == String(localized: "activity.live.calling-named-tool", defaultValue: "\(name)"))
        let command = ActivityItem(
            id: "cmd", type: "commandExecution", commandActions: ["search", "unknown", "read"].map { .init(type: $0) }
        )
        let label = try #require(command.liveLabel)
        let detail = try #require(label.detail)
        #expect(label.text == String(localized: "activity.live.command-with-actions", defaultValue: "\(detail)"))
        #expect(!label.text.contains(" • "))
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

    @Test(arguments: ["tool-completed", "tool-failed", "tool-declined", "calling-tool", "command", "model-changed"])
    func missingDetailsKeepStandaloneLabels(key: String) {
        #expect(ActivityLiveLabel(key).text == ActivityLiveLabel(key).localizedText)
        #expect(ActivityLiveLabel(key, detail: "").text == ActivityLiveLabel(key).localizedText)
    }

    @Test(arguments: [
        ("spawnAgent", ("agent-starting", "activity.action.start-subagent")),
        ("sendInput", ("agent-assigning", "activity.action.assign-subagent")),
        ("followupTask", ("agent-assigning", "activity.action.assign-subagent")),
        ("sendMessage", ("agent-contacting", "activity.action.message-subagent")),
        ("resumeAgent", ("agent-resuming", "activity.action.resume-subagent")),
        ("wait", ("agent-waiting", "activity.action.wait-subagent")),
        ("interruptAgent", ("agent-interrupting", "activity.action.interrupt-subagent")),
        ("closeAgent", ("agent-closing", "activity.action.close-subagent")),
        ("listAgents", ("agent-querying", "activity.action.query-subagent")),
        ("future", ("agent-coordinating", "activity.action.coordinate-subagents"))
    ] as [(String, (String, LocalizedStringResource))], ["completed", "failed", "declined"])
    func subagentOperationOutcomesDescribeTheCall(
        operation: (tool: String, expected: (statusKey: String, action: LocalizedStringResource)), status: String
    ) {
        let item = ActivityItem(
            id: "agent", type: "collabAgentToolCall", status: status, tool: operation.tool,
            agentsStates: ["child": .init(status: "running")]
        )
        #expect(item.liveLabel?.key == operation.expected.statusKey)
        #expect(item.liveCompletionLabel?.key == "action-" + status)
        #expect(item.liveCompletionLabel?.detail == String(localized: operation.expected.action))
        #expect(ActivityDisplayFormat.toolActionText(itemType: item.type, toolName: operation.tool) == item.liveCompletionLabel?.detail)
    }

    @Test(arguments: [
        ("commandExecution", "activity.action.command"), ("fileChange", "activity.action.edit-files"),
        ("webSearch", "activity.action.search-web"), ("imageView", "activity.action.view-image"),
        ("imageGeneration", "activity.action.generate-image"), ("sleep", "activity.action.wait-timer"),
        ("mcpToolCall", "activity.action.call-tool"), ("dynamicToolCall", "activity.action.call-tool"),
        ("collabAgentToolCall", "activity.action.coordinate-subagents")
    ] as [(String, LocalizedStringResource)])
    func namelessToolTypesHaveReadableFallbacks(type: String, action: LocalizedStringResource) {
        #expect(ActivityDisplayFormat.toolActionText(itemType: type, toolName: nil) == String(localized: action))
        #expect(ActivityDisplayFormat.toolActionText(itemType: type, toolName: "  ") == String(localized: action))
    }

    @Test(arguments: ["mcpToolCall", "dynamicToolCall", "future", nil] as [String?], ["search/read", "spawnAgent", "commandExecution"])
    func actualToolNamesAreNeverClassifiedByTheirSpelling(type: String?, tool: String) {
        #expect(ActivityDisplayFormat.toolActionText(itemType: type, toolName: tool) == tool)
    }

    @Test func unknownUnnamedToolsDoNotExposeInternalTypes() {
        #expect(ActivityDisplayFormat.toolActionText(itemType: "futureInternalType", toolName: nil) == nil)
        #expect(ActivityDisplayFormat.toolActionText(itemType: nil, toolName: nil) == nil)
    }

    @Test(arguments: [
        ("form", "waiting-form"), ("openai/form", "waiting-form"), ("openaiForm", "waiting-form"),
        ("url", "waiting-external"), ("openai/userVerification", "waiting-verification"), ("future", "waiting-service")
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
        try live.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), at: now)
        try live.consume(message("mcpServer/elicitation/request", #""mode":"url""#, id: 2), at: now.addingTimeInterval(1))
        try live.consume(message("item/agentMessage/delta", #""itemId":"answer""#), at: now.addingTimeInterval(2))
        try live.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), at: now.addingTimeInterval(3))
        #expect(live.summary.waiting?.label.key == "waiting-external")
        try live.consume(message("serverRequest/resolved", #""requestId":999"#, turn: false), at: now.addingTimeInterval(4))
        #expect(live.summary.waiting?.since == now.addingTimeInterval(1))
    }

    @Test func nonblockingInputAndUncorrelatedElicitationNeverBecomeWaiting() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":false"#, id: 1), now: now)
        #expect(try summary(reducer).waiting == nil)
        _ = try reducer.consume(message("mcpServer/elicitation/request", #""mode":"url""#, id: 2, turn: false), now: now)
        #expect(try summary(reducer).waiting == nil)
    }

    @Test func reconnectDropsUnverifiablePhasesAndWaitingDuration() throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), now: now)
        reducer.reconnect(now: now.addingTimeInterval(10))
        #expect(reducer.states.values.first?.presentation == nil)
        let thread = ActivityThread(id: "session-a", status: ActivityThreadStatus(type: "active", activeFlags: ["waitingOnUserInput"]))
        _ = reducer.reconcile(thread: thread, turns: [ActivityTurn(id: "turn-a", status: "inProgress")], reviewer: .user, now: now.addingTimeInterval(12))
        #expect(try summary(reducer).waiting?.label.key == "waiting-input")
        #expect(try summary(reducer).waiting?.since == nil)
        #expect(try summary(reducer).toolCount == nil)
    }

    @Test(arguments: ["approved", "denied", "timedOut", "aborted"])
    func automaticReviewIsNotUserWaitingAndCompletes(status: String) throws {
        var reducer = try prepared()
        _ = try reducer.consume(message("item/autoApprovalReview/started", #""reviewId":"review","review":{"status":"inProgress"}"#), now: now)
        #expect(try summary(reducer).current.key == "auto-approval")
        #expect(try summary(reducer).waiting == nil)
        let events = try reducer.consume(message("item/autoApprovalReview/completed", "\"reviewId\":\"review\",\"review\":{\"status\":\"\(status)\"}"), now: now.addingTimeInterval(1))
        #expect(events.isEmpty)
        #expect(try summary(reducer).current.key == "processing")
        #expect(try summary(reducer).recent?.label.key.hasPrefix("approval-") == true)
    }

    @Test func presentationEventsNeverProduceHistoricalRecords() throws {
        var reducer = try prepared()
        let messages = try [
            message("turn/plan/updated", #""plan":[{"step":"private","status":"completed"}]"#),
            message("turn/diff/updated", #""diff":"private diff""#),
            message("mcpServer/startupStatus/updated", #""name":"test","status":"starting""#),
            message("model/rerouted", #""fromModel":"old","toModel":"new""#),
            message("modelProvider/authRecoveryStarted"),
            message("modelProvider/authRecoveryCompleted"),
            message("model/safetyBuffering/updated", #""showBufferingUi":true"#),
            message("hook/started", #""run":{"id":"hook","status":"running","executionMode":"sync"}"#)
        ]
        for notification in messages {
            #expect(ActivityNotification.category(for: notification.method) == .presentation)
            #expect(reducer.consume(notification, now: now).isEmpty)
        }
        #expect(try summary(reducer).planCompleted == 1)
        #expect(try summary(reducer).planTotal == 1)
        #expect(try summary(reducer).waiting == nil)
        #expect(reducer.tokenTurns.isEmpty)
    }

    @Test(arguments: ["completed", "failed", "declined", "unknown"])
    func toolOutcomeDoesNotAssumeSuccess(status: String) {
        let item = ActivityItem(id: "image", type: "imageGeneration", status: status)
        #expect(item.liveCompletionLabel?.key == (status == "unknown" ? nil : "image-" + status))
    }

    @Test func displayWaitingDoesNotChangeApprovalOrProtectionState() throws {
        let event = TestFixtures.event()
        var task = ActivityTask(
            displayID: UUID(),
            key: ActivityTaskKey(event: event),
            event: event,
            state: .running,
            startedAt: now,
            progressGeneration: 0
        )
        var reducer = try prepared()
        _ = try reducer.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), now: now)
        let state = try #require(reducer.states.values.first)
        task.mergeExecutionLifecycle(state, owner: ActivityExecutionKey(agentID: nil, turnID: "turn-a"))
        let snapshot = ActivitySnapshot(waitingTasks: [], runningTasks: [task.snapshot], recentCompletions: [], recentTerminations: [])
        #expect(task.state == .running)
        #expect(snapshot.waitingCount == 0)
        #expect(snapshot.panelWaitingTasks.count == 1)
        #expect(snapshot.panelRunningTasks.isEmpty)
        #expect(snapshot.primaryActivity == .running(task.snapshot))
        #expect(snapshot.panelPrimaryActivity == .waiting(task.snapshot))
        let summary = ActivityDisplayFormat.liveSummaryComponents(for: task.snapshot, now: now)
        #expect(summary.count == 2)
        #expect(summary.first == ActivityLiveLabel("elapsed-running").text + " " + CodexDurationFormat.activityText(for: 0))
        #expect(summary.last == ActivityLiveLabel("elapsed-waiting").text + " " + CodexDurationFormat.activityText(for: 0))
    }

    @Test func authoritativeIdleClearsRequestsWithoutInventingApproval() throws {
        var live = ActivityLivePresentation()
        try live.consume(message("mcpServer/elicitation/request", #""mode":"form""#, id: 1), at: now)
        live.reconcile(status: ActivityThreadStatus(type: "idle"))
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
        var task = ActivityTask(
            displayID: UUID(),
            key: ActivityTaskKey(event: event),
            event: event,
            state: .running,
            startedAt: now,
            progressGeneration: 0
        )
        var root = ActivityLivePresentation()
        try root.consume(message("item/agentMessage/delta", #""itemId":"answer""#), at: now.addingTimeInterval(4))
        var child = ActivityLivePresentation()
        try child.consume(message("item/tool/requestUserInput", #""isBlocking":true"#, id: 1), at: now)
        task.executions[ActivityExecutionKey(agentID: nil, turnID: "turn-a")] = ActivityExecution(presentation: root)
        let childOwner = ActivityExecutionKey(agentID: "child", turnID: "child-turn")
        task.executions[childOwner] = ActivityExecution(presentation: child)
        #expect(task.snapshot.presentation?.waiting?.since == now)
        #expect(task.snapshot.presentation?.current.key == "waiting-input")
        try child.consume(message("serverRequest/resolved", #""requestId":1"#, turn: false), at: now.addingTimeInterval(5))
        task.executions[childOwner]?.presentation = child
        #expect(task.snapshot.presentation?.waiting == nil)
        #expect(task.snapshot.presentation?.current.key == "replying")
    }

    @Test func failedTurnKeepsItsOutcomeWithoutChangingTerminalPolicy() throws {
        var reducer = try prepared()
        let events = try reducer.consume(message("turn/completed", #""turn":{"id":"turn-a","status":"failed"}"#), now: now)
        let state = try #require(reducer.states.values.first)
        #expect(state.turnStatus == "failed")
        #expect(state.presentation == nil)
        #expect(events.first?.eventKind == .turnAborted)
        #expect(events.first?.source?.turnStatus == "failed")
        let event = TestFixtures.event()
        var task = ActivityTask(
            displayID: UUID(),
            key: ActivityTaskKey(event: event),
            event: event,
            state: .running,
            startedAt: now,
            progressGeneration: 0
        )
        _ = ActivityMonitor.mergeLifecycleBackfill(from: state, into: &task)
        #expect(task.terminalFailed)
    }

    @Test func mixedCommandActionsResolveTheExplicitLocalizedKey() {
        let item = ActivityItem(
            id: "cmd", type: "commandExecution",
            commandActions: ["search", "unknown", "read", "read"].map { .init(type: $0) }
        )
        #expect(item.liveLabel?.key == "command")
        #expect(item.liveLabel?.detail == String(localized: "activity.live.actions-read-search"))
        let actions = String(localized: "activity.live.actions-read-search")
        #expect(item.liveLabel?.text == String(localized: "activity.live.command-with-actions", defaultValue: "\(actions)"))
    }
}
