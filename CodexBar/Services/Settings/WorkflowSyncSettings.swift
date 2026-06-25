import CloudKit
import Combine
import Foundation

/// 设置页的工作流统计 iCloud 同步状态
@MainActor
final class WorkflowSyncSettings: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isSyncing = false
    @Published private(set) var lastUploadAt: Date?
    @Published private(set) var iCloudAvailability = WorkflowSyncAvailability.unknown

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var accountStatusTask: Task<Void, Never>?
    private var accountStatusGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        lastUploadAt = Self.loadLastUploadAt()
        observeSyncNotifications()
        refreshICloudAvailability()
    }

    deinit {
        accountStatusTask?.cancel()
    }

    func refresh() {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        lastUploadAt = Self.loadLastUploadAt()
        refreshICloudAvailability()
    }

    func setEnabled(_ enabled: Bool) {
        guard !enabled || iCloudAvailability.isAvailable else {
            return
        }

        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled {
            defaults.set(true, forKey: Self.needsBackfillKey)
        }
        isEnabled = enabled
        lastUploadAt = Self.loadLastUploadAt()
    }

    var isICloudAvailable: Bool {
        iCloudAvailability.isAvailable
    }

    var unavailableMessage: String? {
        iCloudAvailability.isUnavailable ? "iCloud 不可用" : nil
    }

    var lastUploadAtText: String? {
        guard let lastUploadAt else {
            return nil
        }
        return Self.lastUploadAtFormatter.string(from: lastUploadAt)
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
        NotificationCenter.default.publisher(for: .workflowStatsICloudSyncDidStart)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.isSyncing = true
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workflowStatsICloudSyncDidFinish)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.isSyncing = false
                    self?.lastUploadAt = Self.loadLastUploadAt()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshICloudAvailability() {
        accountStatusGeneration += 1
        let generation = accountStatusGeneration

        accountStatusTask?.cancel()
        accountStatusTask = Task { @MainActor [weak self] in
            let isAvailable = await Self.queryICloudAvailability()
            guard let self,
                  !Task.isCancelled,
                  generation == accountStatusGeneration else {
                return
            }

            iCloudAvailability = isAvailable ? .available : .unavailable
            if !isAvailable {
                isSyncing = false
            }
        }
    }

    private nonisolated static func queryICloudAvailability() async -> Bool {
        await withCheckedContinuation { continuation in
            CKContainer.default().accountStatus { status, _ in
                continuation.resume(returning: status == .available)
            }
        }
    }

    private nonisolated static func loadLastUploadAt() -> Date? {
        let stateURL = WorkflowStatsStorage.iCloudSyncDirectoryURL()
            .appendingPathComponent("state.json", isDirectory: false)
        guard let data = try? Data(contentsOf: stateURL), !data.isEmpty,
              let state = try? JSONDecoder().decode(LocalSyncState.self, from: data) else {
            return nil
        }
        return state.lastUploadAt
    }

    private static let lastUploadAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private nonisolated static let enabledKey = "WorkflowiCloudSync.isEnabled"
    private nonisolated static let needsBackfillKey = "WorkflowiCloudSync.needsBackfill"

    private nonisolated struct LocalSyncState: Decodable {
        let lastUploadAt: Date?
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

extension Notification.Name {
    nonisolated static let workflowStatsICloudSyncDidStart = Notification.Name("CodexBar.workflowStatsICloudSyncDidStart")
    nonisolated static let workflowStatsICloudSyncDidFinish = Notification.Name("CodexBar.workflowStatsICloudSyncDidFinish")
}
