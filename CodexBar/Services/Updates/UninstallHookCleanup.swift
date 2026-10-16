import Foundation

actor UninstallHookCleanup {
    typealias State = [String: UninstallHookTrustConfig.Value]

    nonisolated struct Identity: Codable, Hashable, Sendable {
        let event: String
        let command: String
        let hash: String
    }

    nonisolated struct Hook: Codable, Sendable {
        let key: String
        let identity: Identity
    }

    nonisolated struct Recovery: Codable, Sendable {
        let schema: Int
        let executablePath: String
        let original: Data
        let updated: Data
        let initialState: State
        let keys: Set<String>
        let survivors: [Hook]
        var finalState: State?

        var clearedState: State {
            initialState.filter { !keys.contains($0.key) }
        }
    }

    @discardableResult
    func remove(hooksURL: URL, executablePath: String, client: any UninstallHookClient) async throws -> Bool {
        let recoveryURL = HookConfigurationAccess.recoveryURL(for: hooksURL)
        guard try HookConfigurationAccess.read(hooksURL) != nil || HookConfigurationAccess.read(recoveryURL, limit: 8 * 1024 * 1024) != nil else { return false }
        let lease = try HookConfigurationAccess.acquire(hooksURL: hooksURL, recovering: true)
        defer { withExtendedLifetime(lease) {} }
        let configURL = hooksURL.deletingLastPathComponent().appending(path: "config.toml")
        var recovery: Recovery
        if let data = try HookConfigurationAccess.read(recoveryURL, limit: 8 * 1024 * 1024) {
            recovery = try JSONDecoder().decode(Recovery.self, from: data)
            guard recovery.schema == 1, recovery.executablePath == executablePath else {
                throw AppUninstallError("存在其他 App 的 Hook 卸载恢复记录")
            }
        } else {
            guard let original = try HookConfigurationAccess.read(hooksURL), !original.isEmpty,
                  let updated = try await AdvancedModeSettings.removingHooksForUninstall(from: original, executablePath: executablePath) else { return false }
            let listed = try await client.listHooks()
            let owned = try await AdvancedModeSettings.uninstallHookTrustKeys(from: listed, executablePath: executablePath, hooksURL: hooksURL)
            let hooks = try Self.hooks(from: listed, at: hooksURL)
            let survivors = hooks.filter { !owned.contains($0.key) }
            guard Set(survivors.map(\.identity)).count == survivors.count else {
                throw AppUninstallError("存在身份重复的 Hook, 无法安全迁移信任记录")
            }
            let config = try await client.readConfig()
            recovery = try Recovery(
                schema: 1, executablePath: executablePath, original: original, updated: updated,
                initialState: config.userLayer(at: configURL).config.hooks?.state ?? [:],
                keys: Set(hooks.map(\.key)), survivors: survivors
            )
            try verifyFile(hooksURL, equals: original)
            try save(recovery, to: recoveryURL)
        }
        try Task.checkCancellation()
        let current = try HookConfigurationAccess.read(hooksURL)
        guard current == recovery.original || current == recovery.updated else {
            throw AppUninstallError("Hook 配置与恢复记录不一致, 已保留外部修改")
        }
        if current == recovery.original {
            // 下标复用前先撤销受影响记录, 避免旧 key 暂时授权给另一个 handler
            try await replaceState(
                recovery.initialState, with: recovery.clearedState, client: client, configURL: configURL,
                hooksURL: hooksURL, expectedHooks: recovery.original
            )
            try HookConfigurationAccess.replace(hooksURL, expected: recovery.original, with: recovery.updated)
        }
        let after = try await Self.hooks(from: client.listHooks(), at: hooksURL)
        let finalState = try Self.migratedState(recovery: recovery, remaining: after)
        guard recovery.finalState == nil || recovery.finalState == finalState else {
            throw AppUninstallError("Hook 身份与恢复记录不一致")
        }
        recovery.finalState = finalState
        try verifyFile(hooksURL, equals: recovery.updated)
        try save(recovery, to: recoveryURL)
        try await replaceState(
            recovery.clearedState, with: finalState, client: client, configURL: configURL,
            hooksURL: hooksURL, expectedHooks: recovery.updated
        )
        try verifyFile(hooksURL, equals: recovery.updated)
        try FileManager.default.removeItem(at: recoveryURL)
        return true
    }

    func verifyRemoved(hooksURL: URL, executablePath: String) async throws {
        let recoveryURL = HookConfigurationAccess.recoveryURL(for: hooksURL)
        guard try HookConfigurationAccess.read(recoveryURL, limit: 8 * 1024 * 1024) == nil else {
            throw AppUninstallError("Hook 清理尚有未完成的恢复记录")
        }
        guard let data = try HookConfigurationAccess.read(hooksURL), !data.isEmpty else { return }
        guard try await AdvancedModeSettings.removingHooksForUninstall(from: data, executablePath: executablePath) == nil else {
            throw AppUninstallError("当前 App 的 Hook 仍存在")
        }
    }

    static func migratedState(recovery: Recovery, remaining: [Hook]) throws -> State {
        guard remaining.count == recovery.survivors.count,
              Set(remaining.map(\.identity)).count == remaining.count,
              Set(remaining.map(\.identity)) == Set(recovery.survivors.map(\.identity)) else {
            throw AppUninstallError("剩余 Hook 身份或内容发生变化, 已停止信任迁移")
        }
        let destinations = Dictionary(uniqueKeysWithValues: remaining.map { ($0.identity, $0.key) })
        var result = recovery.clearedState
        for hook in recovery.survivors {
            guard let key = destinations[hook.identity], result[key] == nil else {
                throw AppUninstallError("Hook 信任标识与其他记录冲突, 已停止迁移")
            }
            // 不生成新授权, 原记录缺失或哈希过期时保持原有未信任状态
            result[key] = recovery.initialState[hook.key]
        }
        return result
    }

    private static func hooks(from response: CodexHooksListResponse, at url: URL) throws -> [Hook] {
        guard !response.data.isEmpty, response.data.allSatisfy({ $0.errors.isEmpty && $0.warnings.isEmpty }) else {
            throw AppUninstallError("Codex 未完整读取 Hook 配置")
        }
        let records = try response.data.flatMap(\.hooks).filter {
            URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
        }.map { hook in
            guard let key = hook.key, !key.isEmpty, let command = hook.command,
                  let hash = hook.currentHash, !hash.isEmpty else {
                throw AppUninstallError("Hook 缺少可验证的身份")
            }
            return Hook(key: key, identity: Identity(event: hook.eventName, command: command, hash: hash))
        }
        guard Set(records.map(\.key)).count == records.count else { throw AppUninstallError("Codex 返回重复的 Hook 标识") }
        return records
    }

    private func replaceState(
        _ original: State, with updated: State, client: any UninstallHookClient, configURL: URL,
        hooksURL: URL, expectedHooks: Data
    ) async throws {
        let config = try await client.readConfig()
        let state = try config.userLayer(at: configURL).config.hooks?.state ?? [:]
        try verifyFile(hooksURL, equals: expectedHooks)
        if state == updated {
            return
        }
        guard state == original else { throw AppUninstallError("Hook 信任配置已被其他进程修改") }
        try await client.writeState(updated, replacing: config, at: configURL)
        let verified = try await client.readConfig().userLayer(at: configURL).config.hooks?.state ?? [:]
        guard verified == updated else { throw AppUninstallError("Codex 未确认 Hook 信任写入结果, 请重试卸载") }
        try verifyFile(hooksURL, equals: expectedHooks)
    }

    private func verifyFile(_ url: URL, equals data: Data) throws {
        guard try HookConfigurationAccess.read(url) == data else { throw AppUninstallError("Hook 配置被其他进程修改") }
    }

    private func save(_ recovery: Recovery, to url: URL) throws {
        let data = try JSONEncoder().encode(recovery)
        guard data.count <= 8 * 1024 * 1024 else { throw AppUninstallError("Hook 卸载恢复记录过大") }
        try HookConfigurationAccess.saveRecovery(data, to: url)
    }
}
