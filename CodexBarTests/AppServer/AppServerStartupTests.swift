import Darwin
import Foundation
import os
import Testing

struct AppServerStartupTests {
    @Test func reusesRunningServiceWithoutAnInstalledCLI() async throws {
        let server = try SharedServerFixture { _ in }
        defer { server.close() }
        let startup = AppServerStartup(
            socketURL: server.url, environment: [:],
            installations: CodexInstallations(globalPath: nil, bundledPath: nil)
        )
        try await startup.ensureStarted()
        try server.finish()
    }

    @Test func startsMissingServiceWithResolvedEnvironmentAndBundledFallback() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let unsupported = try Self.executable(in: directory, "exit 2", named: "old codex")
        let supported = try Self.executable(in: directory, """
        printf '%s\\n' "$*" >> "$HOME/calls"
        if [ "$4" = '--help' ]; then
            printf 'Usage: codex app-server daemon start [OPTIONS]'
        elif [ "$*" = 'app-server daemon start' ]; then
            printf '%s' "$CODEX_HOME" > "$HOME/started"
        else
            exit 4
        fi
        """, named: "fake codex")
        let server = try SharedServerFixture { _ in }
        defer { server.close() }
        let marker = directory.url.appendingPathComponent("started")
        let environment = ["HOME": directory.url.path, "CODEX_HOME": directory.url.appendingPathComponent("custom codex").path]
        let startup = AppServerStartup(
            environment: environment,
            installations: CodexInstallations(globalPath: unsupported.path, bundledPath: supported.path),
            probeConnection: {
                guard FileManager.default.fileExists(atPath: marker.path) else {
                    throw AppServerConnectionError(code: ENOENT)
                }
                let connection = try AppServerSession(socketURL: server.url, logStorage: nil)
                connection.close()
            }
        )
        try await startup.ensureStarted()
        #expect(try String(contentsOf: marker, encoding: .utf8) == environment["CODEX_HOME"])
        #expect(try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8) == """
        app-server daemon start --help
        app-server daemon start

