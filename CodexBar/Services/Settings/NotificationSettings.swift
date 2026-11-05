import AppKit
import Combine
import Foundation
import os
import UserNotifications

/// 管理通知偏好和系统授权状态
/// 具体的通知发送与触觉反馈由 NotificationService 处理
@MainActor
final class NotificationSettings: ObservableObject {
    enum AuthorizationState: Equatable {
        case unknown
        case notDetermined
        case denied
        case authorized
        case unavailable
    }

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
    @Published private(set) var authorizationState: AuthorizationState = .unknown

    /// 查询异常不代表用户关闭了权限, 只有明确未授权时才显示系统设置引导
    var needsAuthorization: Bool {
        isEnabled && (authorizationState == .notDetermined || authorizationState == .denied)
    }

    var authorizationMessage: String? {
        guard isEnabled else { return nil }
        switch authorizationState {
        case .notDetermined, .denied:
            return String(localized: "settings.notifications.system.permission-disabled")
        case .unavailable:
            return String(localized: "settings.notifications.system.permission-unavailable")
        case .unknown, .authorized:
            return nil
        }
    }

    /// 总开关开启且系统已明确允许时才发送, 未决定或未知状态都按不可发送处理
    var canDeliver: Bool {
        isEnabled && authorizationState == .authorized
    }

    /// 触觉反馈不依赖系统通知授权, 但服从 App 内通知总开关
    var canPerformTaskHapticFeedback: Bool {
        isEnabled && isTaskHapticEnabled
    }

    var canShowOptions: Bool {
        canDeliver
    }

    static let lowQuotaThresholdOptions = [5, 10, 25]
    static let taskCompletionDurationOptions = [30, 60, 120, 300]

    private let defaults: UserDefaults
    private let readAuthorizationStatus: () async -> UNAuthorizationStatus
    private let requestSystemAuthorization: () async throws -> Bool
    private let sleep: (Duration) async throws -> Void
    private var authorizationRefreshTask: Task<Void, Never>?
    private var authorizationRequestTask: Task<Void, Never>?
    private var requestsAuthorizationIfNeeded = false
    private var appActivationObserver: AnyCancellable?

    init(
        defaults: UserDefaults = .standard,
        readAuthorizationStatus: @escaping () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        requestSystemAuthorization: @escaping () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        },
        sleep: @escaping (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.defaults = defaults
        self.readAuthorizationStatus = readAuthorizationStatus
        self.requestSystemAuthorization = requestSystemAuthorization
        self.sleep = sleep
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
        appActivationObserver = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshAuthorizationStatus()
            }
    }

    deinit {
        authorizationRefreshTask?.cancel()
        authorizationRequestTask?.cancel()
    }

    // MARK: - 偏好设置

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else {
            return
        }

        AppLog.notification.notice("通知总开关变更: enabled=\(enabled ? 1 : 0)")
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        requestsAuthorizationIfNeeded = enabled
        if enabled {
            refreshAuthorizationStatus()
        } else {
            authorizationRefreshTask?.cancel()
            authorizationRefreshTask = nil
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

    // MARK: - 系统授权

    /// 用户可能在系统设置里改过权限, 回到 App 时需要重新读取
    func refreshAuthorizationStatus() {
        // 系统授权弹窗也会改变 App 与窗口焦点, 查询不能取消正在等待用户回应的请求
        guard authorizationRequestTask == nil else {
            return
        }
        authorizationRefreshTask?.cancel()
        authorizationRefreshTask = Task { @MainActor [weak self, readAuthorizationStatus, sleep] in
            for delay: Duration in [.zero, .seconds(1), .seconds(3), .seconds(10)] {
                do {
                    if delay > .zero {
                        try await sleep(delay)
                    }
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let status = await readAuthorizationStatus()
                guard let self, !Task.isCancelled else { return }

                acceptAuthorizationStatus(status)
                let shouldRequest = requestsAuthorizationIfNeeded
                requestsAuthorizationIfNeeded = false
                if shouldRequest, isEnabled, authorizationState == .notDetermined {
                    requestAuthorization()
                    return
                }
                guard isEnabled, case .unavailable = authorizationState else {
                    authorizationRefreshTask = nil
                    return
                }
            }
            self?.authorizationRefreshTask = nil
        }
    }

    private func acceptAuthorizationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            updateAuthorizationState(.authorized)
        case .denied:
            updateAuthorizationState(.denied)
        case .notDetermined:
            switch authorizationState {
            case .unknown, .notDetermined:
                updateAuthorizationState(.notDetermined)
            case .authorized, .denied, .unavailable:
                // 系统服务重启后可能把已决定的权限读成未决定, 不能据此再次申请
                updateAuthorizationState(.unavailable)
            }
        @unknown default:
            updateAuthorizationState(.unavailable)
        }
    }

    private func updateAuthorizationState(_ state: AuthorizationState) {
        guard state != authorizationState else { return }
        let details = LogFields.joined(
            "from=\(String(describing: authorizationState))",
            "to=\(String(describing: state))"
        )
        AppLog.notification.notice("通知授权变化: \(details, privacy: .public)")
        authorizationState = state
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
        guard isEnabled, authorizationRequestTask == nil else {
            return
        }
        authorizationRefreshTask?.cancel()
        authorizationRefreshTask = nil
        authorizationRequestTask = Task { @MainActor [weak self, requestSystemAuthorization] in
            do {
                let granted = try await requestSystemAuthorization()
                guard let self, !Task.isCancelled else { return }
                acceptAuthorizationStatus(granted ? .authorized : .denied)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let error = error as NSError
                AppLog.notification.error("通知授权请求失败: domain=\(error.domain, privacy: .public); code=\(error.code)")
                updateAuthorizationState(.unavailable)
            }
            guard let self, !Task.isCancelled else {
                return
            }

            authorizationRequestTask = nil
            refreshAuthorizationStatus()
        }
    }

    // MARK: - 偏好读写

    private func setBool(_ value: Bool, current: inout Bool, key: String) {
        guard value != current else {
            return
        }

        // 分类通知统一在这里记录日志, 用持久化 key 区分设置项
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

    /// 已保存的选项可能指向已移除或不再支持的声音, 此时回退到默认音
    private static func sound(from defaults: UserDefaults, key: String) -> NotificationSoundOption {
        guard let id = defaults.string(forKey: key),
              let sound = NotificationSoundOption.option(forID: id) else {
            return .systemDefault
        }

        return sound
    }

    private static let enabledKey = "Notification.isEnabled"
    private static let lowQuotaEnabledKey = "Notification.isLowQuotaEnabled"
    private static let quotaResetEnabledKey = "Notification.isQuotaResetEnabled"
    private static let taskCompletionEnabledKey = "Notification.isTaskCompletionEnabled"
    private static let taskWaitingEnabledKey = "Notification.isTaskWaitingEnabled"
    private static let taskHapticEnabledKey = "Notification.isTaskHapticEnabled"
    private static let creditExpiryEnabledKey = "Notification.isCreditExpiryEnabled"
    private static let autoResetEnabledKey = "Notification.isAutoResetEnabled"
    private static let lowBatteryEnabledKey = "Notification.isLowBatteryEnabled"
    private static let keepAliveLimitEnabledKey = "Notification.isKeepAliveLimitEnabled"
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
