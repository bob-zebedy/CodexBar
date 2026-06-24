import Combine
import Foundation

/// UI 级状态; 更细的连接和接口错误由服务层归并到日志
nonisolated enum CodexLoadState: Equatable {
    case loading
    case loaded
    case notLoggedIn
    case initializationFailed

    var isError: Bool {
        switch self {
        case .notLoggedIn, .initializationFailed: true
        case .loading, .loaded: false
        }
    }
}

@MainActor
final class CodexStatusViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadState: CodexLoadState = .loading
    @Published private(set) var codexConnectionInfo: CodexCLIConnectionInfo?
    @Published private(set) var autoRefreshCountdownStartedAt: Date?

    var hasError: Bool {
        loadState.isError
    }

    var hasUntrustedData: Bool {
        snapshot?.hasTrustedData == false
    }

    var usesErrorImage: Bool {
        hasError || hasUntrustedData
    }

    var autoRefreshInterval: TimeInterval {
        Self.refreshInterval
    }

    private static let refreshInterval: TimeInterval = 60

    private let service: CodexStatusService
    private var autoRefreshTask: Task<Void, Never>?
    private let refreshCoordinator = RefreshTaskCoordinator()

    init(service: CodexStatusService = CodexStatusService()) {
        self.service = service
    }

    deinit {
        autoRefreshTask?.cancel()
        refreshCoordinator.cancel()
    }

    func refreshIfNeeded() {
        guard Date().timeIntervalSince(autoRefreshCountdownStartedAt ?? .distantPast) > Self.refreshInterval else {
            return
        }

        refresh()
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            self?.refreshIfNeeded()

            while !Task.isCancelled {
                let delay = self?.autoRefreshDelay ?? Self.refreshInterval
                if await (try? Task.sleep(for: .seconds(delay))) == nil {
                    break
                }

                self?.refreshIfNeeded()
            }
        }
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true

        refreshCoordinator.start { [weak self] generation in
            guard let self else {
                return
            }

            defer {
                self.refreshCoordinator.finish(generation) {
                    self.isRefreshing = false
                }
            }

            let outcome = await service.fetchOutcome()
            let connectionInfo = await service.currentConnectionInfo()

            guard refreshCoordinator.canCommit(generation) else {
                return
            }

            switch outcome {
            case let .data(snapshot):
                self.snapshot = snapshot
                loadState = .loaded
            case .notLoggedIn:
                snapshot = nil
                loadState = .notLoggedIn
            case .initializationFailed:
                snapshot = nil
                loadState = .initializationFailed
            }

            codexConnectionInfo = connectionInfo
            autoRefreshCountdownStartedAt = Date()
        }
    }

    func refreshCodexConnectionInfo() {
        Task {
            self.codexConnectionInfo = await service.currentConnectionInfo()
        }
    }

    private var autoRefreshDelay: TimeInterval {
        guard let autoRefreshCountdownStartedAt else {
            return Self.refreshInterval
        }

        let remaining = Self.refreshInterval - Date().timeIntervalSince(autoRefreshCountdownStartedAt)
        return max(1, remaining)
    }
}
