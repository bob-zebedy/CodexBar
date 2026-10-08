import Foundation

nonisolated extension ActivityItem {
    var liveLabel: ActivityLiveLabel? {
        switch type {
        case "reasoning": ActivityLiveLabel("thinking")
        case "agentMessage":
            ActivityLiveLabel(phase == "final_answer" ? "answering" : phase == "commentary" ? "commentary" : "replying")
        case "plan": ActivityLiveLabel("planning")
        case "contextCompaction": ActivityLiveLabel("compacting")
        case "commandExecution": commandLabel
        case "fileChange": ActivityLiveLabel("editing")
        case "webSearch": ActivityLiveLabel(webLabel)
        case "imageView": ActivityLiveLabel("viewing-image")
        case "imageGeneration": ActivityLiveLabel("generating-image")
        case "sleep": ActivityLiveLabel("sleeping")
        case "collabAgentToolCall": ActivityLiveLabel(ActivityDisplayFormat.agentAction(tool: tool).statusKey)
        case "mcpToolCall", "dynamicToolCall": ActivityLiveLabel("calling-tool", detail: tool)
        default: nil
        }
    }

    private var commandLabel: ActivityLiveLabel {
        let types = Set((commandActions ?? []).map(\.type))
        let actions = orderedCommandActions
        guard !actions.isEmpty else { return ActivityLiveLabel("command") }
        let key = "command-" + actions.joined(separator: "-")
        if types.isSubset(of: Set(actions)) {
            return ActivityLiveLabel(key)
        }
        return ActivityLiveLabel("command", detail: commandActionDetail)
    }

    private var orderedCommandActions: [String] {
        ActivityDisplayFormat.orderedCommandActions((commandActions ?? []).map(\.type))
    }

    private var commandActionDetail: String? {
        ActivityDisplayFormat.commandActionText((commandActions ?? []).map(\.type))
    }

    private var webLabel: String {
        switch action?.type {
        case "search": "searching-web"
        case "openPage": "opening-web"
        case "findInPage": "finding-web"
        default: "using-web"
        }
    }

    var liveCompletionLabel: ActivityLiveLabel? {
        if type == "subAgentActivity" {
            return ["started": "agent-started", "completed": "agent-completed", "interrupted": "agent-interrupted"][kind ?? ""]
                .map { ActivityLiveLabel($0) }
        }
        if type == "contextCompaction" {
            return ActivityLiveLabel("compaction-completed")
        }
        if type == "collabAgentToolCall", agentsStates?.values.contains(where: { $0.status == "errored" }) == true {
            return ActivityLiveLabel("agent-failed")
        }
        guard isToolCall else { return nil }
        let prefix = type == "fileChange" ? "file" : type == "imageGeneration" ? "image" : "tool"
        let outcome: String
        if status == "declined" {
            outcome = "declined"
        } else if status == "failed" || success == false {
            outcome = "failed"
        } else if status == "completed" || success == true || ["webSearch", "imageView", "sleep"].contains(type) {
            outcome = "completed"
        } else {
            return nil
        }
        let detail = switch type {
        case "commandExecution": commandActionDetail
        case "collabAgentToolCall": String(localized: ActivityDisplayFormat.agentAction(tool: tool).action)
        default: toolDisplayName
        }
        if detail != nil, type == "commandExecution" || type == "collabAgentToolCall" {
            return ActivityLiveLabel("action-" + outcome, detail: detail)
        }
        return ActivityLiveLabel(prefix + "-" + outcome, detail: prefix == "tool" ? detail : nil)
    }
}

