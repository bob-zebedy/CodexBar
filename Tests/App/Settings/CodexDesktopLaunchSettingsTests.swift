import Foundation
import Testing

@Suite(.tags(.integration))
struct CodexDesktopLaunchSettingsTests {
    @Test(arguments: [false, true])
    func firstReadyConnectionAppliesSavedPreferenceOnce(enabled: Bool) async throws {
        let fixture = try Fixture(savedEnabled: enabled)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let addressKey = "CODEX_APP_SERVER_WS_URL"
        let forceKey = "CODEX_APP_SERVER_FORCE_CLI"
        environment.values = [addressKey: "ws://localhost:9000", forceKey: "1"]
        environment.beforeCommand = { _, key in
            #expect(enabled || key == addressKey)
        }
        let startupSocket = fixture.home.appendingPathComponent("startup.sock")
        let startup = AppServerStartup(
            socketURL: startupSocket, environment: [:], installations: .init(standalonePath: nil, bundledPath: nil),
            onFirstReady: settings.applySavedPreference
        )
        await #expect(throws: AppServerStartup.StartupError.self) { try await startup.ensureStarted() }
        #expect(!settings.isUpdating && environment.writes == 0)

        let daemon = try SharedServerFixture(connections: 2) { _ in }
        defer { daemon.close() }
        try fixture.link(daemon, at: startupSocket)
        let rpc = enabled ? try SharedServerFixture(handshakePath: "/rpc") { _ in } : nil
        defer { rpc?.close() }
        if let rpc {
            try fixture.link(rpc)
        }
        try await startup.ensureStarted()
        try await fixture.waitForUpdate()
        #expect(!settings.updateFailed)
        let expectedAddress = enabled ? try fixture.desktopAddress : nil
        #expect(environment.values[addressKey] == expectedAddress)
        #expect(environment.values[forceKey] == (enabled ? "0" : "1"))
        try rpc?.finish()

        environment.values[addressKey] = "ws://localhost:9001"
        try await startup.ensureStarted()
        #expect(!settings.isUpdating)
        #expect(environment.values[addressKey] == "ws://localhost:9001")
        #expect(environment.writes == (enabled ? 2 : 1))
        try daemon.finish()
    }

    @Test(arguments: ["plain", "Codex Data", "目录", "a:b", "a#b", String(repeating: "x", count: 100)])
    func desktopAddressConnectsAfterSocketReplacement(_ name: String) async throws {
        let fixture = try Fixture(homeSuffix: "-\(name)")
        defer { fixture.remove() }
        let settings = fixture.settings
        let server = try SharedServerFixture(handshakePath: "/rpc") { _ in }
        defer { server.close() }
        try fixture.link(server)

        settings.setEnabled(true)
        try await fixture.waitForUpdate()
        try #require(settings.isEnabled && !settings.updateFailed)
        try server.finish()
        let address = try #require(fixture.environment.values["CODEX_APP_SERVER_WS_URL"])
        #expect(address.hasPrefix("ws+unix://localhost/.vol/"))
        #expect(try address == fixture.desktopAddress)
        // Desktop 的 WebSocket 客户端会保留百分号编码, 并用冒号分隔 socket 路径和请求路径
        let url = try #require(URL(string: address))
        let parts = url.path(percentEncoded: true).components(separatedBy: ":")
        try #require(parts.count == 2 && parts[1] == "/rpc" && url.fragment == nil)

        let replacement = try SharedServerFixture(handshakePath: "/rpc") { _ in }
        defer { replacement.close() }
        try FileManager.default.removeItem(at: fixture.socket)
        try fixture.link(replacement)
        let session = try AppServerSession(socketURL: URL(fileURLWithPath: parts[0]), handshakePath: "/rpc", logStorage: nil)
        session.close()
        try replacement.finish()
    }

