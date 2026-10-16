import Foundation
import Testing

actor MockUninstallHookClient: UninstallHookClient {
    typealias State = [String: UninstallHookTrustConfig.Value]
    let hooksURL: URL
    var state: State
    var version = 1
    var writes = 0
    var failingWrite: Int?
    var failAfterWrite = false
    var concurrentHooks: Data?
    var lists = 0
    var failingList: Int?

    init(hooksURL: URL, state: State = [:]) {
        self.hooksURL = hooksURL
        self.state = state
    }

    func configure(failingWrite: Int? = nil, failAfterWrite: Bool = false, concurrentHooks: Data? = nil, failingList: Int? = nil) {
        self.failingWrite = failingWrite
        self.failAfterWrite = failAfterWrite
        self.concurrentHooks = concurrentHooks
        self.failingList = failingList
    }

    func listHooks() throws -> CodexHooksListResponse {
        lists += 1
        if lists == failingList {
            throw AppUninstallError("Hook 查询失败")
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        var metadata: [[String: Any]] = []
        for (event, groups) in config?["hooks"] as? [String: [[String: Any]]] ?? [:] {
            for (groupIndex, group) in groups.enumerated() {
                for (handlerIndex, handler) in (group["hooks"] as? [[String: Any]] ?? []).enumerated() {
                    let command = handler["command"] as? String ?? ""
                    let key = "\(event):\(groupIndex):\(handlerIndex)"
                    metadata.append([
                        "eventName": event, "command": command, "enabled": true, "sourcePath": hooksURL.path,
                        "trustStatus": "untrusted", "key": key, "currentHash": command
                    ])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": [["cwd": "/test", "hooks": metadata, "warnings": [], "errors": []]]])
        return try JSONDecoder().decode(CodexHooksListResponse.self, from: data)
    }

    func readConfig() throws -> UninstallHookTrustConfig {
        let layer: [String: Any] = [
            "name": ["type": "user", "file": hooksURL.deletingLastPathComponent().appending(path: "config.toml").path],
            "version": String(version), "config": ["hooks": ["state": state.mapValues(\.object)]]
        ]
        return try JSONDecoder().decode(UninstallHookTrustConfig.self, from: JSONSerialization.data(withJSONObject: ["layers": [layer]]))
    }

    func writeState(_ updated: State, replacing config: UninstallHookTrustConfig, at url: URL) throws {
        guard try config.userLayer(at: url).version == String(version) else { throw AppUninstallError("配置版本冲突") }
        writes += 1
        if writes == failingWrite, !failAfterWrite {
            throw AppUninstallError("写入前失败")
        }
        state = updated
        version += 1
        if let concurrentHooks {
            try concurrentHooks.write(to: hooksURL, options: .atomic)
        }
        if writes == failingWrite {
            throw AppUninstallError("写入后失去响应")
        }
    }

    func externallyChangeState() {
        state["external"] = .bool(true)
    }
}

@MainActor
struct UninstallHookRecoveryTests {
    private let executable = "/test/app"
    private let own = "'/test/app' --hook-event"
    private let other = "echo other"

    @Test(arguments: [false, true])
    func preservesTrustAcrossHandlerAndGroupChanges(separateGroups: Bool) async throws {
        let url = try fixture(separateGroups: separateGroups)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let otherKey = separateGroups ? "Stop:1:0" : "Stop:0:1"
        let preserved: UninstallHookTrustConfig.Value = .dictionary(["trusted_hash": .string(other), "future": .array([.bool(false), .number(3)])])
        let client = MockUninstallHookClient(hooksURL: url, state: [
            "Stop:0:0": .dictionary(["trusted_hash": .string(own)]), otherKey: preserved,
            "unknown-orphan": .dictionary(["trusted_hash": .string("preserved")])
        ])
        try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        let state = await client.state
        #expect(state["Stop:0:0"] == preserved)
        #expect(state[otherKey] == nil)
        #expect(state["unknown-orphan"] != nil)
        #expect(!FileManager.default.fileExists(atPath: HookConfigurationAccess.recoveryURL(for: url).path))
        let writes = await client.writes
        try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        #expect(await client.writes == writes)
    }

    @Test(arguments: [false, true])
    func neverGrantsTrustToUntrustedHooks(staleRecord: Bool) async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var state: MockUninstallHookClient.State = ["Stop:0:0": .dictionary(["trusted_hash": .string(own)])]
        if staleRecord {
            state["Stop:0:1"] = .dictionary(["trusted_hash": .string("old-content")])
        }
        let client = MockUninstallHookClient(hooksURL: url, state: state)
        try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        #expect(await client.state["Stop:0:0"] == state["Stop:0:1"])
    }

    @Test(arguments: [1, 2], [false, true])
    func resumesAfterWriteFailure(write: Int, afterWrite: Bool) async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let client = MockUninstallHookClient(hooksURL: url, state: [
            "Stop:0:0": .dictionary(["trusted_hash": .string(own)]), "Stop:0:1": .dictionary(["trusted_hash": .string(other)])
        ])
        await client.configure(failingWrite: write, failAfterWrite: afterWrite)
        await #expect(throws: AppUninstallError.self) {
            try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        }
        let recovery = HookConfigurationAccess.recoveryURL(for: url)
        #expect(FileManager.default.fileExists(atPath: recovery.path))
        #expect(throws: AppUninstallError.self) { try HookConfigurationAccess.acquire(hooksURL: url) }
        let permissions = try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        await client.configure()
        try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        #expect(await client.state == ["Stop:0:0": .dictionary(["trusted_hash": .string(other)])])
        #expect(!FileManager.default.fileExists(atPath: recovery.path))
    }

    @Test func concurrentExternalChangesArePreserved() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let changed = Data(#"{"hooks":{},"external":true}"#.utf8)
        let client = MockUninstallHookClient(hooksURL: url, state: ["Stop:0:0": .dictionary(["trusted_hash": .string(own)])])
        await client.configure(concurrentHooks: changed)
        await #expect(throws: AppUninstallError.self) {
            try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        }
        #expect(try Data(contentsOf: url) == changed)
        await client.configure()
        await #expect(throws: AppUninstallError.self) {
            try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        }
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test func resumesWhenDiscoveryFailsAfterHookRemoval() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let client = MockUninstallHookClient(hooksURL: url, state: ["Stop:0:1": .dictionary(["trusted_hash": .string(other)])])
        await client.configure(failingList: 2)
        await #expect(throws: AppUninstallError.self) {
            try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        }
        #expect(try AdvancedModeSettings.removingHooksForUninstall(from: Data(contentsOf: url), executablePath: executable) == nil)
        await client.configure()
        try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        #expect(await client.state == ["Stop:0:0": .dictionary(["trusted_hash": .string(other)])])
    }

    @Test func ambiguousIdentityStopsBeforeMutation() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let groups = [["hooks": [["command": own], ["command": other], ["command": other]]]]
        let original = try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": groups]])
        try original.write(to: url)
        let client = MockUninstallHookClient(hooksURL: url)
        await #expect(throws: AppUninstallError.self) {
            try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client)
        }
        #expect(await client.writes == 0)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func conflictingTrustIsNotOverwrittenOnRecovery() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let client = MockUninstallHookClient(hooksURL: url, state: ["Stop:0:1": .dictionary(["trusted_hash": .string(other)])])
        await client.configure(failingWrite: 2)
        await #expect(throws: AppUninstallError.self) { try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client) }
        await client.configure()
        await client.externallyChangeState()
        await #expect(throws: AppUninstallError.self) { try await UninstallHookCleanup().remove(hooksURL: url, executablePath: executable, client: client) }
        #expect(await client.state["external"] == .bool(true))
    }

    @Test func configurationLockExcludesOtherAppWriters() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lock = try HookConfigurationAccess.acquire(hooksURL: url)
        _ = withExtendedLifetime(lock) {
            #expect(throws: AppUninstallError.self) { try HookConfigurationAccess.acquire(hooksURL: url, recovering: true) }
        }
    }

    @Test func configurationHandshakeDoesNotRequestAnAccount() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let directory = url.deletingLastPathComponent()
        let executable = directory.appending(path: "codex")
        let requests = directory.appending(path: "requests")
        let script = """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$CODEX_HOME/requests"
          case "$line" in
            *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{"userAgent":"codex_cli_rs/999.0.0"}}' ;;
            *'"method":"hooks/list"'*) printf '%s\\n' '{"id":2,"result":{"data":[]}}' ;;
            *'"method":"account/read"'*) exit 1 ;;
          esac
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = UninstallCodexClient(selection: .global, environment: ["PATH": directory.path + ":/usr/bin:/bin", "HOME": directory.path, "CODEX_HOME": directory.path])
        do {
            _ = try await client.listHooks()
            await client.close()
        } catch {
            await client.close()
            throw error
        }
        let sent = try String(contentsOf: requests, encoding: .utf8)
        #expect(sent.contains("hooks/list"))
        #expect(!sent.contains("account/read"))
    }

    private func fixture(separateGroups: Bool = false) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "UninstallHookRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "hooks.json")
        let first = ["type": "command", "command": own]
        let second = ["type": "command", "command": other]
        let groups = separateGroups ? [["hooks": [first]], ["hooks": [second]]] : [["hooks": [first, second]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": groups]]).write(to: url)
        return url
    }
}