        """)
        try server.finish()
    }

    @Test(arguments: [EACCES, EPERM, ENOTSOCK])
    func doesNotStartServiceForOtherConnectionErrors(_ code: Int32) async throws {
        let startup = AppServerStartup(
            environment: [:], installations: CodexInstallations(globalPath: nil, bundledPath: nil),
            probeConnection: { throw AppServerConnectionError(code: code) }
        )
        do {
            try await startup.ensureStarted()
            Issue.record("Expected connection failure")
        } catch let error as AppServerConnectionError {
            #expect(error.code == code)
        }
    }

    @Test func doesNotStartServiceForHandshakeFailure() async throws {
        let startup = AppServerStartup(
            environment: [:], installations: CodexInstallations(globalPath: nil, bundledPath: nil),
            probeConnection: { throw CodexStatusError.invalidServerResponse }
        )
        await #expect(throws: CodexStatusError.self) { try await startup.ensureStarted() }
    }

    @Test func reportsMissingAndUnsupportedInstallations() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let unsupported = try Self.executable(in: directory, "exit 2", named: "fake codex")
        for path in [nil, unsupported.path] {
            let startup = AppServerStartup(
                environment: [:], installations: CodexInstallations(globalPath: path, bundledPath: nil),
                probeConnection: { throw AppServerConnectionError(code: ECONNREFUSED) }
            )
            do {
                try await startup.ensureStarted()
                Issue.record("Expected startup failure")
            } catch let error as AppServerStartup.StartupError {
                switch error {
                case .notInstalled: #expect(path == nil)
                case .unsupportedCommand: #expect(path != nil)
                default: Issue.record("Unexpected error: \(error)")
                }
            }
        }
    }

    @Test(arguments: ["exit 7", "exit 0", "trap '' TERM; while :; do :; done"])
    func boundsFailedStartsAndReadinessRetries(_ body: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try Self.executable(in: directory, """
        if [ "$4" = '--help' ]; then
            printf 'Usage: codex app-server daemon start [OPTIONS]'
            exit 0
        fi
        printf 'start\\n' >> "$HOME/calls"
        \(body)
        """, named: "fake codex")
        let startup = AppServerStartup(
            environment: ["HOME": directory.url.path],
            installations: CodexInstallations(globalPath: command.path, bundledPath: nil),
            commandTimeout: 0.3, readinessAttempts: 2,
            probeConnection: { throw AppServerConnectionError(code: ECONNREFUSED) }
        )
        let started = ContinuousClock.now
        do {
            try await startup.ensureStarted()
            Issue.record("Expected startup failure")
        } catch let error as AppServerStartup.StartupError {
            switch error {
            case let .commandFailed(code): #expect(body == "exit 7" && code == 7)
            case .notReady: #expect(body == "exit 0")
            case .timeout: #expect(body.hasPrefix("trap"))
            default: Issue.record("Unexpected error: \(error)")
            }
        }
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8) == "start\n")
    }

    @Test func rechecksConnectionBeforeIssuingStart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try Self.executable(in: directory, """
        if [ "$4" != '--help' ]; then
            printf 'unexpected start' > "$HOME/started"
            exit 1
        fi
        printf 'Usage: codex app-server daemon start [OPTIONS]'
        """, named: "fake codex")
        let probes = OSAllocatedUnfairLock(initialState: 0)
        let startup = AppServerStartup(
            environment: ["HOME": directory.url.path],
            installations: CodexInstallations(globalPath: command.path, bundledPath: nil),
            probeConnection: {
                let count = probes.withLock { $0 += 1
                    return $0
                }
                if count == 1 {
                    throw AppServerConnectionError(code: ENOENT)
                }
            }
        )
        try await startup.ensureStarted()
        #expect(probes.withLock { $0 } == 2)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("started").path))
    }

    @Test func reusesServiceEvenWhenTheStartCommandFails() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try Self.executable(in: directory, """
        if [ "$4" = '--help' ]; then printf 'daemon start'; exit 0; fi
        printf ready > "$PROCESS_TEST_DIR/started"
        exit 7
        """)
        let marker = directory.url.appendingPathComponent("started")
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path],
            installations: .init(globalPath: command.path, bundledPath: nil),
            probeConnection: {
                if !FileManager.default.fileExists(atPath: marker.path) {
                    throw AppServerConnectionError(code: ENOENT)
                }
            }
        )
        try await startup.ensureStarted()
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: ["help", "start"])
    func preventsOverlappingCommandsAndAllowsRetryAfterCancellation(_ stage: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try Self.executable(in: directory, """
        if [ -f "$PROCESS_TEST_DIR/retry" ]; then
            if [ "$4" = '--help' ]; then printf 'daemon start'
            else printf ready > "$PROCESS_TEST_DIR/started"; fi
            exit 0
        fi
        if [ "$4" = '--help' ] && [ "$PROCESS_TEST_STAGE" = 'start' ]; then printf 'daemon start'; exit 0; fi
        trap '' TERM
        printf blocked >> "$PROCESS_TEST_DIR/calls"
        printf ready > "$PROCESS_TEST_DIR/blocked"
        while :; do :; done
        """)
        let marker = directory.url.appendingPathComponent("started")
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path, "PROCESS_TEST_STAGE": stage],
            installations: .init(globalPath: command.path, bundledPath: nil),
            probeConnection: {
                if !FileManager.default.fileExists(atPath: marker.path) {
                    throw AppServerConnectionError(code: ENOENT)
                }
            }
        )
        let task = Task { try await startup.ensureStarted() }
        defer { task.cancel() }
        try await directory.waitForFile("blocked")
        let joined = Task { try await startup.ensureStarted() }
        await Task.yield()
        joined.cancel()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: CancellationError.self) { try await joined.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8) == "blocked")
        _ = try directory.write("retry", to: "retry")
        try await startup.ensureStarted(trigger: .manual)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test nonisolated func missingSocketPreservesConnectionErrno() throws {
        let socket = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).sock")
        do {
            _ = try AppServerSession(socketURL: socket, logStorage: nil)
            Issue.record("Expected missing socket")
        } catch let error as AppServerConnectionError {
            #expect(error.code == ENOENT)
            #expect(error.serverIsAbsent)
        }
    }

    @Test(arguments: ["0.161.0", "0.162.0-alpha.17.2", "unrecognized", "absent"])
    func selectsSupportedBundledVersionBeforeLaunching(cliVersion: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let cli = try directory.executable("""
        if [ "$1" = '--version' ]; then printf '%s' '\(cliVersion)'; exit 0; fi
        printf unexpected > "$PROCESS_TEST_DIR/cli-command"
        exit 0
        """, named: "cli")
        let bundled = try Self.executable(in: directory, """
        if [ "$4" = '--help' ]; then printf 'daemon start'; exit 0; fi
        printf ready > "$PROCESS_TEST_DIR/ready"
        """, named: "bundled")
        let ready = directory.url.appendingPathComponent("ready")
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path],
            installations: .init(globalPath: cliVersion == "absent" ? nil : cli.path, bundledPath: bundled.path),
            probeConnection: {
                guard FileManager.default.fileExists(atPath: ready.path) else { throw AppServerConnectionError(code: ENOENT) }
            }
        )
        try await startup.ensureStarted()
        #expect(FileManager.default.fileExists(atPath: ready.path))
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("cli-command").path))
    }

    @Test func rejectsOldVersionsBeforeCapabilityChecksOrStartup() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.executable("""
        if [ "$1" = '--version' ]; then printf 'codex-cli 0.161.0'; exit 0; fi
        printf unexpected > "$PROCESS_TEST_DIR/called"
        """)
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path], installations: .init(globalPath: command.path, bundledPath: command.path),
            probeConnection: { throw AppServerConnectionError(code: ECONNREFUSED) }
        )
        do {
            try await startup.ensureStarted()
            Issue.record("Expected minimum version rejection")
        } catch let CodexStatusError.unsupportedVersion(minimum) {
            #expect(minimum == "0.162.0")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("called").path))
    }

    @Test func automaticRetriesAreBoundedManualBypassesAndConnectionResetsBudget() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let ready = OSAllocatedUnfairLock(initialState: false)
        let command = try Self.executable(in: directory, """
        if [ "$4" = '--help' ]; then printf 'daemon start'; exit 0; fi
        printf 'start\\n' >> "$PROCESS_TEST_DIR/calls"
        exit 7
        """)
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path], installations: .init(globalPath: command.path, bundledPath: nil),
            probeConnection: {
                if !ready.withLock({ $0 }) {
                    throw AppServerConnectionError(code: ENOENT)
                }
            },
            now: { clock.withLock { $0 } }
        )
        for index in 0 ..< 3 {
            if index > 0 {
                clock.withLock { $0 = $0.advanced(by: .seconds(60)) }
            }
            do { try await startup.ensureStarted()
                Issue.record("Expected command failure")
            } catch let error as AppServerStartup.StartupError {
                guard case .commandFailed(7) = error else { throw error }
            }
            do { try await startup.ensureStarted()
                Issue.record("Expected automatic retry limit")
            } catch let error as AppServerStartup.StartupError {
                if index < 2 {
                    guard case .retryDeferred = error else { throw error }
                } else {
                    guard case .retryExhausted = error else { throw error }
                }
            }
        }
        await #expect(throws: AppServerStartup.StartupError.self) { try await startup.ensureStarted(trigger: .manual) }
        ready.withLock { $0 = true }
        try await startup.ensureStarted()
        ready.withLock { $0 = false }
        do { try await startup.ensureStarted()
            Issue.record("Expected a fresh automatic attempt")
        } catch let error as AppServerStartup.StartupError { guard case .commandFailed(7) = error else { throw error } }
        let calls = try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 5)
    }

    @Test func concurrentRequestsShareOneStartAndOneCancellationDoesNotCancelOthers() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try Self.executable(in: directory, """
        if [ "$4" = '--help' ]; then printf 'daemon start'; exit 0; fi
        printf 'start\\n' >> "$PROCESS_TEST_DIR/calls"
        printf waiting > "$PROCESS_TEST_DIR/waiting"
        while [ ! -f "$PROCESS_TEST_DIR/release" ]; do /bin/sleep 0.01; done
        printf ready > "$PROCESS_TEST_DIR/ready"
        """)
        let ready = directory.url.appendingPathComponent("ready")
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path], installations: .init(globalPath: command.path, bundledPath: nil),
            probeConnection: {
                if !FileManager.default.fileExists(atPath: ready.path) {
                    throw AppServerConnectionError(code: ENOENT)
                }
            }
        )
        let first = Task { try await startup.ensureStarted() }
        defer { first.cancel() }
        try await directory.waitForFile("waiting")
        let second = Task { try await startup.ensureStarted(trigger: .manual) }
        defer { second.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        _ = try directory.write("release", to: "release")
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        #expect(try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8) == "start\n")
    }

    @Test(arguments: [false, true])
    func accountRecoveryCanStartAfterInitialFailure(manual: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let command = try Self.executable(in: directory, """
        if [ "$4" = '--help' ]; then printf 'daemon start'; exit 0; fi
        printf 'start\\n' >> "$PROCESS_TEST_DIR/calls"
        if [ ! -f "$PROCESS_TEST_DIR/allow" ]; then exit 7; fi
        printf ready > "$PROCESS_TEST_DIR/ready"
        """)
        let ready = directory.url.appendingPathComponent("ready")
        let startup = AppServerStartup(
            environment: ["PROCESS_TEST_DIR": directory.url.path], installations: .init(globalPath: command.path, bundledPath: nil),
            probeConnection: {
                if !FileManager.default.fileExists(atPath: ready.path) {
                    throw AppServerConnectionError(code: ENOENT)
                }
            },
            now: { clock.withLock { $0 } }
        )
        await #expect(throws: AppServerStartup.StartupError.self) { try await startup.ensureStarted() }
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let account = try peer.readMessage()
            try peer.reply(to: account, result: ["account": NSNull()])
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil, startup: startup)
        let deferred = await service.fetchOutcome()
        guard case .initializationFailed = deferred.outcome else { Issue.record("Expected deferred retry")
            return
        }
        _ = try directory.write("allow", to: "allow")
        if manual {
            #expect(try await service.reconnect(minimumVersion: "0.162.0").version == "0.162.0")
        } else {
            clock.withLock { $0 = $0.advanced(by: .seconds(60)) }
            let recovered = await service.fetchOutcome()
            guard case .notLoggedIn = recovered.outcome else { Issue.record("Expected successful account read")
                return
            }
        }
        let calls = try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 2)
        try server.finish()
    }

    @Test func existingOldDaemonIsRejectedWithoutStartingAnother() async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.161.0"])
        }
        defer { server.close() }
        let startup = AppServerStartup(environment: [:], installations: .init(globalPath: nil, bundledPath: nil), probeConnection: {})
        let service = CodexStatusService(socketURL: server.url, logStorage: nil, startup: startup)
        let result = await service.fetchOutcome()
        guard case let .unsupportedVersion(minimum) = result.outcome else { Issue.record("Expected actual server version check")
            return
        }
        #expect(minimum == "0.162.0")
        try server.finish()
    }

    private static func executable(in directory: TestDirectory, _ body: String, named name: String = "fake codex") throws -> URL {
        try directory.executable("""
        if [ "$1" = '--version' ]; then printf 'codex-cli 0.162.0'; exit 0; fi
        \(body)
        """, named: name)
    }
}
