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
    @Published private(set) var errorMessage: String?
    
    private static let refreshInterval: TimeInterval = 60
    
    private let service: CodexRateLimitService
    private var autoRefreshTask: Task<Void, Never>?
    
    init(service: CodexRateLimitService = CodexRateLimitService()) {
        self.service = service
    }
    
    func refreshIfNeeded() {
        guard snapshot == nil || Date().timeIntervalSince(snapshot?.generatedAt ?? .distantPast) > Self.refreshInterval else {
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
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
                self?.refresh()
            }
        }
    }
    
    func refresh() {
        guard !isRefreshing else {
            return
        }
        
        isRefreshing = true
        errorMessage = nil
        
        Task {
            do {
                let snapshot = try await service.fetchRateLimits()
                self.snapshot = snapshot
            } catch {
                self.errorMessage = error.localizedDescription
            }
            
            self.isRefreshing = false
        }
    }
}
