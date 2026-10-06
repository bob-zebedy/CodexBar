import CloudKit
import Combine
import Foundation
import os

/// 设置页的跨设备同步状态
@MainActor
final class SyncSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var syncFailureMessage: String?
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var syncAvailability = SyncAvailability.unknown

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
        if !enabled {
            clearSyncActivity()
        }
        isEnabled = enabled
        lastUploadAt = Self.loadLastUploadAt()
        return previousValue != enabled
    }

    var isSyncAvailable: Bool {
        syncAvailability.isAvailable
    }

    var hasSyncFailure: Bool {
        syncFailureMessage != nil
    }

    func activation(isSyncAvailable: Bool? = nil) -> SyncActivation {
        guard isEnabled else { return .syncOff }
        guard isSyncAvailable ?? self.isSyncAvailable else { return .unavailable }
        return .active
    }

    var isEffectivelyActive: Bool {
        activation().isActive
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

    private func observeSyncNotifications() {
        NotificationCenter.default.publisher(for: .syncDidStart)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleSyncDidStart()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .syncDidFinish)
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
        let didSucceed = notification.userInfo?[SyncNotificationKey.didSucceed] as? Bool ?? true
        let failureMessage = notification.userInfo?[SyncNotificationKey.failureMessage] as? String

        isSyncing = false
        if didSucceed {
            clearSyncFailure()
        } else {
            applySyncFailure(failureMessage)
        }
        lastUploadAt = Self.loadLastUploadAt()
    }

    private func applyAvailabilityResult(_ result: SyncAvailabilityResult) {
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
        syncFailureMessage = nil
    }

    private func applySyncFailure(_ message: String?) {
        syncFailureMessage = isEnabled
            ? message ?? SyncFailureReason.retryLater.message
            : nil
    }

    private nonisolated static func querySyncAvailability() async -> SyncAvailabilityResult {
        await withCheckedContinuation { continuation in
            SyncCloudKit.makeContainer().accountStatus { status, error in
                continuation.resume(
                    returning: SyncFailureReason.availabilityResult(
                        status: status,
                        error: error
                    )
                )
            }
        }
    }

    private nonisolated static func loadLastUploadAt() -> Date? {
        SyncService.loadLastUploadAt()
    }

    private nonisolated static let enabledKey = "Sync.isEnabled"
}

/// 同步没生效时缺的是哪一项, 同时充当日志里的 reason= 取值
nonisolated enum SyncActivation: String {
    case active
    case syncOff
    case unavailable

    var isActive: Bool {
        self == .active
    }
}

nonisolated enum SyncAvailability: Equatable {
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

nonisolated struct SyncAvailabilityResult {
    let availability: SyncAvailability
    let failureReason: SyncFailureReason?

    static let available = SyncAvailabilityResult(
        availability: .available,
        failureReason: nil
    )

    static func unavailable(
        _ failureReason: SyncFailureReason
    ) -> SyncAvailabilityResult {
        SyncAvailabilityResult(
            availability: .unavailable,
            failureReason: failureReason
        )
    }
}

extension Notification.Name {
    nonisolated static let syncDidStart = Notification.Name("CodexBar.syncDidStart")
    nonisolated static let syncDidFinish = Notification.Name("CodexBar.syncDidFinish")
}

nonisolated enum SyncNotificationKey {
    static let didSucceed = "didSucceed"
    static let failureMessage = "failureMessage"
}

nonisolated enum SyncFailureReason: String {
    case networkUnavailable
    case accountUnavailable
    case serviceUnavailable
    case retryLater

    var message: String {
        switch self {
        case .networkUnavailable:
            String(localized: "sync.icloud.error.network-unavailable")
        case .accountUnavailable:
            String(localized: "sync.icloud.error.account-unavailable")
        case .serviceUnavailable:
            String(localized: "sync.icloud.error.service-unavailable")
        case .retryLater:
            String(localized: "sync.error.retry-later")
        }
    }
}

nonisolated extension SyncFailureReason {
    static func classify(_ error: Error) -> SyncFailureReason {
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
    ) -> SyncAvailabilityResult {
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
