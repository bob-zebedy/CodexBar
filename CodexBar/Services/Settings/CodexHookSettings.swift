import Combine
import Foundation

/// 设置页的 Codex Hook 开关状态机, 同时管理 hooks.json 和 Codex 信任状态
@MainActor
final class CodexHookSettings: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    private let hooksURL: URL
    private let fileManager: FileManager
    private let codexStatusService: CodexStatusService
    private var updateTask: Task<Void, Never>?
    private var updateGeneration = 0

    init(
        hooksURL: URL = CodexHookSettings.defaultHooksURL(),
        fileManager: FileManager = .default,
        codexStatusService: CodexStatusService
    ) {
        self.hooksURL = hooksURL
        self.fileManager = fileManager
        self.codexStatusService = codexStatusService
    }

    deinit {
        updateTask?.cancel()
    }

    func refresh() {
        do {
            let config = try readConfigIfPresent()
            isEnabled = Self.containsAnyCodexBarHook(
                in: config,
                executablePath: currentExecutablePath
            )
            errorMessage = nil
        } catch {
            isEnabled = false
            errorMessage = "读取 Codex Hook 配置失败: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        runLatestUpdate(showProgress: true) { settings, generation in
            await settings.applyEnabled(enabled, generation: generation)
        }
    }

    func verifyInstalledHooks() {
        guard isEnabled, !isUpdating else {
            return
        }

        runLatestUpdate(showProgress: false) { settings, generation in
            await settings.verifyInstalledHooksWithAppServer(generation: generation)
        }
    }

    private func applyEnabled(_ enabled: Bool, generation: Int) async {
        do {
            if enabled {
                try await ensureCodexHooksGloballyEnabled()
                try ensureCurrentUpdate(generation)
            }

            // 关闭前先通过 hooks/list 拿到 key
            // hooks.json 删除后 app-server 就无法再反查这些 key
            let cleanupPlan = try await hookTrustCleanupPlan(isDisabling: !enabled, generation: generation)
            try writeCodexBarHookConfig(enabled: enabled)
            try ensureCurrentUpdate(generation)
            isEnabled = enabled
            if enabled {
                await verifyInstalledHooksWithAppServer(generation: generation)
            } else {
                await cleanupCodexHookTrust(
                    removing: cleanupPlan.keys,
                    discoveryError: cleanupPlan.discoveryError,
                    generation: generation
                )
            }
        } catch is CancellationError {
            return
        } catch {
            handleApplyError(error, generation: generation)
        }
    }

    private func verifyInstalledHooksWithAppServer(generation: Int) async {
        do {
            try await validateInstalledHooksWithAppServer()
            try ensureCurrentUpdate(generation)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as HookConfigError {
            guard isCurrentUpdate(generation) else {
                return
            }

            errorMessage = error.localizedDescription
        } catch {
            guard isCurrentUpdate(generation) else {
                return
            }

            errorMessage = "无法验证 Codex Hook: \(error.localizedDescription)"
        }
    }

    private func runLatestUpdate(
        showProgress: Bool,
        _ operation: @escaping @MainActor (CodexHookSettings, Int) async -> Void
    ) {
        updateTask?.cancel()
        updateGeneration += 1
        let generation = updateGeneration

        if showProgress {
            isUpdating = true
            errorMessage = nil
        }

        updateTask = Task { [weak self] in
            guard let self else {
                return
            }

            await operation(self, generation)
            finishUpdate(generation, showProgress: showProgress)
        }
    }

    private func finishUpdate(_ generation: Int, showProgress: Bool) {
        guard isCurrentUpdate(generation) else {
            return
        }

        if showProgress {
            isUpdating = false
        }
        updateTask = nil
    }

    private func isCurrentUpdate(_ generation: Int) -> Bool {
        generation == updateGeneration
    }

    private func ensureCurrentUpdate(_ generation: Int) throws {
        try Task.checkCancellation()

        guard isCurrentUpdate(generation) else {
            throw CancellationError()
        }
    }

    private func handleApplyError(_ error: Error, generation: Int) {
        guard isCurrentUpdate(generation) else {
            return
        }

        if let hookError = error as? HookConfigError,
           hookError.isPreflightFailure {
            isEnabled = false
            errorMessage = hookError.localizedDescription
        } else {
            refresh()
            errorMessage = "设置 Codex Hook 失败: \(error.localizedDescription)"
        }
    }
}

