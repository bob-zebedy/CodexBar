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
    private let notificationService: QuotaNotificationService
    private var autoRefreshTask: Task<Void, Never>?
    private var rateLimitUpdateTask: Task<Void, Never>?
    private var isHandlingRateLimitUpdate = false

    init(service: CodexRateLimitService = CodexRateLimitService()) {
        self.service = service
        self.notificationService = QuotaNotificationService()
    }

    deinit {
        autoRefreshTask?.cancel()
        rateLimitUpdateTask?.cancel()
    }

    func refreshIfNeeded() {
        guard snapshot == nil || Date().timeIntervalSince(snapshot?.generatedAt ?? .distantPast) > Self.refreshInterval else {
            return
        }

        refresh()
    }

    func startAutoRefresh() {
        startRateLimitUpdateObserver()

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

    private func startRateLimitUpdateObserver() {
        guard rateLimitUpdateTask == nil else {
            return
        }

        let viewModelBox = WeakRateLimitsViewModelBox(self)
        rateLimitUpdateTask = Task.detached(priority: .utility) { [service, viewModelBox] in
            await service.observeRateLimitUpdates {
                Task { @MainActor [viewModelBox] in
                    await viewModelBox.value?.handleRateLimitUpdate()
                }
            }
        }
    }

    private func handleRateLimitUpdate() async {
        guard !isHandlingRateLimitUpdate else {
            return
        }

        isHandlingRateLimitUpdate = true
        defer {
            isHandlingRateLimitUpdate = false
        }

        do {
            let updatedSnapshot = try await service.fetchRateLimits()
            snapshot = updatedSnapshot
            errorMessage = nil

            await notificationService.sendRateLimitUpdatedNotification()
        } catch {
            if snapshot == nil {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private final class WeakRateLimitsViewModelBox: @unchecked Sendable {
    weak var value: RateLimitsViewModel?

    @MainActor
    init(_ value: RateLimitsViewModel) {
        self.value = value
    }
}
