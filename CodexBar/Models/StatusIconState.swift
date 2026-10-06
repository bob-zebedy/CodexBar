import Foundation

struct StatusIconState: Equatable {
    let usesErrorImage: Bool
    let ordinaryUsageAllowed: Bool?
    let progress: StatusIconProgress?
    let activity: ActivitySnapshot

    func symbolName(at now: Date) -> String {
        if usesErrorImage {
            return "person.slash.fill"
        }
        switch activity.statusItemActivity(at: now) {
        case .waiting: return "person.badge.key.fill"
        case .running: return "person.badge.clock.fill"
        case .completed: return "person.badge.shield.checkmark.fill"
        case .terminated: return "person.badge.shield.exclamationmark.fill"
        case .idle: return "person.fill"
        }
    }

    var hasLiveDuration: Bool {
        activity.hasActiveTasks
    }

    func toolTip(at now: Date) -> String? {
        var lines: [String] = []
        if usesErrorImage {
            lines.append(String(localized: "codex-status.account.unavailable"))
        }

        if let activityText = activityToolTip(at: now) {
            lines.append(activityText)
        }
        if activity.activeCount > 1 {
            lines.append(
                String(localized: "status-item.activity-summary", defaultValue: "\(activity.waitingCount, specifier: "%lld")\(activity.runningCount, specifier: "%lld")")
            )
        }
        if let progress {
            lines.append(progress.toolTip)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func activityToolTip(at now: Date) -> String? {
        switch activity.statusItemActivity(at: now) {
        case let .waiting(task):
            var text = String(localized: "activity.status.codex-waiting-for-approval")
            if let projectName = task.projectName {
                text += " • \(projectName)"
            }
            if let toolName = task.toolDisplayName {
                text += " • \(toolName)"
            }
            text += " • \(ActivityDisplayFormat.waitingDurationFragment(since: task.stateChangedAt, now: now))"
            return text
        case let .running(task):
            var text = String(localized: "activity.status.codex-running")
            if let projectName = task.projectName {
                text += " • \(projectName)"
            }
            if task.showsPreciseDuration, let startedAt = task.startedAt {
                text += " • \(ActivityDisplayFormat.runningDurationFragment(since: startedAt, now: now))"
            }
            return text
        case let .completed(completion):
            var text = String(localized: "activity.status.codex-just-completed")
            if let projectName = completion.projectName {
                text += " • \(projectName)"
            }
            if let duration = completion.duration {
                text += " • \(ActivityDisplayFormat.elapsedDurationFragment(for: duration))"
            }
            return text
        case let .terminated(termination):
            var text = String(localized: "activity.status.codex-stopped")
            if let projectName = termination.projectName {
                text += " • \(projectName)"
            }
            if let duration = termination.duration {
                text += " • \(ActivityDisplayFormat.elapsedDurationFragment(for: duration))"
            }
            return text
        case .idle:
            return nil
        }
    }
}

struct StatusIconProgress: Equatable {
    let label: String
    let percent: Int
    let isStale: Bool

    var toolTip: String {
        let percentText = CodexPercentageFormat.string(from: percent)
        return String(localized: "quota.status.remaining", defaultValue: "\(label)\(percentText)")
    }

    init?(snapshot: CodexQuotaSnapshot?, selection: MenuBarQuotaSelection) {
        guard let targetKind = selection.windowKind,
              let snapshot,
              let window = snapshot.codexLimit?.window(ofKind: targetKind),
              window.hasData else {
            return nil
        }

        label = window.label
        percent = window.remainingPercent
        isStale = snapshot.isRateLimitsStale
    }
}
