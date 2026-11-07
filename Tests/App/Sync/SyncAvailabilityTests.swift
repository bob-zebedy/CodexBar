import Combine
import Foundation
import Testing

struct SyncAvailabilityTests {
    @Test func uploadTimeIgnoresOlderReadsAndPreservesValueAfterFailure() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        var reads: [CheckedContinuation<Date?, any Error>] = []
        let settings = SyncSettings(defaults: preferences.defaults, queryAvailability: { .available }, loadLastUpload: {
            try await withCheckedThrowingContinuation { reads.append($0) }
        })
        try await waitUntil { reads.count == 1 }
        settings.refresh()
        try await waitUntil { reads.count == 2 }
        let latest = Date(timeIntervalSince1970: 200)
        reads[1].resume(returning: latest)
        try await waitUntil { settings.lastUploadAt == latest }
        reads[0].resume(returning: Date(timeIntervalSince1970: 100))
        settings.refresh()
        try await waitUntil { reads.count == 3 }
        reads[2].resume(throwing: POSIXError(.EWOULDBLOCK))
        settings.refresh()
        try await waitUntil { reads.count == 4 }
        #expect(settings.lastUploadAt == latest)
        reads[3].resume(returning: nil)
        try await waitUntil { settings.lastUploadAt == nil }
    }

    @Test func maintenanceRecoversAvailabilityWithoutOpeningSettings() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "Sync.isEnabled")
        var queries = 0
        let settings = SyncSettings(defaults: preferences.defaults, queryAvailability: {
            queries += 1
            return queries == 1 ? .unavailable(.networkUnavailable) : .available
        }, loadLastUpload: { nil })
        var synchronizations = 0
        let scheduler = SyncScheduler(syncActivation: { settings.activation() }, maintenance: { synchronizes, _ in
            if synchronizes {
                synchronizations += 1
            }
            return nil
        }, rebuild: { _, _ in throw CancellationError() })
        defer { scheduler.cancel() }
        let subscription = settings.$syncAvailability
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { availability in
                guard availability == settings.syncAvailability else { return }
                scheduler.requestSync(trigger: .settings)
            }
        defer { subscription.cancel() }
        try await waitUntil { settings.syncAvailability == .unavailable }
        let now = Date()
        settings.refreshAvailabilityIfNeeded(now: now.addingTimeInterval(30))
        scheduler.requestMaintenance(allowsSync: true, trigger: .auto)
        #expect(queries == 1)
        #expect(synchronizations == 0)

        settings.refreshAvailabilityIfNeeded(now: now.addingTimeInterval(61))
        try await waitUntil { synchronizations == 1 }
        #expect(queries == 2)
        #expect(settings.isEffectivelyActive)
        settings.refreshAvailabilityIfNeeded(now: now.addingTimeInterval(180))
        #expect(queries == 2)
    }

    @Test func availabilityRequestsCoalesceAndDisablingIgnoresLateResults() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "Sync.isEnabled")
        var queries = 0
        var pending: CheckedContinuation<SyncAvailabilityResult, Never>?
        let settings = SyncSettings(defaults: preferences.defaults, queryAvailability: {
            queries += 1
            return await withCheckedContinuation { pending = $0 }
        }, loadLastUpload: { nil })
        try await waitUntil { pending != nil }
        settings.refresh()
        settings.refreshAvailabilityIfNeeded(now: Date().addingTimeInterval(120))
        #expect(queries == 1)
        #expect(settings.setEnabled(false))
        pending?.resume(returning: .available)
        pending = nil
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(settings.syncAvailability == .unknown)
        #expect(settings.activation() == .syncOff)
        settings.refreshAvailabilityIfNeeded(now: Date().addingTimeInterval(240))
        #expect(queries == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        try #require(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5), condition))
    }
}
