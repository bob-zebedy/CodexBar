import Combine
import Foundation

// UI 级状态; 更细的连接和接口错误由服务层归并到日志
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
    
    var hasError: Bool { loadState.isError }
    var autoRefreshInterval: TimeInterval { Self.refreshInterval }
    
    private static let refreshInterval: TimeInterval = 60
    
    private let service: CodexStatusService
    private var autoRefreshTask: Task<Void, Never>?
    
    init(service: CodexStatusService = CodexStatusService()) {
        self.service = service
    }
    
    deinit {
        autoRefreshTask?.cancel()
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
                if (try? await Task.sleep(for: .seconds(delay))) == nil {
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
        
        Task {
            switch await service.fetchOutcome() {
            case .data(let snapshot):
                self.snapshot = snapshot
                self.loadState = .loaded
            case .notLoggedIn:
                self.snapshot = nil
                self.loadState = .notLoggedIn
            case .initializationFailed:
                self.snapshot = nil
                self.loadState = .initializationFailed
            }
            
            self.codexConnectionInfo = await service.currentConnectionInfo()
            self.autoRefreshCountdownStartedAt = Date()
            self.isRefreshing = false
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
