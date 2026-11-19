import Foundation
import Testing

@Suite(.tags(.integration))
struct CodexVersionProcessTests {
    @Test func snapshotIsEmptyWithoutInstallations() async {
        let service = CodexVersionService(environment: [:], installations: .init(standalonePath: nil, bundledPath: nil))
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.installedItems.isEmpty)
    }

    @Test(arguments: [
        ("printf 'codex-cli 0.157.0\\nignored'; printf 'codex-cli 0.156.0' >&2", "0.157.0"),
        ("printf '  \\n'; printf 'codex-cli 0.157.0\\n' >&2", "0.157.0"),
        ("printf '\\377'; printf 'codex-cli 0.157.0' >&2", "0.157.0")
    ])
    func preservesOutputPriorityAndStrictDecoding(_ fixture: (String, String)) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.executable(fixture.0)
        let service = CodexVersionService(environment: [:], installations: .init(standalonePath: command.path, bundledPath: nil))
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.installedItems == [.init(source: .standalone, path: command.path, result: .success(fixture.1))])
    }

    @Test(arguments: [
        ("exit 7", 5.0, CodexVersionItem.ProbeFailure.read),
        ("exit 0", 5.0, .parse),
        ("trap '' TERM; while :; do :; done", 0.15, .timeout)
    ])
    func preservesProbeFailures(_ body: String, timeout: TimeInterval, expectedFailure: CodexVersionItem.ProbeFailure) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.executable(body)
        let service = CodexVersionService(
            timeout: timeout, environment: [:],
            installations: .init(standalonePath: command.path, bundledPath: nil)
        )
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.installedItems == [.init(source: .standalone, path: command.path, result: .failure(expectedFailure))])
    }

    @Test func preservesLaunchFailureForANonExecutableFile() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let command = try directory.write("not executable", to: "codex")
        let service = CodexVersionService(environment: [:], installations: .init(standalonePath: nil, bundledPath: command.path))
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.installedItems == [.init(source: .bundled, path: command.path, result: .failure(.launch))])
    }

    @Test func probesBothSourcesConcurrently() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let standalone = try directory.executable("""
        printf ready > "$PROCESS_TEST_DIR/standalone.ready"
        while [ ! -f "$PROCESS_TEST_DIR/bundled.ready" ]; do /bin/sleep 0.01; done
        printf 'codex-cli 0.157.0'
        """, named: "standalone")
        let bundled = try directory.executable("""
        printf ready > "$PROCESS_TEST_DIR/bundled.ready"
        while [ ! -f "$PROCESS_TEST_DIR/standalone.ready" ]; do /bin/sleep 0.01; done
        printf 'codex-cli 0.158.0'
        """, named: "bundled")
        let service = CodexVersionService(
            timeout: 3, environment: ["PROCESS_TEST_DIR": directory.url.path],
            installations: .init(standalonePath: standalone.path, bundledPath: bundled.path)
        )
        let snapshot = await service.fetchSnapshot()
        #expect(snapshot.installedItems == [
            .init(source: .standalone, path: standalone.path, result: .success("0.157.0")),
            .init(source: .bundled, path: bundled.path, result: .success("0.158.0"))
        ])
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
        let standalone = try command(named: "standalone")
        let bundled = try command(named: "bundled")
        let service = CodexVersionService(
            timeout: 15, environment: ["PROCESS_TEST_DIR": directory.url.path],
            installations: .init(standalonePath: standalone.path, bundledPath: bundled.path)
        )
        let task = Task { await service.fetchSnapshot() }
        defer { task.cancel() }
        try await directory.waitForFile("standalone.ready")
        try await directory.waitForFile("bundled.ready")
        let overlapping = await service.fetchSnapshot()
        #expect(overlapping.installedItems.map(\.result) == [.failure(.read), .failure(.read)])
        let started = ContinuousClock.now
        task.cancel()
        _ = await task.value
        #expect(started.duration(to: .now) < .seconds(3))
        _ = try directory.write("retry", to: "retry")
        let retried = await service.fetchSnapshot()
        #expect(retried.installedItems.map(\.result) == [.success("0.157.0"), .success("0.157.0")])
    }
}
