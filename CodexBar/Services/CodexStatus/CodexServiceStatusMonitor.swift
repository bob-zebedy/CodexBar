import Combine
import Foundation

@MainActor
final class CodexServiceStatusMonitor: ObservableObject {
    enum State: Equatable {
        case checking
        case available(CodexServiceStatus)
        case unavailable
    }

    @Published private(set) var state: State = .checking
    private let fetch: @Sendable () async throws -> CodexServiceStatus
    private var refreshInterval: Duration
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: ContinuousClock.Instant?

    private var nextRefresh: ContinuousClock.Instant? {
        lastRefresh?.advanced(by: refreshInterval)
    }

    convenience init() {
        let service = CodexServiceStatusService()
        self.init(fetch: { try await service.fetch() })
    }

    init(refreshInterval: Duration = .seconds(60), fetch: @escaping @Sendable () async throws -> CodexServiceStatus) {
        self.refreshInterval = refreshInterval
        self.fetch = fetch
    }

    deinit {
        refreshTask?.cancel()
    }

    func setActive(_ active: Bool, refreshInterval: Duration) {
        let intervalChanged = self.refreshInterval != refreshInterval
        self.refreshInterval = refreshInterval
        if !active || intervalChanged {
            refreshTask?.cancel()
            refreshTask = nil
        }
        guard active, refreshTask == nil else { return }
        if nextRefresh.map({ $0 <= .now }) ?? true {
            state = .checking
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if let deadline = self?.nextRefresh {
                    do { try await Task.sleep(until: deadline, clock: ContinuousClock()) } catch { return }
                }
                guard !Task.isCancelled, let self else { return }
                await refresh()
            }
        }
    }

    private func refresh() async {
        do {
            let status = try await fetch()
            try Task.checkCancellation()
            lastRefresh = .now
            state = .available(status)
        } catch {
            // 隐藏后取消的旧请求不能覆盖重开面板后的结果
            guard !Task.isCancelled else { return }
            lastRefresh = .now
            state = .unavailable
        }
    }
}
