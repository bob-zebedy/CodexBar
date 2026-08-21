import CloudKit
import Combine
import Foundation
import os

/// 设置页的工作流同步状态
@MainActor
final class WorkflowSyncSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var hasSyncFailure = false
    @Published private(set) var syncFailureMessage: String?
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var syncAvailability = WorkflowSyncAvailability.unknown

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private let accountStatusCoordinator = RefreshTaskCoordinator()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = Self.isEnabled(defaults: defaults)
        lastUploadAt = Self.loadLastUploadAt()
        observeSyncNotifications()
        refreshSyncAvailability()
    }

    func refresh() {
        isEnabled = Self.isEnabled(defaults: defaults)
        if !isEnabled {
            clearSyncActivity()
        }
        lastUploadAt = Self.loadLastUploadAt()
        refreshSyncAvailability()
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard !enabled || syncAvailability.isAvailable else {
            return false
        }

        let previousValue = isEnabled
        if previousValue != enabled {
            AppLog.sync.notice("同步开关变更: enabled=\(enabled ? 1 : 0)")
        }
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            defaults.set(true, forKey: Self.needsBackfillKey)
        } else {
            clearSyncActivity()
        }
        isEnabled = enabled
        lastUploadAt = Self.loadLastUploadAt()
        return previousValue != enabled
    }

    var isSyncAvailable: Bool {
        syncAvailability.isAvailable
    }

    /// "同步是否实际生效"的唯一判定: Hook 已启用且同步开关打开且 iCloud 可用
    /// 按顺序返回第一个不满足的项, 日志的 reason= 直接取它的 rawValue
    func activation(isHookEnabled: Bool) -> WorkflowSyncActivation {
        activation(isHookEnabled: isHookEnabled, isSyncAvailable: isSyncAvailable)
    }

    /// 两项依赖都可以由调用方指定
    /// @Published 的订阅回调跑在 willSet, 那时属性还是旧值, 只有回调参数是新值
    func activation(
        isHookEnabled: Bool,
        isSyncAvailable: Bool
    ) -> WorkflowSyncActivation {
        if !isHookEnabled {
            return .hookOff
        }
        if !isEnabled {
            return .syncOff
        }
        if !isSyncAvailable {
            return .unavailable
        }
        return .active
    }

    func isEffectivelyActive(isHookEnabled: Bool) -> Bool {
        activation(isHookEnabled: isHookEnabled).isActive
    }

    var unavailableMessage: String? {
        syncAvailability.isUnavailable ? String(localized: "sync.status.unavailable") : nil
    }

    var lastUploadAtText: String? {
        guard let lastUploadAt else {
            return nil
        }
        return CodexDateFormat.localDisplayString(from: lastUploadAt)
    }

    nonisolated static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    nonisolated static func needsBackfill(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: needsBackfillKey)
    }

    nonisolated static func clearBackfillRequest(defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: needsBackfillKey)
    }

    private func observeSyncNotifications() {
        NotificationCenter.default.publisher(for: .workflowSyncDidStart)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleSyncDidStart()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowSyncDidFinish)
            .sink { [weak self] notification in
                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    self.handleSyncDidFinish(notification)
                }
            }
            .store(in: &cancellables)
    }

    private func refreshSyncAvailability() {
        accountStatusCoordinator.start { [weak self] generation in
            let result = await Self.querySyncAvailability()
            guard let self,
                  accountStatusCoordinator.canCommit(generation) else {
                return
            }

            applyAvailabilityResult(result)
            accountStatusCoordinator.finish(generation) {}
        }
    }

    private func handleSyncDidStart() {
        isSyncing = true
        clearSyncFailure()
    }

    private func handleSyncDidFinish(_ notification: Notification) {
        let didSucceed = notification.userInfo?[WorkflowSyncNotificationKey.didSucceed] as? Bool ?? true
        let failureMessage = notification.userInfo?[WorkflowSyncNotificationKey.failureMessage] as? String

        isSyncing = false
        if didSucceed {
            clearSyncFailure()
        } else {
            applySyncFailure(failureMessage)
        }
        lastUploadAt = Self.loadLastUploadAt()
    }

    private func applyAvailabilityResult(_ result: WorkflowSyncAvailabilityResult) {
        syncAvailability = result.availability
        guard result.availability.isUnavailable else {
            return
        }

        isSyncing = false
        applySyncFailure(result.failureReason?.message)
    }

    private func clearSyncActivity() {
        isSyncing = false
        clearSyncFailure()
    }

    private func clearSyncFailure() {
        hasSyncFailure = false
        syncFailureMessage = nil
    }

    private func applySyncFailure(_ message: String?) {
        hasSyncFailure = isEnabled
        syncFailureMessage = isEnabled
            ? message ?? WorkflowSyncFailureReason.retryLater.message
            : nil
    }

    private nonisolated static func querySyncAvailability() async -> WorkflowSyncAvailabilityResult {
        await withCheckedContinuation { continuation in
            WorkflowSyncCloudKit.makeContainer().accountStatus { status, error in
                continuation.resume(
                    returning: WorkflowSyncFailureReason.availabilityResult(
                        status: status,
                        error: error
                    )
                )
            }
        }
    }

    private nonisolated static func loadLastUploadAt() -> Date? {
        WorkflowSyncService.loadLastUploadAt()
    }

    private nonisolated static let enabledKey = "WorkflowSync.isEnabled"
    private nonisolated static let needsBackfillKey = "WorkflowSync.needsBackfill"
}

