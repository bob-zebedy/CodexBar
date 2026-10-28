import Foundation
import Testing

struct ActivityLiveLabelTests {
    @Test(arguments: [
        (["read"], .init("command-read")), (["listFiles"], .init("command-listfiles")), (["search"], .init("command-search")),
        (["search", "read", "read"], .init("command-read-search")), (["search", "listFiles"], .init("command-listfiles-search")),
        (["listFiles", "read"], .init("command-read-listfiles")), (["search", "listFiles", "read"], .init("command-read-listfiles-search")),
        (["read", "unknown"], .init("command", detail: String(localized: "activity.live.actions-read"))),
        (["search", "unknown", "read"], .init("command", detail: String(localized: "activity.live.actions-read-search"))),
        (["search", "unknown", "read", "read"], .init("command", detail: String(localized: "activity.live.actions-read-search"))),
        (["future"], .init("command")), ([], .init("command"))
    ] as [([String], ActivityLiveLabel)])
    func commandActionsUseServerClassification(actions: [String], expected: ActivityLiveLabel) throws {
        let item = ActivityItem(id: "cmd", type: .commandExecution, commandActions: actions.map { .init(type: $0) })
        let label = try #require(item.liveLabel)
        #expect(label == expected)
        if let detail = expected.detail {
            #expect(label.text == String(localized: "activity.live.command-with-actions", defaultValue: "\(detail)"))
            #expect(!label.text.contains(" • "))
        }
    }

    @Test(arguments: [
        (["search", "read"], "actions-read-search"),
        (["read", "search"], "actions-read-search"),
        (["search", "unknown", "read", "read"], "actions-read-search"),
        (["search", "listFiles", "read", "listFiles"], "actions-read-listfiles-search"),
        ([], nil), (["unknown", "future"], nil)
    ] as [([String], String?)])
    func commandCompletionLocalizesAndOrdersKnownActions(actions: [String], detailKey: String?) {
        let item = ActivityItem(
            id: "cmd", type: .commandExecution, status: "failed",
            commandActions: actions.map { .init(type: $0) }
        )
        #expect(item.liveCompletionLabel?.key == (detailKey == nil ? "command-failed" : "action-failed"))
        #expect(item.liveCompletionLabel?.detail == detailKey.map { ActivityLiveLabel($0).text })
    }

    @Test func knownCommandClassificationsTakePrecedenceOverParsing() throws {
        let item = try TestFixtures.decode(ActivityItem.self, #"""
        {"id":"cmd","type":"commandExecution","status":"completed","commandActions":[
        {"type":"read","command":"cat file"},{"type":"unknown","command":"pwd; git status"}]}
        """#)
        #expect(item.commandSummary == nil)
        #expect(item.liveLabel == ActivityLiveLabel("command", detail: ActivityLiveLabel("actions-read").text))
        #expect(item.liveCompletionLabel == ActivityLiveLabel("action-completed", detail: ActivityLiveLabel("actions-read").text))
    }

    @Test(arguments: ["git", "git, ls"])
    func parsedCommandLabelsAreLocalized(names: String) {
        #expect(ActivityLiveLabel("executing-tool", detail: "python3").text == String(localized: "activity.live.executing-named-tool", defaultValue: "\("python3")"))
        #expect(ActivityLiveLabel("executing-tool", detail: names).text == String(localized: "activity.live.executing-named-tool", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("command-completed", detail: names).text == String(localized: "activity.live.named-command-completed", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("command-failed", detail: names).text == String(localized: "activity.live.named-command-failed", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("command-declined", detail: names).text == String(localized: "activity.live.named-command-declined", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("executing-tools", detail: names).text == String(localized: "activity.live.executing-tools", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("tools-completed", detail: names).text == String(localized: "activity.live.tools-completed", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("tools-failed", detail: names).text == String(localized: "activity.live.tools-failed", defaultValue: "\(names)"))
        #expect(ActivityLiveLabel("tools-declined", detail: names).text == String(localized: "activity.live.tools-declined", defaultValue: "\(names)"))
    }

    @Test(arguments: ["mcpToolCall", "dynamicToolCall"], [nil, "server"] as [String?])
    func completionPreservesActualToolNames(type: String, server: String?) {
        let item = ActivityItem(
            id: "tool", type: ActivityItem.ItemType(rawValue: type) ?? .unknown, status: "failed", tool: "search/read", server: server,
            commandActions: [.init(type: "read")]
        )
        #expect(item.liveCompletionLabel?.key == "tool-failed")
        let name = type == "mcpToolCall" ? server.map { $0 + ".search/read" } ?? "search/read" : "search/read"
        #expect(item.liveCompletionLabel?.detail == name)
        #expect(item.liveCompletionLabel?.text == String(localized: "activity.live.named-tool-failed", defaultValue: "\(name)"))
    }

    @Test(arguments: ["tool-completed", "tool-failed", "tool-declined", "command-completed", "command-failed", "command-declined", "calling-tool", "command", "model-changed"])
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
    ] as [(String, (String, LocalizedStringResource))])
    func subagentOperationsDescribeTheCall(operation: (tool: String, expected: (statusKey: String, action: LocalizedStringResource))) {
        let item = ActivityItem(
            id: "agent", type: .collabAgentToolCall, status: "completed", tool: operation.tool,
            agentsStates: ["child": .init(status: "running")]
        )
        #expect(item.liveLabel?.key == operation.expected.statusKey)
        #expect(item.liveCompletionLabel?.key == "action-completed")
        #expect(item.liveCompletionLabel?.detail == String(localized: operation.expected.action))
        #expect(ActivityDisplayFormat.toolActionText(itemType: item.type.rawValue, toolName: operation.tool) == item.liveCompletionLabel?.detail)
    }

    @Test(arguments: ["completed", "failed", "declined", "interrupted"])
    func subagentCompletionPreservesOutcome(status: String) {
        let item = ActivityItem(
            id: "agent", type: .collabAgentToolCall, status: status, tool: "spawnAgent",
            agentsStates: ["child": .init(status: "running")]
        )
        #expect(item.liveCompletionLabel?.key == "action-" + status)
        #expect(item.liveCompletionLabel?.detail == String(localized: "activity.action.start-subagent"))
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

    @Test(arguments: ["completed", "failed", "declined", "unknown"])
    func toolOutcomeDoesNotAssumeSuccess(status: String) {
        let item = ActivityItem(id: "image", type: .imageGeneration, status: status)
        #expect(item.liveCompletionLabel?.key == (status == "unknown" ? nil : "image-" + status))
    }
}
