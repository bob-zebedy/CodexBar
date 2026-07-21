import Foundation

/// Codex Hook 事件名的统一枚举, 负责在 hooks.json 与 app-server 命名间转换
nonisolated enum CodexHookEvent: String, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"

    init?(eventName: String) {
        let normalizedName = Self.normalizedName(eventName)
        guard let event = Self.allCases.first(where: { $0.normalizedName == normalizedName }) else {
            return nil
        }
        self = event
    }

    var configName: String {
        rawValue
    }

    var appServerName: String {
        rawValue.prefix(1).lowercased() + rawValue.dropFirst()
    }

    private var normalizedName: String {
        Self.normalizedName(rawValue)
    }

    private static func normalizedName(_ eventName: String) -> String {
        eventName
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}

/// Codex turn 的审批路由; 只有 user 表示 PermissionRequest 会停在用户 UI
nonisolated enum CodexApprovalReviewer: String, Codable {
    case user
    case autoReview = "auto_review"
    case guardianSubagent = "guardian_subagent"
}