nonisolated extension ActivityDisplayFormat {
    static func orderedCommandActions(_ types: [String]) -> [String] {
        let types = Set(types)
        return ["read", "listFiles", "search"].filter { types.contains($0) }
    }

    static func commandActionText(_ types: [String]) -> String? {
        let actions = orderedCommandActions(types)
        guard !actions.isEmpty else { return nil }
        return ActivityLiveLabel("actions-" + actions.joined(separator: "-")).text
    }

    static func agentAction(tool: String?) -> (statusKey: String, action: LocalizedStringResource) {
        switch tool {
        case "spawnAgent": ("agent-starting", "activity.action.start-subagent")
        case "sendInput", "followupTask": ("agent-assigning", "activity.action.assign-subagent")
        case "sendMessage": ("agent-contacting", "activity.action.message-subagent")
        case "resumeAgent": ("agent-resuming", "activity.action.resume-subagent")
        case "wait": ("agent-waiting", "activity.action.wait-subagent")
        case "interruptAgent": ("agent-interrupting", "activity.action.interrupt-subagent")
        case "closeAgent": ("agent-closing", "activity.action.close-subagent")
        case "listAgents": ("agent-querying", "activity.action.query-subagent")
        default: ("agent-coordinating", "activity.action.coordinate-subagents")
        }
    }

    static func toolActionText(itemType: String?, toolName: String?) -> String? {
        if itemType == "commandExecution" {
            // 历史事件的 tool 字段保存分类组合, 仅在类型明确时按该格式读取
            let actions = toolName?.split(separator: "/").map(String.init) ?? []
            return commandActionText(actions) ?? String(localized: "activity.action.command")
        }
        if itemType == "collabAgentToolCall" {
            return String(localized: agentAction(tool: toolName).action)
        }
        if let toolName, !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return toolName
        }
        switch itemType {
        case "fileChange": return String(localized: "activity.action.edit-files")
        case "webSearch": return String(localized: "activity.action.search-web")
        case "imageView": return String(localized: "activity.action.view-image")
        case "imageGeneration": return String(localized: "activity.action.generate-image")
        case "sleep": return String(localized: "activity.action.wait-timer")
        case "mcpToolCall", "dynamicToolCall": return String(localized: "activity.action.call-tool")
        default: return nil
        }
    }

    static func liveSummaryComponents(for task: ActivityTaskSnapshot, now: Date, waiting: Bool = false) -> [String] {
        let live = task.presentation
        let running = if task.showsPreciseDuration, let started = task.startedAt {
            ActivityLiveLabel("elapsed-running").text + " " + CodexDurationFormat.activityText(for: now.timeIntervalSince(started))
        } else {
            ActivityLiveLabel("running").text
        }
        let waitStart = live?.waiting?.since
        let waitingDuration = waitStart.map {
            ActivityLiveLabel("elapsed-waiting").text + " " + CodexDurationFormat.activityText(for: now.timeIntervalSince($0))
        }
        // 等待起点缺失时只展示等待事实, 不把订阅连接的时间当成请求开始时间
        if waiting || live?.waiting != nil {
            return [running, waitingDuration ?? ActivityLiveLabel("waiting-user").text]
        }
        let extra: String? = if let count = task.activeSubagentCount, count > 0 {
            String(localized: "activity.live.subagent-count", defaultValue: "\(count, specifier: "%lld")")
        } else if let count = live?.toolCount, count > 1 {
            String(localized: "activity.live.tool-count", defaultValue: "\(count, specifier: "%lld")")
        } else if let total = live?.planTotal, total > 0, let completed = live?.planCompleted {
            ActivityLiveLabel("plan-progress").text + " \(completed)/\(total)"
        } else if live?.isReviewing == true {
            ActivityLiveLabel("review-mode").text
        } else {
            nil
        }
        return [running] + (extra.map { [$0] } ?? [])
    }

    static func liveStatus(for task: ActivityTaskSnapshot, waiting: Bool) -> String {
        task.presentation?.current.text ?? ActivityLiveLabel(waiting ? "waiting-approval" : "processing").text
    }

    static func recentEvent(for task: ActivityTaskSnapshot) -> String? {
        task.presentation?.recent.map { ActivityLiveLabel("recent-event").text + ": " + $0.label.text }
    }
}
