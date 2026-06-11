//
//  NotificationSettings.swift
//  CodexBar
//
//  Created by Bob on 2026-06-11.
//

import Combine
import Foundation
import UserNotifications

@MainActor
final class NotificationSettings: ObservableObject {
    @Published private(set) var isEnabled = NotificationSettingsStore.isEnabled
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        Task {
            await refreshAuthorizationState()
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        guard enabled else {
            NotificationSettingsStore.isEnabled = false
            isEnabled = false
            return
        }

        Task {
            await enable()
        }
    }

    private func enable() async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus

        if status.allowsNotifications {
            NotificationSettingsStore.isEnabled = true
            isEnabled = true
            return
        }

        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            NotificationSettingsStore.isEnabled = granted
            isEnabled = granted

            if !granted {
                errorMessage = "系统通知权限未开启"
            }

            return
        }

        NotificationSettingsStore.isEnabled = false
        isEnabled = false
        errorMessage = status == .denied ? "系统通知权限被拒绝" : "系统通知权限不可用"
    }

    private func refreshAuthorizationState() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus

        if status.allowsNotifications {
            isEnabled = NotificationSettingsStore.isEnabled
        } else {
            if status != .notDetermined {
                NotificationSettingsStore.isEnabled = false
            }

            isEnabled = false
        }
    }
}

extension UNAuthorizationStatus {
    var allowsNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}

enum NotificationSettingsStore {
    private static let enabledKey = "rateLimitNotificationsEnabled"

    static var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}

struct QuotaNotificationService {
    func sendRateLimitUpdatedNotification() async {
        guard NotificationSettingsStore.isEnabled,
              await hasAuthorization else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Codex 额度已更新"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex-rate-limits-updated-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }

    private var hasAuthorization: Bool {
        get async {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.allowsNotifications
        }
    }

}
