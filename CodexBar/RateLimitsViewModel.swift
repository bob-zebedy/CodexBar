//
//  RateLimitsViewModel.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Combine
import Foundation

@MainActor
final class RateLimitsViewModel: ObservableObject {
    @Published private(set) var snapshot: CodexQuotaSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: CodexRateLimitError?
    @Published private(set) var codexConnectionInfo: CodexCLIConnectionInfo?
    @Published private(set) var autoRefreshCountdownStartedAt: Date?
    
    // UI 状态统一从 lastError 派生, 保证单一真相来源
    var errorMessage: String? { lastError?.errorDescription }
    var requiresLogin: Bool { lastError?.requiresLogin ?? false }
    var hasError: Bool { lastError != nil }
    var autoRefreshInterval: TimeInterval { Self.refreshInterval }
    
    private static let refreshInterval: TimeInterval = 60
    
    private let service: CodexRateLimitService
    private var autoRefreshTask: Task<Void, Never>?
    
    init(service: CodexRateLimitService = CodexRateLimitService()) {
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
                if (try? await Task.sleep(for: .seconds(1))) == nil {
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
            do {
                self.snapshot = try await service.fetchRateLimits()
                self.lastError = nil
            } catch {
                self.lastError = (error as? CodexRateLimitError) ?? .serverError(error.localizedDescription)
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
}