/// 同步没生效时缺的是哪一项, 同时充当日志里的 reason= 取值
nonisolated enum WorkflowSyncActivation: String {
    case active
    case hookOff
    case syncOff
    case unavailable

    var isActive: Bool {
        self == .active
    }
}

nonisolated enum WorkflowSyncAvailability: Equatable {
    case unknown
    case available
    case unavailable

    var isAvailable: Bool {
        self == .available
    }

    var isUnavailable: Bool {
        self == .unavailable
    }
}

nonisolated struct WorkflowSyncAvailabilityResult {
    let availability: WorkflowSyncAvailability
    let failureReason: WorkflowSyncFailureReason?

    static let available = WorkflowSyncAvailabilityResult(
        availability: .available,
        failureReason: nil
    )

    static func unavailable(
        _ failureReason: WorkflowSyncFailureReason
    ) -> WorkflowSyncAvailabilityResult {
        WorkflowSyncAvailabilityResult(
            availability: .unavailable,
            failureReason: failureReason
        )
    }
}

extension Notification.Name {
    nonisolated static let workflowSyncDidStart = Notification.Name("CodexBar.workflowSyncDidStart")
    nonisolated static let workflowSyncDidFinish = Notification.Name("CodexBar.workflowSyncDidFinish")
}

nonisolated enum WorkflowSyncNotificationKey {
    static let didSucceed = "didSucceed"
    static let failureMessage = "failureMessage"
}

nonisolated enum WorkflowSyncFailureReason: String {
    case networkUnavailable
    case accountUnavailable
    case serviceUnavailable
    case retryLater

    var message: String {
        switch self {
        case .networkUnavailable:
            String(localized: "sync.error.network-unavailable")
        case .accountUnavailable:
            String(localized: "sync.error.account-unavailable")
        case .serviceUnavailable:
            String(localized: "sync.error.service-unavailable")
        case .retryLater:
            String(localized: "sync.error.retry-later")
        }
    }
}

nonisolated extension WorkflowSyncFailureReason {
    static func classify(_ error: Error) -> WorkflowSyncFailureReason {
        guard let error = error as? CKError else {
            return .retryLater
        }

        switch error.code {
        case .networkUnavailable, .networkFailure:
            return .networkUnavailable
        case .notAuthenticated, .permissionFailure:
            return .accountUnavailable
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .serviceUnavailable
        default:
            return .retryLater
        }
    }

    static func availabilityResult(
        status: CKAccountStatus,
        error: Error?
    ) -> WorkflowSyncAvailabilityResult {
        if let error {
            return .unavailable(classify(error))
        }

        switch status {
        case .available:
            return .available
        case .noAccount, .restricted:
            return .unavailable(.accountUnavailable)
        case .temporarilyUnavailable:
            return .unavailable(.serviceUnavailable)
        case .couldNotDetermine:
            return .unavailable(.retryLater)
        @unknown default:
            return .unavailable(.retryLater)
        }
    }
}
