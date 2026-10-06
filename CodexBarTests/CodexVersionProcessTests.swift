import Foundation
import Testing

struct CodexVersionProcessTests {
    @Test(arguments: [
        ("printf 'codex-cli 0.157.0\\nignored'; printf 'codex-cli 0.156.0' >&2", "0.157.0"),
        ("printf '  \\n'; printf 'codex-cli 0.157.0\\n' >&2", "0.157.0"),
        ("printf '\\377'; printf 'codex-cli 0.157.0' >&2", "0.157.0")
    ])
    func preservesOutputPriorityAndStrictDecoding(_ fixture: (String, String)) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.executable(fixture.0)
        let service = CodexVersionService(environment: [:], installations: .init(globalPath: command.path, bundledPath: nil))
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.global.version == fixture.1)
        #expect(snapshot.global.errorMessage == nil)
        #expect(snapshot.bundled.path == nil)
    }

    @Test(arguments: ["exit 7", "exit 0", "trap '' TERM; while :; do :; done"])
    func preservesFailureMessages(_ body: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.executable(body)
        let service = CodexVersionService(
            timeout: body.hasPrefix("trap") ? 0.15 : 5, environment: [:],
            installations: .init(globalPath: command.path, bundledPath: nil)
        )
        let snapshot = await service.fetchSnapshot()
        let message = switch body {
        case "exit 7": String(localized: "codex.version.read-failed")
        case "exit 0": String(localized: "codex.version.parse-failed")
        default: String(localized: "codex.version.read-timeout")
        }
        #expect(snapshot.global.errorMessage == message)
        #expect(snapshot.global.version == nil)
    }

    @Test func preservesLaunchFailureForANonExecutableFile() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.write("not executable", to: "codex")
        let service = CodexVersionService(environment: [:], installations: .init(globalPath: command.path, bundledPath: nil))
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.global.errorMessage == String(localized: "codex.version.launch-failed"))
    }

    @Test func probesBothSourcesConcurrently() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let global = try directory.executable("""
        printf ready > "$PROCESS_TEST_DIR/global.ready"
        while [ ! -f "$PROCESS_TEST_DIR/bundled.ready" ]; do /bin/sleep 0.01; done
        printf 'codex-cli 0.157.0'
        """, named: "global")
        let bundled = try directory.executable("""
        printf ready > "$PROCESS_TEST_DIR/bundled.ready"
        while [ ! -f "$PROCESS_TEST_DIR/global.ready" ]; do /bin/sleep 0.01; done
        printf 'codex-cli 0.158.0'
        """, named: "bundled")
        let service = CodexVersionService(
            timeout: 3, environment: ["PROCESS_TEST_DIR": directory.url.path],
            installations: .init(globalPath: global.path, bundledPath: bundled.path)
        )
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.global.version == "0.157.0")
        #expect(snapshot.bundled.version == "0.158.0")
    }

    @Test func cancellationCleansBothSourcesAndAllowsAnotherRefresh() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        func command(named name: String) throws -> URL {
            try directory.executable("""
            if [ -f "$PROCESS_TEST_DIR/retry" ]; then printf 'codex-cli 0.157.0'; exit 0; fi
            trap '' TERM
            printf ready > "$PROCESS_TEST_DIR/\(name).ready"
            while :; do :; done
            """, named: name)
        }
        let global = try command(named: "global")
        let bundled = try command(named: "bundled")
        let service = CodexVersionService(
            timeout: 15, environment: ["PROCESS_TEST_DIR": directory.url.path],
            installations: .init(globalPath: global.path, bundledPath: bundled.path)
        )
        let task = Task { await service.fetchSnapshot() }
        defer { task.cancel() }
        try await directory.waitForFile("global.ready")
        try await directory.waitForFile("bundled.ready")
        let overlapping = await service.fetchSnapshot()
        #expect(overlapping.global.errorMessage == String(localized: "codex.version.read-failed"))
        #expect(overlapping.bundled.errorMessage == String(localized: "codex.version.read-failed"))
        let started = ContinuousClock.now
        task.cancel()
        _ = await task.value
        #expect(started.duration(to: .now) < .seconds(3))
        _ = try directory.write("retry", to: "retry")
        let retried = await service.fetchSnapshot()
        #expect(retried.global.version == "0.157.0")
        #expect(retried.bundled.version == "0.157.0")
    }
}
