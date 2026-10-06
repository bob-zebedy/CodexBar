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
        let unsupported = try directory.executable("exit 2", named: "old codex")
        let supported = try directory.executable("""
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
        let unsupported = try directory.executable("exit 2", named: "fake codex")
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
        let command = try directory.executable("""
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
        let command = try directory.executable("""
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
        let command = try directory.executable("""
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
        let command = try directory.executable("""
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
        do {
            try await startup.ensureStarted()
            Issue.record("Expected overlapping startup to be rejected")
        } catch let error as AppServerStartup.StartupError {
            guard case .notReady = error else { throw error }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try String(contentsOf: directory.url.appendingPathComponent("calls"), encoding: .utf8) == "blocked")
        _ = try directory.write("retry", to: "retry")
        try await startup.ensureStarted()
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
}
