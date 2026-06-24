import Foundation

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
