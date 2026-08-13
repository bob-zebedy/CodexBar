import AppKit
import Combine
import Foundation
import os
import UserNotifications

/// 通知偏好: 总开关; 八类通知子开关及声音; 任务触觉开关; 两个阈值和系统授权状态镜像
/// 授权请求/查询集中在这里, 通知与触觉反馈判定在 CodexNotificationService
@MainActor
final class NotificationSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLowQuotaEnabled: Bool
    @Published private(set) var isQuotaResetEnabled: Bool
    @Published private(set) var isTaskCompletionEnabled: Bool
    @Published private(set) var isTaskWaitingEnabled: Bool
    @Published private(set) var isTaskHapticEnabled: Bool
    @Published private(set) var isCreditExpiryEnabled: Bool
    @Published private(set) var isAutoResetEnabled: Bool
    @Published private(set) var isLowBatteryEnabled: Bool
    @Published private(set) var isKeepAliveLimitEnabled: Bool
    @Published private(set) var lowQuotaThresholdPercent: Int
    @Published private(set) var taskCompletionMinimumDurationSeconds: Int
    @Published private(set) var lowQuotaSound: NotificationSoundOption
    @Published private(set) var quotaResetSound: NotificationSoundOption
    @Published private(set) var taskCompletionSound: NotificationSoundOption
    @Published private(set) var taskWaitingSound: NotificationSoundOption
    @Published private(set) var creditExpirySound: NotificationSoundOption
    @Published private(set) var autoResetSound: NotificationSoundOption
    @Published private(set) var lowBatterySound: NotificationSoundOption
    @Published private(set) var keepAliveLimitSound: NotificationSoundOption
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// 系统授权被拒时设置页展示引导, 通知服务停发
    var isAuthorizationDenied: Bool {
        authorizationStatus == .denied
    }

    /// 总开关开启且系统已明确允许时才发送, 未决定或未知状态都按不可发送处理
    var canDeliver: Bool {
        guard isEnabled else {
            return false
        }

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    /// 触觉反馈不依赖系统通知授权, 但服从 App 内通知总开关
    var canPerformTaskHapticFeedback: Bool {
        isEnabled && isTaskHapticEnabled
    }

    /// 子选项面板仅在总开关开启且授权已明确通过时可展示
    var canShowOptions: Bool {
        canDeliver
    }

    static let lowQuotaThresholdOptions = [5, 10, 25]
    static let taskCompletionDurationOptions = [30, 60, 120, 300]

    private let defaults: UserDefaults
    private var authorizationTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        isLowQuotaEnabled = Self.bool(from: defaults, key: Self.lowQuotaEnabledKey, defaultValue: true)
        isQuotaResetEnabled = Self.bool(from: defaults, key: Self.quotaResetEnabledKey, defaultValue: true)
        isTaskCompletionEnabled = Self.bool(
            from: defaults,
            key: Self.taskCompletionEnabledKey,
            defaultValue: true
        )
        isTaskWaitingEnabled = Self.bool(from: defaults, key: Self.taskWaitingEnabledKey, defaultValue: true)
        isTaskHapticEnabled = Self.bool(from: defaults, key: Self.taskHapticEnabledKey, defaultValue: false)
        isCreditExpiryEnabled = Self.bool(from: defaults, key: Self.creditExpiryEnabledKey, defaultValue: true)
        isAutoResetEnabled = Self.bool(
            from: defaults,
            key: Self.autoResetEnabledKey,
            defaultValue: true
        )
        isLowBatteryEnabled = Self.bool(from: defaults, key: Self.lowBatteryEnabledKey, defaultValue: true)
        isKeepAliveLimitEnabled = Self.bool(from: defaults, key: Self.keepAliveLimitEnabledKey, defaultValue: true)
        lowQuotaThresholdPercent = Self.option(
            defaults.object(forKey: Self.lowQuotaThresholdKey) as? Int,
            in: Self.lowQuotaThresholdOptions,
            defaultValue: 10
        )
        taskCompletionMinimumDurationSeconds = Self.option(
            defaults.object(forKey: Self.taskCompletionMinimumDurationKey) as? Int,
            in: Self.taskCompletionDurationOptions,
            defaultValue: 60
        )
        lowQuotaSound = Self.sound(from: defaults, key: Self.lowQuotaSoundKey)
        quotaResetSound = Self.sound(from: defaults, key: Self.quotaResetSoundKey)
        taskCompletionSound = Self.sound(from: defaults, key: Self.taskCompletionSoundKey)
        taskWaitingSound = Self.sound(from: defaults, key: Self.taskWaitingSoundKey)
        creditExpirySound = Self.sound(from: defaults, key: Self.creditExpirySoundKey)
        autoResetSound = Self.sound(from: defaults, key: Self.autoResetSoundKey)
        lowBatterySound = Self.sound(from: defaults, key: Self.lowBatterySoundKey)
        keepAliveLimitSound = Self.sound(from: defaults, key: Self.keepAliveLimitSoundKey)
    }

    deinit {
        authorizationTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        AppLog.notification.notice("通知总开关变更: enabled=\(enabled ? 1 : 0)")
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            requestAuthorization()
        }
    }

    func setLowQuotaEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isLowQuotaEnabled, key: Self.lowQuotaEnabledKey)
    }

    func setQuotaResetEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isQuotaResetEnabled, key: Self.quotaResetEnabledKey)
    }

    func setTaskCompletionEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isTaskCompletionEnabled, key: Self.taskCompletionEnabledKey)
    }

    func setTaskWaitingEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isTaskWaitingEnabled, key: Self.taskWaitingEnabledKey)
    }

    func setTaskHapticEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isTaskHapticEnabled, key: Self.taskHapticEnabledKey)
    }

    func setCreditExpiryEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isCreditExpiryEnabled, key: Self.creditExpiryEnabledKey)
    }

    func setAutoResetEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isAutoResetEnabled, key: Self.autoResetEnabledKey)
    }

    func setLowBatteryEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isLowBatteryEnabled, key: Self.lowBatteryEnabledKey)
    }

    func setKeepAliveLimitEnabled(_ enabled: Bool) {
        setBool(enabled, current: &isKeepAliveLimitEnabled, key: Self.keepAliveLimitEnabledKey)
    }

    func setLowQuotaThresholdPercent(_ percent: Int) {
        guard Self.lowQuotaThresholdOptions.contains(percent),
              percent != lowQuotaThresholdPercent else {
            return
        }

        lowQuotaThresholdPercent = percent
        defaults.set(percent, forKey: Self.lowQuotaThresholdKey)
    }

    func setTaskCompletionMinimumDurationSeconds(_ seconds: Int) {
        guard Self.taskCompletionDurationOptions.contains(seconds),
              seconds != taskCompletionMinimumDurationSeconds else {
            return
        }

        taskCompletionMinimumDurationSeconds = seconds
        defaults.set(seconds, forKey: Self.taskCompletionMinimumDurationKey)
    }

    func setLowQuotaSound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &lowQuotaSound, key: Self.lowQuotaSoundKey)
    }

    func setQuotaResetSound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &quotaResetSound, key: Self.quotaResetSoundKey)
    }

    func setTaskCompletionSound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &taskCompletionSound, key: Self.taskCompletionSoundKey)
    }

    func setTaskWaitingSound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &taskWaitingSound, key: Self.taskWaitingSoundKey)
    }

    func setCreditExpirySound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &creditExpirySound, key: Self.creditExpirySoundKey)
    }

    func setAutoResetSound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &autoResetSound, key: Self.autoResetSoundKey)
    }

    func setLowBatterySound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &lowBatterySound, key: Self.lowBatterySoundKey)
    }

    func setKeepAliveLimitSound(_ sound: NotificationSoundOption) {
        setSound(sound, current: &keepAliveLimitSound, key: Self.keepAliveLimitSoundKey)
    }

    /// 用户可能在系统设置里改过权限, 回到 App 时需要重新读取
    func refreshAuthorizationStatus() {
        authorizationTask?.cancel()
        authorizationTask = Task { @MainActor [weak self] in
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            guard let self, !Task.isCancelled else {
                return
            }

            // 开关已开但用户从未回应过系统弹窗 (如开启后立即退出): 补一次请求, 避免静默丢通知
            if status == .notDetermined, isEnabled {
                requestAuthorization()
                return
            }

            let previousStatus = authorizationStatus
            if status != previousStatus {
                let details = LogFields.joined(
                    "from=\(String(describing: previousStatus))",
                    "to=\(String(describing: status))"
                )
                AppLog.notification.notice("通知授权变化: \(details, privacy: .public)")
            }
            authorizationStatus = status
        }
    }

    /// 引导用户到系统设置的 CodexBar 通知面板
    func openSystemNotificationSettings() {
        let candidates = [
            Bundle.main.bundleIdentifier.flatMap {
                URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)")
            },
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        ]
        for url in candidates.compactMap(\.self) where NSWorkspace.shared.open(url) {
            return
        }
    }

    private func requestAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = Task { @MainActor [weak self] in
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            guard let self, !Task.isCancelled else {
                return
            }

            // 被拒时通知会静默不发, 这是最常见的"设置开了却收不到"来源, 必须留痕
            AppLog.notification.notice(
                "通知授权结果: status=\(String(describing: status), privacy: .public)"
            )
            authorizationStatus = status
        }
    }

    private func setBool(_ value: Bool, current: inout Bool, key: String) {
        guard value != current else {
            return
        }

        // 八个通知细项都走这里, 用持久化 key 区分是哪一项, 不必逐个 setter 铺日志
        let details = LogFields.joined(
            "key=\(key)",
            "enabled=\(value ? 1 : 0)"
        )
        AppLog.notification.notice("通知选项变更: \(details, privacy: .public)")
        current = value
        defaults.set(value, forKey: key)
    }

    private func setSound(
        _ sound: NotificationSoundOption,
        current: inout NotificationSoundOption,
        key: String
    ) {
        guard sound != current else {
            return
        }

        current = sound
        defaults.set(sound.id, forKey: key)
    }

    private static func bool(from defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }

        return defaults.bool(forKey: key)
    }

    private static func option(_ value: Int?, in options: [Int], defaultValue: Int) -> Int {
        guard let value, options.contains(value) else {
            return defaultValue
        }

        return value
    }

    /// 存量值可能指向本机没有的声音, 例如换了机器或者用户删掉了自定义音, 这时回落默认音
    private static func sound(from defaults: UserDefaults, key: String) -> NotificationSoundOption {
        guard let id = defaults.string(forKey: key),
              let sound = NotificationSoundOption.option(forID: id) else {
            return .systemDefault
        }

        return sound
    }

    private static let enabledKey = "Notification.enabled"
    private static let lowQuotaEnabledKey = "Notification.lowQuotaEnabled"
    private static let quotaResetEnabledKey = "Notification.quotaResetEnabled"
    private static let taskCompletionEnabledKey = "Notification.taskCompletionEnabled"
    private static let taskWaitingEnabledKey = "Notification.taskWaitingEnabled"
    private static let taskHapticEnabledKey = "Notification.taskHapticEnabled"
    private static let creditExpiryEnabledKey = "Notification.creditExpiryEnabled"
    private static let autoResetEnabledKey = "Notification.autoResetEnabled"
    private static let lowBatteryEnabledKey = "Notification.lowBatteryEnabled"
    private static let keepAliveLimitEnabledKey = "Notification.keepAliveLimitEnabled"
    private static let lowQuotaThresholdKey = "Notification.lowQuotaThresholdPercent"
    private static let taskCompletionMinimumDurationKey = "Notification.taskCompletionMinimumDurationSeconds"
    private static let lowQuotaSoundKey = "Notification.lowQuotaSound"
    private static let quotaResetSoundKey = "Notification.quotaResetSound"
    private static let taskCompletionSoundKey = "Notification.taskCompletionSound"
    private static let taskWaitingSoundKey = "Notification.taskWaitingSound"
    private static let creditExpirySoundKey = "Notification.creditExpirySound"
    private static let autoResetSoundKey = "Notification.autoResetSound"
    private static let lowBatterySoundKey = "Notification.lowBatterySound"
    private static let keepAliveLimitSoundKey = "Notification.keepAliveLimitSound"
}