    @Test(arguments: [false, true])
    func unavailableDaemonPreservesEnvironmentAndPreference(restoring: Bool) async throws {
        let fixture = try Fixture(savedEnabled: restoring)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let address = restoring ? "ws://localhost:9000" : try fixture.desktopAddress
        environment.values["CODEX_APP_SERVER_WS_URL"] = address
        if restoring {
            settings.refresh()
            try #require(try await waitForCondition(timeout: .seconds(8), pollInterval: .milliseconds(10)) { settings.hasMismatch })
            settings.restore()
        } else {
            settings.setEnabled(true)
        }
        try await fixture.waitForUpdate()
        #expect(settings.updateFailed)
        #expect(settings.isEnabled == restoring)
        #expect(fixture.preferences.defaults.bool(forKey: "CodexDesktopDaemon.isEnabled") == restoring)
        #expect(environment.values["CODEX_APP_SERVER_WS_URL"] == address)
        #expect(environment.writes == 0)
        if restoring {
            settings.setEnabled(false)
            try await fixture.waitForUpdate()
            #expect(!settings.updateFailed && !settings.isEnabled)
            #expect(environment.values.isEmpty)
        } else {
            environment.values["CODEX_APP_SERVER_FORCE_CLI"] = "0"
            settings.refresh()
            try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { settings.hasMismatch })
            #expect(settings.updateFailed && !settings.isEnabled && environment.writes == 0)

            let server = try SharedServerFixture(handshakePath: "/rpc") { _ in }
            defer { server.close() }
            try fixture.link(server)
            settings.setEnabled(true)
            try await fixture.waitForUpdate()
            #expect(!settings.updateFailed && settings.isEnabled && environment.writes == 0)
            try server.finish()
        }
    }

    @Test func matchingEnvironmentKeepsConnectionFailureUntilRestoreSucceeds() async throws {
        let fixture = try Fixture(savedEnabled: true)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        environment.values["CODEX_APP_SERVER_WS_URL"] = try fixture.desktopAddress

        settings.applySavedPreference()
        try await fixture.waitForUpdate()
        try #require(settings.updateFailed && settings.isEnabled)
        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { settings.hasMismatch })

        environment.values["CODEX_APP_SERVER_FORCE_CLI"] = "0"
        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { !settings.hasMismatch })
        try #require(settings.updateFailed && settings.canRestore)

        let server = try SharedServerFixture(handshakePath: "/rpc") { _ in }
        defer { server.close() }
        try fixture.link(server)
        settings.restore()
        #expect(settings.isUpdating)
        try await fixture.waitForUpdate()
        #expect(!settings.updateFailed && !settings.canRestore && settings.isEnabled)
        #expect(environment.writes == 0)
        try server.finish()
    }

    @Test(arguments: [nil, "0", "1", "01"] as [String?])
    func enablingAndRestoringRequireExplicitForceCLIZero(_ forceCLI: String?) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let server = try SharedServerFixture(connections: 2, handshakePath: "/rpc") { _ in }
        defer { server.close() }
        try fixture.link(server)
        let forceKey = "CODEX_APP_SERVER_FORCE_CLI"
        environment.values["CODEX_APP_SERVER_WS_URL"] = try fixture.desktopAddress
        environment.values[forceKey] = forceCLI

        settings.setEnabled(true)
        try await fixture.waitForUpdate()
        try #require(settings.isEnabled && !settings.updateFailed)
        #expect(environment.values[forceKey] == "0")
        let expectedWrites = forceCLI == "0" ? 0 : 1
        #expect(environment.writes == expectedWrites)

        let changedValue = forceCLI == "0" ? "1" : forceCLI
        environment.values[forceKey] = changedValue
        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { settings.hasMismatch })
        #expect(environment.values[forceKey] == changedValue)
        #expect(environment.writes == expectedWrites)

        settings.restore()
        try await fixture.waitForUpdate()
        #expect(!settings.updateFailed && !settings.hasMismatch)
        #expect(environment.values[forceKey] == "0")
        #expect(environment.writes == expectedWrites + 1)
        try server.finish()
    }

    @Test func failedEnableRollsBackAddressAndRefreshChecksBothVariables() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let addressKey = "CODEX_APP_SERVER_WS_URL"
        let forceKey = "CODEX_APP_SERVER_FORCE_CLI"
        environment.values[forceKey] = "1"
        environment.beforeCommand = { operation, key in
            if operation == "setenv", key == forceKey {
                throw POSIXError(.EACCES)
            }
        }
        let server = try SharedServerFixture(handshakePath: "/rpc") { _ in }
        defer { server.close() }
        try fixture.link(server)

        settings.setEnabled(true)
        try await fixture.waitForUpdate()
        try #require(settings.updateFailed && !settings.isEnabled && !settings.hasMismatch)
        #expect(environment.values == [forceKey: "1"] && environment.writes == 2)
        try server.finish()

        environment.values[addressKey] = try fixture.desktopAddress
        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { settings.hasMismatch })
        #expect(settings.updateFailed)

        environment.values[forceKey] = "0"
        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { !settings.updateFailed })
        #expect(settings.hasMismatch && !settings.isEnabled && environment.writes == 2)
    }

    @Test(arguments: [1, 2])
    func acceptedDisableSurvivesReadbackFailureAndRelaunch(failedReads: Int) async throws {
        let fixture = try Fixture(savedEnabled: true)
        defer { fixture.remove() }
        let environment = fixture.environment
        environment.values["CODEX_APP_SERVER_WS_URL"] = "ws://localhost:9000"
        var remaining = failedReads
        environment.beforeCommand = { operation, _ in
            if operation == "getenv", environment.writes == 1, remaining > 0 {
                remaining -= 1
                throw POSIXError(.ETIMEDOUT)
            }
        }
        defer { environment.beforeCommand = nil }
        fixture.settings.setEnabled(false)
        try await fixture.waitForUpdate()
        #expect(!fixture.settings.isEnabled && environment.values.isEmpty)
        #expect(fixture.settings.updateFailed == (failedReads == 2))
        #expect(remaining == 0 && environment.writes == 1)

        let relaunched = CodexDesktopLaunchSettings(codexHome: fixture.home, defaults: fixture.preferences.defaults, isDesktopInstalled: { true }, launchctl: environment.run)
        try #require(!relaunched.isEnabled)
        relaunched.applySavedPreference()
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { !relaunched.isUpdating })
        #expect(!relaunched.hasMismatch && !relaunched.updateFailed && environment.writes == 1)
    }

    @Test func disabledRefreshOnlyReadsAddress() async throws {
        let fixture = try Fixture(savedEnabled: false)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let addressKey = "CODEX_APP_SERVER_WS_URL"
        environment.values[addressKey] = "ws://localhost:9000"
        var reads: [String] = []
        environment.beforeCommand = { operation, key in
            #expect(operation == "getenv")
            reads.append(key)
            if key != addressKey {
                throw POSIXError(.EACCES)
            }
        }

        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { settings.hasMismatch })
        environment.values[addressKey] = nil
        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(10)) { !settings.hasMismatch })
        #expect(!settings.updateFailed && reads == [addressKey, addressKey])
    }

    @Test func queuedChangeSurvivesRepeatedRefreshes() async throws {
        let fixture = try Fixture(savedEnabled: true)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let addressKey = "CODEX_APP_SERVER_WS_URL"
        let forceKey = "CODEX_APP_SERVER_FORCE_CLI"
        environment.values = try [addressKey: fixture.desktopAddress, forceKey: "0"]
        var reads: [String] = []
        environment.beforeCommand = { operation, key in
            guard operation == "getenv" else { return }
            reads.append(key)
            if reads.count == 1 {
                settings.refresh()
                settings.setEnabled(false)
                settings.refresh()
                settings.refresh()
            }
        }
        defer { environment.beforeCommand = nil }

        settings.refresh()
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { !settings.isEnabled && !settings.isUpdating })
        #expect(reads == [addressKey, forceKey, addressKey, addressKey])
        #expect(environment.values == [forceKey: "0"] && environment.writes == 1)
        #expect(!settings.hasMismatch && !settings.updateFailed)
    }

    @Test(arguments: [false, true])
    func queuedReadKeepsWriteFailureUntilTargetIsReached(retry: Bool) async throws {
        let fixture = try Fixture(savedEnabled: true)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let addressKey = "CODEX_APP_SERVER_WS_URL"
        environment.values = try [addressKey: fixture.desktopAddress, "CODEX_APP_SERVER_FORCE_CLI": "0"]
        environment.beforeCommand = { operation, _ in
            if operation == "unsetenv" {
                settings.refresh()
                throw POSIXError(.EACCES)
            }
        }
        defer { environment.beforeCommand = nil }
        settings.setEnabled(false)
        try await fixture.waitForUpdate()
        #expect(settings.updateFailed && settings.isEnabled && !settings.hasMismatch)
        #expect(environment.values[addressKey] != nil && environment.writes == 0)

        environment.beforeCommand = nil
        if retry {
            settings.setEnabled(false)
            try await fixture.waitForUpdate()
            #expect(!settings.updateFailed && !settings.isEnabled && environment.writes == 1)
        } else {
            environment.values[addressKey] = nil
            settings.refresh()
            try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { !settings.updateFailed })
            #expect(settings.isEnabled && settings.hasMismatch && environment.writes == 0)
        }
    }

    @Test(arguments: [false, true])
    func terminationWaitsForAcceptedWriteAndRecovery(failsSecondWrite: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        let addressKey = "CODEX_APP_SERVER_WS_URL"
        let forceKey = "CODEX_APP_SERVER_FORCE_CLI"
        let original = [addressKey: "ws://localhost:9000", forceKey: "1"]
        environment.values = original
        let secondWrite = TestCheckpoint()
        let releaseWrite = TestCheckpoint()
        defer { releaseWrite.signal() }
        environment.beforeCommand = { operation, key in
            guard operation == "setenv", key == forceKey else { return }
            secondWrite.signal()
            await releaseWrite.waitIgnoringCancellation()
            if failsSecondWrite {
                throw POSIXError(.EACCES)
            }
        }
        let server = try SharedServerFixture(handshakePath: "/rpc") { _ in }
        defer { server.close() }
        try fixture.link(server)
        settings.setEnabled(true)
        try #require(try await secondWrite.wait())
        let address = try fixture.desktopAddress
        #expect(environment.values == [addressKey: address, forceKey: "1"])

        let preparing = TestCheckpoint()
        var finished = false
        let termination = Task {
            preparing.signal()
            await settings.prepareForTermination()
            finished = true
            #expect(!settings.isUpdating && settings.updateFailed == failsSecondWrite)
            #expect(settings.hasMismatch == failsSecondWrite)
            #expect(fixture.preferences.defaults.bool(forKey: "CodexDesktopDaemon.isEnabled") == !failsSecondWrite)
            #expect(environment.values == (failsSecondWrite ? original : [addressKey: address, forceKey: "0"]))
        }
        try #require(try await preparing.wait())
        #expect(!finished)
        releaseWrite.signal()
        await termination.value
        try server.finish()
    }

    @Test func cancelledTerminationResumesDeferredStartupPreference() async throws {
        let fixture = try Fixture(savedEnabled: false)
        defer { fixture.remove() }
        let settings = fixture.settings
        let environment = fixture.environment
        environment.values["CODEX_APP_SERVER_WS_URL"] = "ws://localhost:9000"
        await settings.prepareForTermination()
        settings.setEnabled(true)
        settings.refresh()
        settings.applySavedPreference()
        #expect(!settings.isUpdating && !settings.hasMismatch && environment.writes == 0)

        settings.resumeAfterTerminationCancellation()
        try #require(settings.isUpdating)
        try await fixture.waitForUpdate()
        #expect(environment.values.isEmpty && environment.writes == 1 && !settings.updateFailed)
    }

    private struct Fixture {
        let home: URL
        let socket: URL
        let preferences: TestPreferences
        let environment = LaunchEnvironment()
        let settings: CodexDesktopLaunchSettings

        var desktopAddress: String {
            get throws {
                let directory = try CodexPaths.socketDirectoryReference(home)
                return "ws+unix://localhost\(directory.path)/app-server-control/app-server-control.sock:/rpc"
            }
        }

        init(homeSuffix: String = "", savedEnabled: Bool? = nil) throws {
            home = URL(fileURLWithPath: "/tmp/\(UUID())\(homeSuffix)", isDirectory: true)
            socket = CodexPaths.appServerSocket(in: home)
            preferences = try TestPreferences()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            if let savedEnabled {
                preferences.defaults.set(savedEnabled, forKey: "CodexDesktopDaemon.isEnabled")
            }
            settings = CodexDesktopLaunchSettings(codexHome: home, defaults: preferences.defaults, isDesktopInstalled: { true }, launchctl: environment.run)
        }

        func link(_ server: SharedServerFixture, at target: URL? = nil) throws {
            let target = target ?? socket
            let files = FileManager.default
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createSymbolicLink(at: target, withDestinationURL: server.url)
        }

        func waitForUpdate(sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try #require(try await waitForCondition(timeout: .seconds(8), pollInterval: .milliseconds(10)) { !settings.isUpdating }, sourceLocation: sourceLocation)
        }

        func remove() {
            preferences.remove()
            try? FileManager.default.removeItem(at: home)
        }
    }

    private final class LaunchEnvironment {
        var values: [String: String] = [:]
        var writes = 0
        var beforeCommand: ((String, String) async throws -> Void)?

        func run(_ operation: String, _ key: String, _ value: String?) async throws -> String? {
            try await beforeCommand?(operation, key)
            guard operation != "getenv" else { return values[key] }
            writes += 1
            values[key] = value
            return nil
        }
    }
}
