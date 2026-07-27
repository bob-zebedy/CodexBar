import Combine
import Foundation
import os

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

/// 菜单面板主状态模型, 将服务层结果转换为 SwiftUI 可发布状态
@MainActor
final class CodexStatusViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadState: CodexLoadState = .loading
    @Published private(set) var codexConnectionInfo: CodexCLIConnectionInfo?
    @Published private(set) var autoRefreshCountdownStartedAt: Date?

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

            // 每轮按剩余时间休眠, 手动刷新后倒计时会自然重新对齐
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

        refreshCoordinator.run(
            setRefreshing: { [weak self] in self?.isRefreshing = $0 },
            operation: { [service = self.service] in
                await (outcome: service.fetchOutcome(), connectionInfo: service.currentConnectionInfo())
            },
            commit: { [weak self] result in
                guard let self else {
                    return
                }

                switch result.outcome {
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

                // 只记结果分类, 额度与用量是用户数据, 不进系统日志
                // RPC 层面的请求响应细节仍然只进日志窗口
                let state = loadState
                AppLog.app.notice("额度信息刷新完成: state=\(String(describing: state), privacy: .public)")
                codexConnectionInfo = result.connectionInfo
                autoRefreshCountdownStartedAt = Date()
            }
        )
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