private extension CodexHookSettings {
    typealias JSONObject = [String: Any]
    typealias JSONArray = [Any]

    static let hooksKey = "hooks"
    static let hookTypeKey = "type"
    static let hookCommandKey = "command"
    static let hookTimeoutKey = "timeout"
    static let hookCommandType = "command"
    static let hookTimeout = 5
    static let configMergeStrategyReplace = "replace"
    static let configMergeStrategyUpsert = "upsert"
    static let hookTrustStateKeyPath = "hooks.state"
    static let trustedHashKey = "trusted_hash"

    struct CodexHookTrustEntry {
        let key: String
        let trustedHash: String
    }

    /// discoveryError 会在 Hook 已关闭后展示, 说明仅信任状态清理未完成
    struct CodexHookTrustCleanupPlan {
        let keys: Set<String>
        let discoveryError: Error?

        static let empty = Self(keys: [], discoveryError: nil)
    }

    enum HookConfigError: LocalizedError {
        case invalidFormat
        case hooksGloballyDisabled
        case hookValidationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                "hooks.json 文件格式错误"
            case .hooksGloballyDisabled:
                "Codex 配置已禁用 Hook"
            case let .hookValidationFailed(message):
                message
            }
        }

        var isPreflightFailure: Bool {
            if case .hooksGloballyDisabled = self {
                return true
            }
            return false
        }
    }

    nonisolated static func defaultHooksURL() -> URL {
        CodexCLIResolver.codexHomeDirectory()
            .appendingPathComponent("hooks.json")
    }

    var currentExecutablePath: String {
        Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? "/Applications/CodexBar.app/Contents/MacOS/CodexBar"
    }

    var hooksListWorkingDirectory: String {
        fileManager.homeDirectoryForCurrentUser.path
    }

    func ensureCodexHooksGloballyEnabled() async throws {
        let response = try await codexStatusService.readCodexConfig()
        if response.hooksGloballyDisabled {
            throw HookConfigError.hooksGloballyDisabled
        }
    }

    func validateInstalledHooksWithAppServer() async throws {
        var response = try await codexStatusService.listCodexHooks(cwds: [hooksListWorkingDirectory])
        // 只信任 command/sourcePath/event 都匹配当前 CodexBar 的 Hook
        let entries = Self.hookTrustEntriesNeedingUpdate(
            from: response,
            executablePath: currentExecutablePath,
            hooksURL: hooksURL
        )
        if !entries.isEmpty {
            try await trustCodexBarHooks(entries)
            response = try await codexStatusService.listCodexHooks(cwds: [hooksListWorkingDirectory])
        }

        if let message = Self.validationMessage(
            from: response,
            executablePath: currentExecutablePath,
            hooksURL: hooksURL
        ) {
            throw HookConfigError.hookValidationFailed(message)
        }
    }

    func hookTrustCleanupPlan(isDisabling: Bool, generation: Int) async throws -> CodexHookTrustCleanupPlan {
        guard isDisabling else {
            return .empty
        }

        do {
            let keys = try await codexBarHookTrustKeysFromAppServer()
            try ensureCurrentUpdate(generation)
            return .init(keys: keys, discoveryError: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .init(keys: [], discoveryError: error)
        }
    }

    func writeCodexBarHookConfig(enabled: Bool) throws {
        var config = try readConfigIfPresent()
        try Self.removeCodexBarHooks(
            from: &config,
            executablePath: currentExecutablePath
        )

        if enabled {
            try Self.installCodexBarHooks(
                in: &config,
                executablePath: currentExecutablePath
            )
        }

        try write(config)
    }

    func codexBarHookTrustKeysFromAppServer() async throws -> Set<String> {
        let response = try await codexStatusService.listCodexHooks(cwds: [hooksListWorkingDirectory])
        return Self.codexBarHookTrustKeys(
            from: response,
            executablePath: currentExecutablePath,
            hooksURL: hooksURL
        )
    }

    func cleanupCodexHookTrust(
        removing keys: Set<String>,
        discoveryError: Error?,
        generation: Int
    ) async {
        do {
            try ensureCurrentUpdate(generation)
            if !keys.isEmpty {
                try await removeCodexBarHookTrust(keys)
                try ensureCurrentUpdate(generation)
            }

            if let discoveryError {
                errorMessage = "已关闭 Codex Hook, 清理信任状态失败: \(discoveryError.localizedDescription)"
            } else {
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentUpdate(generation) else {
                return
            }

            errorMessage = "已关闭 Codex Hook, 清理信任状态失败: \(error.localizedDescription)"
        }
    }

    func trustCodexBarHooks(_ entries: [CodexHookTrustEntry]) async throws {
        guard !entries.isEmpty else {
            return
        }

        try await writeHookTrustState(
            Self.hookTrustStateValue(from: entries),
            mergeStrategy: Self.configMergeStrategyUpsert
        )
    }

    func removeCodexBarHookTrust(_ keys: Set<String>) async throws {
        guard !keys.isEmpty else {
            return
        }

        let response = try await codexStatusService.readCodexConfig()
        var state = response.hookTrustState
        // 先读出现有 state 再 replace, 只删除 CodexBar key, 保留用户自己的信任项
        for key in keys {
            state.removeValue(forKey: key)
        }

        try await writeHookTrustState(
            Self.hookTrustStateValue(from: state),
            mergeStrategy: Self.configMergeStrategyReplace
        )
    }

    func writeHookTrustState(
        _ value: [String: [String: String]],
        mergeStrategy: String
    ) async throws {
        _ = try await codexStatusService.writeCodexConfigBatch(
            edits: [
                .init(
                    keyPath: Self.hookTrustStateKeyPath,
                    value: value,
                    mergeStrategy: mergeStrategy
                )
            ]
        )
    }

    func readConfigIfPresent() throws -> JSONObject {
        guard fileManager.fileExists(atPath: hooksURL.path) else {
            return [:]
        }

        return try readConfig()
    }

    func readConfig() throws -> JSONObject {
        let data = try Data(contentsOf: hooksURL)
        guard !data.isEmpty else {
            return [:]
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HookConfigError.invalidFormat
        }

        guard let config = object as? JSONObject else {
            throw HookConfigError.invalidFormat
        }

        return config
    }

    func write(_ config: JSONObject) throws {
        try fileManager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: hooksURL, options: .atomic)
    }

    static func containsAnyCodexBarHook(in config: JSONObject, executablePath: String) -> Bool {
        guard let hooks = config[hooksKey] as? JSONObject else {
            return false
        }

        return CodexHookEvent.allCases.contains { event in
            guard let groups = hooks[event.configName] as? JSONArray else {
                return false
            }

            return groups.contains {
                groupContainsCodexBarHandler($0, executablePath: executablePath)
            }
        }
    }

    static func installCodexBarHooks(in config: inout JSONObject, executablePath: String) throws {
        var hooks = try hooksObject(from: config)

        // 每个事件追加一个独立 group, 避免和用户已有 group 混写
        for event in CodexHookEvent.allCases {
            var groups = try eventGroups(named: event.configName, from: hooks)
            groups.append([
                hooksKey: [codexBarHookHandler(executablePath: executablePath)]
            ])
            hooks[event.configName] = groups
        }

        config[hooksKey] = hooks
    }

    static func removeCodexBarHooks(
        from config: inout JSONObject,
        executablePath: String
    ) throws {
        guard config[hooksKey] != nil else {
            return
        }

        var hooks = try hooksObject(from: config)

        // 仅移除 command 同时匹配当前可执行路径与 --hook-event 的 handler
        for (event, value) in hooks {
            guard let groups = value as? JSONArray else {
                throw HookConfigError.invalidFormat
            }

            let filteredGroups = groups.compactMap {
                groupRemovingCodexBarHandlers(
                    from: $0,
                    executablePath: executablePath
                )
            }

            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filteredGroups
            }
        }

        config[hooksKey] = hooks
    }

    static func validationMessage(
        from response: CodexHooksListResponse,
        executablePath: String,
        hooksURL: URL
    ) -> String? {
        guard !response.data.isEmpty else {
            return "Codex 没有返回任何结果"
        }

        let entries = response.data
        let hooks = entries.flatMap(\.hooks)
        let warnings = entries.flatMap(\.warnings)
        let errors = entries.flatMap(\.errors)
        let expectedSourcePath = normalizedPath(hooksURL.path)
        var hasMissingEvent = false
        var hasDisabledHook = false
        var hasUnexpectedSource = false
        var hasUntrustedHook = false

        for event in CodexHookEvent.allCases {
            guard let hook = matchingHook(
                for: event,
                in: hooks,
                executablePath: executablePath,
                expectedSourcePath: expectedSourcePath
            ) else {
                hasMissingEvent = true
                continue
            }

            hasDisabledHook = hasDisabledHook || !hook.enabled
            hasUnexpectedSource = hasUnexpectedSource || normalizedPath(hook.sourcePath) != expectedSourcePath
            hasUntrustedHook = hasUntrustedHook || hookNeedsTrustUpdate(hook)
        }

        if !errors.isEmpty {
            return "Codex 返回错误"
        }
        if hasDisabledHook {
            return "CodexBar Hook 已被禁用"
        }
        if hasUntrustedHook {
            return "CodexBar Hook 未被信任"
        }
        if hasMissingEvent {
            return "CodexBar Hook 已不完整"
        }
        if hasUnexpectedSource {
            return "CodexBar Hook 意外来源"
        }
        if !warnings.isEmpty {
            return "Codex 返回警告"
        }

        return nil
    }

    static func hookTrustEntriesNeedingUpdate(
        from response: CodexHooksListResponse,
        executablePath: String,
        hooksURL: URL
    ) -> [CodexHookTrustEntry] {
        let hooks = response.data.flatMap(\.hooks)
        let expectedSourcePath = normalizedPath(hooksURL.path)
        var entries: [CodexHookTrustEntry] = []
        var seenKeys = Set<String>()

        for event in CodexHookEvent.allCases {
            guard let hook = matchingHook(
                for: event,
                in: hooks,
                executablePath: executablePath,
                expectedSourcePath: expectedSourcePath
            ),
                isManagedCodexBarHook(
                    hook,
                    executablePath: executablePath,
                    expectedSourcePath: expectedSourcePath
                ),
                hookNeedsTrustUpdate(hook),
                let key = hook.key,
                let trustedHash = hook.currentHash,
                !key.isEmpty,
                !trustedHash.isEmpty,
                seenKeys.insert(key).inserted else {
                continue
            }

            entries.append(.init(key: key, trustedHash: trustedHash))
        }

        return entries
    }

    static func codexBarHookTrustKeys(
        from response: CodexHooksListResponse,
        executablePath: String,
        hooksURL: URL
    ) -> Set<String> {
        let expectedSourcePath = normalizedPath(hooksURL.path)
        return Set(
            response.data
                .flatMap(\.hooks)
                .compactMap { hook in
                    guard isManagedCodexBarHook(
                        hook,
                        executablePath: executablePath,
                        expectedSourcePath: expectedSourcePath
                    ),
                        let key = hook.key,
                        !key.isEmpty else {
                        return nil
                    }

                    return key
                }
        )
    }

    static func matchingHook(
        for event: CodexHookEvent,
        in hooks: [CodexHookMetadata],
        executablePath: String,
        expectedSourcePath: String
    ) -> CodexHookMetadata? {
        let matchingHooks = hooks.filter {
            ($0.command.map { isCodexBarCommand($0, executablePath: executablePath) } ?? false)
                && $0.eventName == event.appServerName
        }
        return matchingHooks.first { normalizedPath($0.sourcePath) == expectedSourcePath }
            ?? matchingHooks.first
    }

    static func isManagedCodexBarHook(
        _ hook: CodexHookMetadata,
        executablePath: String,
        expectedSourcePath: String
    ) -> Bool {
        guard let command = hook.command else {
            return false
        }

        // 自动信任/清理必须同时匹配命令和 sourcePath, 防止误碰用户 Hook
        return isCodexBarCommand(command, executablePath: executablePath)
            && normalizedPath(hook.sourcePath) == expectedSourcePath
    }

    static func hookNeedsTrustUpdate(_ hook: CodexHookMetadata) -> Bool {
        switch hook.trustStatus.lowercased() {
        case "untrusted", "modified":
            true
        default:
            false
        }
    }

    static func hookTrustStateValue(from state: [String: String]) -> [String: [String: String]] {
        state.mapValues { [trustedHashKey: $0] }
    }

    static func hookTrustStateValue(from entries: [CodexHookTrustEntry]) -> [String: [String: String]] {
        entries.reduce(into: [:]) { value, entry in
            value[entry.key] = [trustedHashKey: entry.trustedHash]
        }
    }

    static func hooksObject(from config: JSONObject) throws -> JSONObject {
        guard let value = config[hooksKey] else {
            return [:]
        }

        guard let hooks = value as? JSONObject else {
            throw HookConfigError.invalidFormat
        }

        return hooks
    }

    static func eventGroups(named event: String, from hooks: JSONObject) throws -> JSONArray {
        guard let value = hooks[event] else {
            return []
        }

        guard let groups = value as? JSONArray else {
            throw HookConfigError.invalidFormat
        }

        return groups
    }

    static func groupContainsCodexBarHandler(
        _ group: Any,
        executablePath: String
    ) -> Bool {
        handlers(from: group)?.contains {
            isCurrentCodexBarHandler($0, executablePath: executablePath)
        } ?? false
    }

    static func groupRemovingCodexBarHandlers(
        from group: Any,
        executablePath: String
    ) -> Any? {
        guard var groupObject = group as? JSONObject,
              let handlers = handlers(from: group) else {
            return group
        }

        let filteredHandlers = handlers.filter {
            !isCurrentCodexBarHandler($0, executablePath: executablePath)
        }
        guard !filteredHandlers.isEmpty else {
            return nil
        }

        groupObject[hooksKey] = filteredHandlers
        return groupObject
    }

    static func handlers(from group: Any) -> JSONArray? {
        guard let group = group as? JSONObject else {
            return nil
        }

        return group[hooksKey] as? JSONArray
    }

    static func isCurrentCodexBarHandler(
        _ handler: Any,
        executablePath: String
    ) -> Bool {
        guard let command = commandIfCommandHandler(handler) else {
            return false
        }

        return isCodexBarCommand(command, executablePath: executablePath)
    }

    /// 仅当 handler 是 type == "command" 时返回其 command 字符串, 否则 nil
    private static func commandIfCommandHandler(_ handler: Any) -> String? {
        guard let handler = handler as? JSONObject,
              handler[hookTypeKey] as? String == hookCommandType,
              let command = handler[hookCommandKey] as? String else {
            return nil
        }

        return command
    }

    static func codexBarHookHandler(executablePath: String) -> JSONObject {
        [
            hookTypeKey: hookCommandType,
            hookCommandKey: hookCommand(executablePath: executablePath),
            hookTimeoutKey: hookTimeout
        ]
    }

    static func hookCommand(executablePath: String) -> String {
        "\(shellQuoted(executablePath)) \(WorkflowHookEventRecorder.hookArgument)"
    }

    static func isCodexBarCommand(_ command: String, executablePath: String) -> Bool {
        // 使用 shell quoted 路径匹配当前 app, 再要求带有 Hook 子进程参数
        command.contains(shellQuoted(executablePath))
            && command.split(whereSeparator: \.isWhitespace)
            .contains(Substring(WorkflowHookEventRecorder.hookArgument))
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func normalizedPath(_ path: String) -> String {
        CodexCLIResolver.canonicalPath(path, expandingTilde: true)
    }
}
