import Foundation
import Testing

@MainActor
struct ProtectionRecoveryTests {
    @Test func repairedStoreReloadsWhenProtectionIsEnabled() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let bad = try directory.write("broken", to: "Protection/state.json")
        let monitor = makeMonitor(directory: directory, preferences: preferences)
        monitor.isStarted = true
        monitor.loadProtectionState()
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { monitor.protectionLoadState == .blocked })
        #expect(!monitor.isProtectionStoreAvailable)
        try FileManager.default.removeItem(at: bad)
        monitor.setProtectionEnabled(true)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { monitor.isProtectionStoreAvailable })
        #expect(monitor.isProtectionRecoveryInProgress)
        monitor.stop()
    }

    @Test func transientReadFailureRetriesAndStopInvalidatesLoad() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let path = directory.url.appendingPathComponent("Protection/state.json")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let monitor = makeMonitor(directory: directory, preferences: preferences)
        monitor.isStarted = true
        monitor.loadProtectionState()
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { monitor.protectionLoadState == .retryableFailure })
        try FileManager.default.removeItem(at: path)
        #expect(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { monitor.isProtectionStoreAvailable })
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
            activityDataDirectoryURL: directory.url
        )
        // 注入未启动的 reader, 避免状态恢复测试连接真实 Codex
        monitor.activityReader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: directory.url.appendingPathComponent("absent.sock"),
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { _ in }
        monitor.isBootstrapping = true
        return monitor
    }
}
