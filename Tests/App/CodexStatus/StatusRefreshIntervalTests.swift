import Foundation
import Testing

struct StatusRefreshIntervalTests {
    @Test(arguments: DataUpdateInterval.allCases)
    func dataUpdateIntervalPersistsAndUpdatesCountdown(_ interval: DataUpdateInterval) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let service = makeStatusService(suiteName: preferences.suite)
        let model = CodexStatusViewModel(service: service, defaults: preferences.defaults)
        #expect(model.dataUpdateInterval == .oneMinute)
        model.setDataUpdateInterval(interval)
        #expect(model.autoRefreshInterval == interval.duration)
        let restored = CodexStatusViewModel(service: service, defaults: preferences.defaults)
        #expect(restored.dataUpdateInterval == interval)
        #expect(restored.autoRefreshInterval == interval.duration)
        #expect(!model.isRefreshing)
        #expect(model.autoRefreshCountdownStartedAt == nil)
    }

    @Test(arguments: [0, -60, 90, 1200])
    func invalidDataUpdateIntervalUsesDefault(_ seconds: Int) throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(seconds, forKey: "DataUpdate.intervalSeconds")
        let model = CodexStatusViewModel(
            service: makeStatusService(suiteName: preferences.suite),
            defaults: preferences.defaults
        )
        #expect(model.dataUpdateInterval == .oneMinute)
    }

    @Test func dataUpdateIntervalRespectsElapsedTimeAndNewRefreshOrigin() {
        let start = TestFixtures.now
        let now = start.addingTimeInterval(150)
        #expect(DataUpdateInterval.tenMinutes.remainingTime(since: start, now: now) == 450)
        #expect(DataUpdateInterval.threeMinutes.remainingTime(since: start, now: now) == 30)
        #expect(DataUpdateInterval.twoMinutes.remainingTime(since: start, now: now) == 0)
        #expect(DataUpdateInterval.oneMinute.remainingTime(since: nil, now: now) == 0)
        #expect(DataUpdateInterval.oneMinute.remainingTime(since: start, now: start.addingTimeInterval(60)) == 0)
        #expect(DataUpdateInterval.fiveMinutes.remainingTime(since: now, now: now) == 300)
    }

    private nonisolated func makeStatusService(suiteName: String) -> CodexStatusService {
        CodexStatusService(socketURL: URL(fileURLWithPath: "/tmp/\(suiteName).sock"), logStorage: nil)
    }
}
