import Combine
import Foundation
import os

nonisolated enum DataUpdateInterval: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case twoMinutes = 120
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var duration: TimeInterval {
        TimeInterval(rawValue)
    }

    var title: String {
        String(localized: "duration.minutes", defaultValue: "\(rawValue / 60, specifier: "%lld")")
    }

    func remainingTime(since startedAt: Date?, now: Date) -> TimeInterval {
        guard let startedAt else {
            return 0
        }

        return max(0, duration - now.timeIntervalSince(startedAt))
    }
}

/// UI 级状态; 更细的连接和接口错误由服务层归并到日志
nonisolated enum CodexLoadState: Equatable {
    case loading
    case loaded
    case notLoggedIn
    case unsupportedVersion(minimum: String)
    case initializationFailed

    var isError: Bool {
        switch self {
        case .notLoggedIn, .unsupportedVersion, .initializationFailed: true
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
    @Published private(set) var codexConnectionInfo: CodexServerConnectionInfo?
    @Published private(set) var autoRefreshCountdownStartedAt: Date?
    @Published private(set) var dataUpdateInterval: DataUpdateInterval

    /// 统计维护挂在额度刷新完成事件上, 由它继承本次刷新的触发来源
    private(set) var lastRefreshTrigger: LogTrigger = .launch

    @Published private(set) var isReconnecting = false

    var autoRefreshInterval: TimeInterval {
        dataUpdateInterval.duration
    }

    private static let dataUpdateIntervalKey = "DataUpdate.intervalSeconds"

    private let fetchResults = CurrentValueSubject<CodexFetchOutcome?, Never>(nil)
    var fetchOutcomes: AnyPublisher<CodexFetchOutcome, Never> {
        fetchResults.compactMap(\.self).eraseToAnyPublisher()
    }

    private let service: CodexStatusService
    private let defaults: UserDefaults
    private var autoRefreshTask: Task<Void, Never>?
    private var pendingRefreshTask: Task<Void, Never>?
    private var accountNotificationTask: Task<Void, Never>?
    private var notificationRefreshTask: Task<Void, Never>?
    private var notificationSchedule = AccountNotificationSchedule()
    private var pendingForcedRefreshTrigger: LogTrigger?
    private let refreshCoordinator = RefreshTaskCoordinator()
    private var connectionInfoGeneration: UInt64 = 0

    init(service: CodexStatusService = CodexStatusService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        dataUpdateInterval = (defaults.object(forKey: Self.dataUpdateIntervalKey) as? Int)
            .flatMap(DataUpdateInterval.init(rawValue:)) ?? .oneMinute
    }

    deinit {
        autoRefreshTask?.cancel()
        accountNotificationTask?.cancel()
        notificationRefreshTask?.cancel()
        pendingRefreshTask?.cancel()
        refreshCoordinator.cancel()
    }

    func refreshIfNeeded(trigger: LogTrigger) {
        guard dataUpdateInterval.remainingTime(since: autoRefreshCountdownStartedAt, now: Date()) == 0 else {
            return
        }

        refresh(trigger: trigger)
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else {
            return
        }

        startAccountNotifications()
        refreshAfterCurrent(trigger: .launch)
        scheduleAutoRefresh()
    }

    func setDataUpdateInterval(_ interval: DataUpdateInterval) {
        guard dataUpdateInterval != interval else {
            return
        }

        defaults.set(interval.rawValue, forKey: Self.dataUpdateIntervalKey)
        dataUpdateInterval = interval
        AppLog.settings.notice("数据更新间隔变更: seconds=\(interval.rawValue)")
        if autoRefreshTask != nil {
            scheduleAutoRefresh()
        }
    }

    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            // 每轮按剩余时间等待, 手动刷新后倒计时会自然重新对齐
            while !Task.isCancelled {
                guard let delay = self?.autoRefreshDelay else {
                    break
                }
                if await (try? Task.sleep(for: .seconds(delay))) == nil {
                    break
                }

                self?.refreshIfNeeded(trigger: .auto)
            }
        }
    }

    func refresh(trigger: LogTrigger) {
        guard !isRefreshing, !isReconnecting else {
            return
        }

        // 持续推送和慢查询不能挤占已到期的定时维护
        let trigger = trigger == .accountNotification && autoRefreshTask != nil
            && dataUpdateInterval.remainingTime(since: autoRefreshCountdownStartedAt, now: Date()) == 0 ? .auto : trigger
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
        notificationSchedule.didStartRefresh(at: .now)
        lastRefreshTrigger = trigger
        AppLog.app.notice("额度刷新开始: trigger=\(trigger.rawValue, privacy: .public)")
        let duration = LogDuration()

        refreshCoordinator.run(
            setRefreshing: { [weak self] in self?.setRefreshing($0) },
            operation: { [service = self.service] in
                await (
                    fetch: service.fetchOutcome(),
                    connectionInfo: service.currentConnectionInfo()
                )
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
                case let .unsupportedVersion(minimum):
                    snapshot = nil
                    loadState = .unsupportedVersion(minimum: minimum)
                case .authenticationRequired, .initializationFailed:
                    snapshot = nil
                    loadState = .initializationFailed
                }

                fetchResults.send(result.fetch.outcome)

                // 只记各步结果分类, 额度与用量是用户数据, 不进系统日志
                // RPC 层面的请求响应细节仍然只进日志窗口
                logRefreshOutcome(
                    trigger: trigger,
                    trace: result.fetch.trace,
                    elapsed: duration.elapsed
                )
                codexConnectionInfo = result.connectionInfo
                // 推送只更新账户快照, 定时刷新继续驱动原有历史维护和同步周期
                if trigger != .accountNotification {
                    autoRefreshCountdownStartedAt = Date()
                }
            }
        )
    }

    private func startAccountNotifications() {
        guard accountNotificationTask == nil else { return }
        accountNotificationTask = Task { [weak self, service] in
            while !Task.isCancelled, self != nil {
                let generation = self?.connectionInfoGeneration
                let change = await service.pollAccountChanges()
                guard !Task.isCancelled else { return }
                if generation == self?.connectionInfoGeneration, let change {
                    self?.receiveAccountChange(change)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func receiveAccountChange(_ change: AccountChange) {
        notificationSchedule.receive(change, at: .now)
        scheduleNotificationRefresh()
    }

    private func scheduleNotificationRefresh() {
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
        guard !isRefreshing, !isReconnecting, let deadline = notificationSchedule.readyAt else { return }
        notificationRefreshTask = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled else { return }
            notificationRefreshTask = nil
            refresh(trigger: .accountNotification)
        }
    }

    /// 自动消费完成后不能因为普通刷新正在运行而丢掉最终核对
    func refreshAfterCurrent(trigger: LogTrigger) {
        guard isRefreshing || isReconnecting else {
            refresh(trigger: trigger)
            return
        }

        pendingForcedRefreshTrigger = trigger
    }

    private func setRefreshing(_ refreshing: Bool) {
        isRefreshing = refreshing
        guard !refreshing else { return }
        guard let trigger = pendingForcedRefreshTrigger else {
            scheduleNotificationRefresh()
            return
        }

        pendingForcedRefreshTrigger = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else {
                return
            }

            pendingRefreshTask = nil
            refresh(trigger: trigger)
        }
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
            // 未登录是正常状态, 使用 notice 级别记录刷新跳过原因
            let details = LogFields.joined(
                "trigger=\(triggerName)",
                "reason=notLoggedIn",
                "elapsed=\(elapsed)"
            )
            AppLog.app.notice("额度刷新已跳过: \(details, privacy: .public)")
        case let .unsupportedVersion(minimum):
            let details = LogFields.joined(
                "trigger=\(triggerName)",
                "reason=unsupportedCodexVersion",
                "minimum=\(minimum)",
                "elapsed=\(elapsed)"
            )
            AppLog.app.error("额度刷新失败: \(details, privacy: .public)")
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
        guard !isReconnecting else {
            return
        }
        let generation = connectionInfoGeneration
        Task {
            let info = await service.currentConnectionInfo()
            guard generation == connectionInfoGeneration, !isReconnecting else {
                return
            }
            codexConnectionInfo = info
        }
    }

    func reconnectCodex() async {
        guard !isRefreshing, !isReconnecting else {
            return
        }

        isReconnecting = true
        notificationRefreshTask?.cancel()
        notificationRefreshTask = nil
        notificationSchedule = AccountNotificationSchedule()
        codexConnectionInfo = nil
        snapshot = nil
        loadState = .loading
        connectionInfoGeneration &+= 1
        var didReconnect = false
        defer {
            isReconnecting = false
            let trigger = pendingForcedRefreshTrigger
            pendingForcedRefreshTrigger = nil
            if didReconnect || trigger != nil {
                refresh(trigger: trigger ?? .manual)
            } else {
                scheduleNotificationRefresh()
            }
        }

        do {
            codexConnectionInfo = try await service.reconnect(
                minimumVersion: CodexVersionReader.minimumAppServerVersion
            )
            didReconnect = true
        } catch {
            loadState = switch error {
            case CodexStatusError.notLoggedIn: .notLoggedIn
            case let CodexStatusError.unsupportedVersion(minimum): .unsupportedVersion(minimum: minimum)
            default: .initializationFailed
            }
        }
    }

    private var autoRefreshDelay: TimeInterval {
        guard let autoRefreshCountdownStartedAt else {
            return autoRefreshInterval
        }

        let remaining = dataUpdateInterval.remainingTime(since: autoRefreshCountdownStartedAt, now: Date())
        return max(1, remaining)
    }
}

/// 首条通知固定合并截止时间, 后续通知不能无限延后刷新
nonisolated struct AccountNotificationSchedule {
    private(set) var readyAt: ContinuousClock.Instant?
    private var pending: AccountChange?
    private var lastRefreshStartedAt: ContinuousClock.Instant?

    mutating func receive(_ change: AccountChange, at now: ContinuousClock.Instant) {
        let deadline = now.advanced(by: .seconds(1))
        if change == .account {
            readyAt = min(readyAt ?? deadline, deadline)
        } else if pending == nil {
            readyAt = max(deadline, lastRefreshStartedAt?.advanced(by: .seconds(10)) ?? deadline)
        }
        pending = change.merging(pending)
    }

    mutating func didStartRefresh(at now: ContinuousClock.Instant) {
        readyAt = nil
        pending = nil
        lastRefreshStartedAt = now
    }
}
