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

    /// 统计维护挂在额度刷新完成事件上, 由它继承本次刷新的触发来源
    private(set) var lastRefreshTrigger: LogTrigger = .launch

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

    func refreshIfNeeded(trigger: LogTrigger) {
        guard Date().timeIntervalSince(autoRefreshCountdownStartedAt ?? .distantPast) > Self.refreshInterval else {
            return
        }

        refresh(trigger: trigger)
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else {
            return
        }

        autoRefreshTask = Task { [weak self] in
            self?.refreshIfNeeded(trigger: .launch)

            // 每轮按剩余时间等待, 手动刷新后倒计时会自然重新对齐
            while !Task.isCancelled {
                let delay = self?.autoRefreshDelay ?? Self.refreshInterval
                if await (try? Task.sleep(for: .seconds(delay))) == nil {
                    break
                }

                self?.refreshIfNeeded(trigger: .auto)
            }
        }
    }

    func refresh(trigger: LogTrigger) {
        guard !isRefreshing else {
            return
        }

        lastRefreshTrigger = trigger
        AppLog.app.notice("额度刷新开始: trigger=\(trigger.rawValue, privacy: .public)")
        let duration = LogDuration()

        refreshCoordinator.run(
            setRefreshing: { [weak self] in self?.isRefreshing = $0 },
            operation: { [service = self.service] in
                await (fetch: service.fetchOutcome(), connectionInfo: service.currentConnectionInfo())
            },
            commit: { [weak self] result in
                guard let self else {
                    return
                }

                switch result.fetch.outcome {
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

                // 只记各步结果分类, 额度与用量是用户数据, 不进系统日志
                // RPC 层面的请求响应细节仍然只进日志窗口
                logRefreshOutcome(
                    trigger: trigger,
                    trace: result.fetch.trace,
                    elapsed: duration.elapsed
                )
                codexConnectionInfo = result.connectionInfo
                autoRefreshCountdownStartedAt = Date()
            }
        )
    }

    /// 成功路径把各步结果压进一条, 失败才带上定位到哪一步
    private func logRefreshOutcome(
        trigger: LogTrigger,
        trace: CodexFetchTrace,
        elapsed: String
    ) {
        let triggerName = trigger.rawValue
        let state = String(describing: loadState)
        switch loadState {
        case .loaded:
            let connection = trace.connection?.rawValue ?? "-"
            let account = trace.account?.rawValue ?? "-"
            let rateLimits = trace.rateLimits?.rawValue ?? "-"
            let usage = trace.usage?.rawValue ?? "-"
            let resetCredits = trace.resetCredits?.rawValue ?? "-"
            let details = LogFields.joined(
                "trigger=\(triggerName)",
                "state=\(state)",
                "conn=\(connection)",
                "account=\(account)",
                "rateLimits=\(rateLimits)",
                "usage=\(usage)",
                "reset=\(resetCredits)",
                "elapsed=\(elapsed)"
            )
            AppLog.app.notice("额度刷新完成: \(details, privacy: .public)")
        case .notLoggedIn:
            // 未登录是正常状态, 混进失败词根会让每分钟一条噪声盖掉真故障
            let details = LogFields.joined(
                "trigger=\(triggerName)",
                "reason=notLoggedIn",
                "elapsed=\(elapsed)"
            )
            AppLog.app.notice("额度刷新已跳过: \(details, privacy: .public)")
        case .initializationFailed, .loading:
            let stage = trace.failureStage?.rawValue ?? "-"
            let details = LogFields.joined(
                "trigger=\(triggerName)",
                "stage=\(stage)",
                "state=\(state)",
                "elapsed=\(elapsed)"
            )
            AppLog.app.error("额度刷新失败: \(details, privacy: .public)")
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
