import Foundation

struct StatusIconState: Equatable {
    let usesErrorImage: Bool
    let ordinaryUsageAllowed: Bool?
    let progress: StatusIconProgress?
    let activity: ActivitySnapshot

    func symbolName(at now: Date) -> String {
        switch activity.statusItemActivity(at: now) {
        case .waiting: "person.badge.key.fill"
        case .running: "person.badge.clock.fill"
        case .completed: "person.badge.shield.checkmark.fill"
        case .terminated: "person.badge.shield.exclamationmark.fill"
        case .idle: usesErrorImage ? "person.slash.fill" : "person.fill"
        }
    }
}

struct StatusIconProgress: Equatable {
    let percent: Int
    let isStale: Bool

    init?(snapshot: CodexQuotaSnapshot?, selection: MenuBarQuotaSelection) {
        guard let targetKind = selection.windowKind,
              let snapshot,
              let window = snapshot.codexLimit?.window(ofKind: targetKind),
              window.hasData else {
            return nil
        }

        percent = window.remainingPercent
        isStale = snapshot.isRateLimitsStale
    }
}
