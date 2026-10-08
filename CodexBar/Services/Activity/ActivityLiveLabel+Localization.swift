import Foundation

nonisolated extension ActivityLiveLabel {
    var text: String {
        guard let detail, !detail.isEmpty else { return localizedText }
        switch key {
        case "action-completed":
            return String(localized: "activity.live.action-completed", defaultValue: "\(detail)")
        case "action-failed":
            return String(localized: "activity.live.action-failed", defaultValue: "\(detail)")
        case "action-declined":
            return String(localized: "activity.live.action-declined", defaultValue: "\(detail)")
        case "tool-completed":
            return String(localized: "activity.live.named-tool-completed", defaultValue: "\(detail)")
        case "tool-failed":
            return String(localized: "activity.live.named-tool-failed", defaultValue: "\(detail)")
        case "tool-declined":
            return String(localized: "activity.live.named-tool-declined", defaultValue: "\(detail)")
        case "calling-tool":
            return String(localized: "activity.live.calling-named-tool", defaultValue: "\(detail)")
        case "command":
            return String(localized: "activity.live.command-with-actions", defaultValue: "\(detail)")
        case "model-changed":
            return String(localized: "activity.live.model-changed-detail", defaultValue: "\(detail)")
        default:
            return localizedText
        }
    }

    /// 完整键名保留为字面量, 供 Xcode 提取和校验本地化文案
    var localizedText: String {
        switch key {
        case "actions-listFiles":
            String(localized: "activity.live.actions-listFiles")
        case "actions-listFiles-search":
            String(localized: "activity.live.actions-listFiles-search")
        case "actions-read":
            String(localized: "activity.live.actions-read")
        case "actions-read-listFiles":
            String(localized: "activity.live.actions-read-listFiles")
        case "actions-read-listFiles-search":
            String(localized: "activity.live.actions-read-listFiles-search")
        case "actions-read-search":
            String(localized: "activity.live.actions-read-search")
        case "actions-search":
            String(localized: "activity.live.actions-search")
        case "agent-assigning":
            String(localized: "activity.live.agent-assigning")
        case "agent-closing":
            String(localized: "activity.live.agent-closing")
        case "agent-completed":
            String(localized: "activity.live.agent-completed")
        case "agent-contacting":
            String(localized: "activity.live.agent-contacting")
        case "agent-coordinating":
            String(localized: "activity.live.agent-coordinating")
        case "agent-failed":
            String(localized: "activity.live.agent-failed")
        case "agent-interrupted":
            String(localized: "activity.live.agent-interrupted")
        case "agent-interrupting":
            String(localized: "activity.live.agent-interrupting")
        case "agent-querying":
            String(localized: "activity.live.agent-querying")
        case "agent-resuming":
            String(localized: "activity.live.agent-resuming")
        case "agent-started":
            String(localized: "activity.live.agent-started")
        case "agent-starting":
            String(localized: "activity.live.agent-starting")
        case "agent-waiting":
            String(localized: "activity.live.agent-waiting")
        case "answering":
            String(localized: "activity.live.answering")
        case "approval-aborted":
            String(localized: "activity.live.approval-aborted")
        case "approval-approved":
            String(localized: "activity.live.approval-approved")
        case "approval-denied":
            String(localized: "activity.live.approval-denied")
        case "approval-timeout":
            String(localized: "activity.live.approval-timeout")
        case "auth-recovery-ended":
            String(localized: "activity.live.auth-recovery-ended")
        case "auto-approval":
            String(localized: "activity.live.auto-approval")
        case "buffering":
            String(localized: "activity.live.buffering")
        case "calling-tool":
            String(localized: "activity.live.calling-tool")
        case "command":
            String(localized: "activity.live.command")
        case "command-listFiles":
            String(localized: "activity.live.command-listFiles")
        case "command-listFiles-search":
            String(localized: "activity.live.command-listFiles-search")
        case "command-read":
            String(localized: "activity.live.command-read")
        case "command-read-listFiles":
            String(localized: "activity.live.command-read-listFiles")
        case "command-read-listFiles-search":
            String(localized: "activity.live.command-read-listFiles-search")
        case "command-read-search":
            String(localized: "activity.live.command-read-search")
        case "command-search":
            String(localized: "activity.live.command-search")
        case "commentary":
            String(localized: "activity.live.commentary")
        case "compacting":
            String(localized: "activity.live.compacting")
        case "compaction-completed":
            String(localized: "activity.live.compaction-completed")
        case "connecting":
            String(localized: "activity.live.connecting")
        case "connecting-tool":
            String(localized: "activity.live.connecting-tool")
        case "diff-updated":
            String(localized: "activity.live.diff-updated")
        case "editing":
            String(localized: "activity.live.editing")
        case "elapsed-running":
            String(localized: "activity.live.elapsed-running")
        case "elapsed-waiting":
            String(localized: "activity.live.elapsed-waiting")
        case "environment-connected":
            String(localized: "activity.live.environment-connected")
        case "environment-disconnected":
            String(localized: "activity.live.environment-disconnected")
        case "failed":
            String(localized: "activity.live.failed")
        case "file-completed":
            String(localized: "activity.live.file-completed")
        case "file-declined":
            String(localized: "activity.live.file-declined")
        case "file-failed":
            String(localized: "activity.live.file-failed")
        case "finding-web":
            String(localized: "activity.live.finding-web")
        case "generating-image":
            String(localized: "activity.live.generating-image")
        case "hook-blocked":
            String(localized: "activity.live.hook-blocked")
        case "hook-completed":
            String(localized: "activity.live.hook-completed")
        case "hook-failed":
            String(localized: "activity.live.hook-failed")
        case "hook-stopped":
            String(localized: "activity.live.hook-stopped")
        case "idle":
            String(localized: "activity.live.idle")
        case "image-completed":
            String(localized: "activity.live.image-completed")
        case "image-declined":
            String(localized: "activity.live.image-declined")
        case "image-failed":
            String(localized: "activity.live.image-failed")
        case "interrupted":
            String(localized: "activity.live.interrupted")
        case "model-changed":
            String(localized: "activity.live.model-changed")
        case "opening-web":
            String(localized: "activity.live.opening-web")
        case "plan-progress":
            String(localized: "activity.live.plan-progress")
        case "plan-step-completed":
            String(localized: "activity.live.plan-step-completed")
        case "plan-updated":
            String(localized: "activity.live.plan-updated")
        case "planning":
            String(localized: "activity.live.planning")
        case "processing":
            String(localized: "activity.live.processing")
        case "recent-event":
            String(localized: "activity.live.recent-event")
        case "reconnecting":
            String(localized: "activity.live.reconnecting")
        case "recovering-auth":
            String(localized: "activity.live.recovering-auth")
        case "recovering-state":
            String(localized: "activity.live.recovering-state")
        case "replying":
            String(localized: "activity.live.replying")
        case "request-ended":
            String(localized: "activity.live.request-ended")
        case "retrying":
            String(localized: "activity.live.retrying")
        case "review-mode":
            String(localized: "activity.live.review-mode")
        case "running":
            String(localized: "activity.live.running")
        case "running-hook":
            String(localized: "activity.live.running-hook")
        case "searching-web":
            String(localized: "activity.live.searching-web")
        case "sleeping":
            String(localized: "activity.live.sleeping")
        case "thinking":
            String(localized: "activity.live.thinking")
        case "tool-completed", "action-completed":
            String(localized: "activity.live.tool-completed")
        case "tool-declined", "action-declined":
            String(localized: "activity.live.tool-declined")
        case "tool-failed", "action-failed":
            String(localized: "activity.live.tool-failed")
        case "unavailable":
            String(localized: "activity.live.unavailable")
        case "using-web":
            String(localized: "activity.live.using-web")
        case "verification-needed":
            String(localized: "activity.live.verification-needed")
        case "viewing-image":
            String(localized: "activity.live.viewing-image")
        case "waiting-approval":
            String(localized: "activity.live.waiting-approval")
        case "waiting-external":
            String(localized: "activity.live.waiting-external")
        case "waiting-form":
            String(localized: "activity.live.waiting-form")
        case "waiting-input":
            String(localized: "activity.live.waiting-input")
        case "waiting-service":
            String(localized: "activity.live.waiting-service")
        case "waiting-user":
            String(localized: "activity.live.waiting-user")
        case "waiting-verification":
            String(localized: "activity.live.waiting-verification")
        default:
            String(localized: "activity.live.processing")
        }
    }
}
