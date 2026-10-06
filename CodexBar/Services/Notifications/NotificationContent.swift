import Foundation

nonisolated struct NotificationContent: Equatable {
    /// 只用于日志分类, 由各静态工厂带出, 保证与实际内容不会错位
    let kind: String
    let title: String
    let body: String

    static func lowQuota(
        limitTitle: String,
        windowLabel: String,
        thresholdPercent: Int
    ) -> NotificationContent {
        let thresholdText = CodexPercentageFormat.string(from: thresholdPercent)
        return NotificationContent(
            kind: "lowQuota",
            title: String(localized: "notification.low-quota.title"),
            body: String(
                localized: "notification.low-quota.body",
                defaultValue: "\(limitTitle)\(windowLabel)\(thresholdText)"
            )
        )
    }

    static func quotaReset(
        limitTitle: String,
        windowLabel: String
    ) -> NotificationContent {
        NotificationContent(
            kind: "quotaReset",
            title: String(localized: "notification.quota-reset.title"),
            body: String(
                localized: "notification.quota-reset.body",
                defaultValue: "\(limitTitle)\(windowLabel)"
            )
        )
    }

    static func autoResetSucceeded(remainingCount: Int?) -> NotificationContent {
        let body = if let remainingCount {
            String(
                localized: "notification.auto-reset.body.count",
                defaultValue: "\(remainingCount)"
            )
        } else {
            ""
        }

        return NotificationContent(
            kind: "autoResetSucceeded",
            title: String(localized: "notification.auto-reset.title"),
            body: body
        )
    }

    static func autoResetFailed(
        reason: AutoResetFailureNotice
    ) -> NotificationContent {
        let body = switch reason {
        case .expired:
            String(localized: "notification.auto-reset-failed.body.expired")
        case .authentication:
            String(localized: "notification.auto-reset-failed.body.authentication")
        case .permanent:
            String(localized: "notification.auto-reset-failed.body.permanent")
        }

        return NotificationContent(
            kind: "autoResetFailed",
            title: String(localized: "notification.auto-reset-failed.title"),
            body: body
        )
    }

    static func taskCompleted(project: String?, duration: TimeInterval) -> NotificationContent {
        let durationText = ActivityDisplayFormat.elapsedDurationFragment(for: duration)
        let body = if let project {
            String(
                localized: "notification.task-completed.body.project",
                defaultValue: "\(project)\(durationText)"
            )
        } else {
            String(
                localized: "notification.task-completed.body.codex",
                defaultValue: "\(durationText)"
            )
        }

        return NotificationContent(
            kind: "taskCompleted",
            title: String(localized: "notification.task-completed.title"),
            body: body
        )
    }

    static func taskWaiting(project: String?, toolName: String?) -> NotificationContent {
        let body = switch (project, toolName) {
        case let (project?, toolName?):
            String(
                localized: "notification.task-waiting.body.project-tool",
                defaultValue: "\(project)\(toolName)"
            )
        case let (project?, nil):
            String(
                localized: "notification.task-waiting.body.project",
                defaultValue: "\(project)"
            )
        case let (nil, toolName?):
            String(
                localized: "notification.task-waiting.body.codex-tool",
                defaultValue: "\(toolName)"
            )
        case (nil, nil):
            String(localized: "notification.task-waiting.body.codex")
        }

        return NotificationContent(
            kind: "taskWaiting",
            title: String(localized: "notification.task-waiting.title"),
            body: body
        )
    }

    static func protection(
        project: String?,
        inactivityDurationText: String
    ) -> NotificationContent {
        let body = if let project {
            String(
                localized: "notification.protection.body.project",
                defaultValue: "\(project)\(inactivityDurationText)"
            )
        } else {
            String(
                localized: "notification.protection.body.codex",
                defaultValue: "\(inactivityDurationText)"
            )
        }

        return NotificationContent(
            kind: "protection",
            title: String(localized: "notification.protection.title"),
            body: body
        )
    }

    static func creditExpiry(count: Int, expirationDate: Date) -> NotificationContent {
        let expirationText = CodexDateFormat.localDisplayString(from: expirationDate)
        return NotificationContent(
            kind: "creditExpiry",
            title: String(localized: "notification.banked-reset-expiry.title"),
            body: String(
                localized: "notification.banked-reset-expiry.body",
                defaultValue: "\(count)\(expirationText)"
            )
        )
    }

    static func lowBattery(percent: Int) -> NotificationContent {
        let percentText = CodexPercentageFormat.string(from: percent)
        return NotificationContent(
            kind: "lowBattery",
            title: String(localized: "notification.keep-alive-ended.title"),
            body: String(
                localized: "notification.keep-alive-ended.low-battery",
                defaultValue: "\(percentText)"
            )
        )
    }

    static func keepAliveLimit(durationText: String) -> NotificationContent {
        NotificationContent(
            kind: "keepAliveLimit",
            title: String(localized: "notification.keep-alive-ended.title"),
            body: String(
                localized: "notification.keep-alive-ended.duration-limit",
                defaultValue: "\(durationText)"
            )
        )
    }
}

// MARK: - UNUserNotificationCenterDelegate
