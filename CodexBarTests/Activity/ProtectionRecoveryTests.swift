import Foundation
import Testing

@MainActor
struct ProtectionRecoveryTests {
    @Test func repairedStoreReloadsWhenProtectionIsEnabled() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let bad = try directory.write("broken", to: "state.json")
        let monitor = makeMonitor(directory: directory, preferences: preferences)
        monitor.isStarted = true
        monitor.loadProtectionState()
        try await wait { monitor.protectionLoadState == .blocked }
        #expect(!monitor.isProtectionStoreAvailable)
        try FileManager.default.removeItem(at: bad)
        monitor.setProtectionEnabled(true)
        try await wait { monitor.isProtectionStoreAvailable }
        #expect(monitor.isProtectionRecoveryInProgress)
        monitor.stop()
    }

    @Test func transientReadFailureRetriesAndStopInvalidatesLoad() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let path = directory.url.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let monitor = makeMonitor(directory: directory, preferences: preferences)
        monitor.isStarted = true
        monitor.loadProtectionState()
        try await wait { monitor.protectionLoadState == .retryableFailure }
        try FileManager.default.removeItem(at: path)
        try await wait { monitor.isProtectionStoreAvailable }
        monitor.stop()
        monitor.protectionLoadState = .idle
        monitor.isStarted = true
        monitor.loadProtectionState()
        monitor.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(monitor.protectionLoadState == .idle)
    }

    private func makeMonitor(directory: TestDirectory, preferences: TestPreferences) -> ActivityMonitor {
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDirectoryURL: directory.url
        )
        // 注入未启动的 reader, 避免状态恢复测试连接真实 Codex
        monitor.activityReader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: directory.url.appendingPathComponent("absent.sock"),
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url)
        ) { _ in }
        monitor.isBootstrapping = true
        return monitor
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
