nonisolated extension ActivityLiveLabel {
    static func symbolName(for key: String) -> String {
        switch key {
        case "thinking":
            "brain"
        case "answering", "replying", "commentary":
            "text.bubble"
        case "command-read":
            "book"
        case "command-listfiles":
            "folder"
        case "command-search":
            "magnifyingglass"
        case "command-read-listfiles", "command-read-search", "command-listfiles-search", "command-read-listfiles-search":
            "doc.text.magnifyingglass"
        case "command", "executing-tool", "executing-tools", "command-completed", "command-failed", "command-declined",
             "tools-completed", "tools-failed", "tools-declined":
            "terminal"
        case "editing", "file-completed", "file-failed", "file-declined":
            "square.and.pencil"
        case "searching-web", "opening-web", "finding-web", "using-web":
            "globe"
        case "viewing-image":
            "photo"
        case "generating-image", "image-completed", "image-failed", "image-declined":
            "wand.and.stars"
        case "calling-tool", "tool-completed", "tool-failed", "tool-declined", "action-completed", "action-failed", "action-declined", "action-interrupted":
            "wrench.and.screwdriver"
        case "agent-starting", "agent-assigning", "agent-contacting", "agent-resuming", "agent-waiting", "agent-interrupting",
             "agent-closing", "agent-querying", "agent-coordinating", "agent-started", "agent-completed", "agent-failed", "agent-interrupted":
            "person.2"
        case "compacting", "compaction-completed":
            "arrow.up.right.and.arrow.down.left.rectangle"
        case "waiting-approval":
            "hand.raised"
        case "waiting-input", "waiting-form", "waiting-external", "waiting-service", "waiting-default", "request-ended":
            "bubble.left.and.bubble.right"
        case "sleeping", "timer-completed", "timer-failed", "timer-declined":
            "hourglass"
        case "running-hook", "hook-completed", "hook-failed", "hook-blocked", "hook-stopped":
            "link"
        case "retrying":
            "arrow.clockwise"
        case "recovering-auth", "auth-recovery-ended":
            "key"
        case "buffering":
            "ellipsis.bubble"
        case "plan-updated", "plan-step-completed":
            "list.bullet"
        case "diff-updated":
            "doc.text"
        case "model-changed":
            "arrow.triangle.2.circlepath"
        case "verification-needed":
            "checkmark.shield"
        default:
            "ellipsis"
        }
    }
}
