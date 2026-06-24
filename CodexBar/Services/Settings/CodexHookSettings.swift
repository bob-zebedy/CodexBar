import Combine
import Foundation

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
            try ensureCurrentUpdate(generation)
            isEnabled = enabled
            if enabled {
                await verifyInstalledHooksWithAppServer(generation: generation)
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
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
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
        let response = try await codexStatusService.listCodexHooks(cwds: [hooksListWorkingDirectory])
        if let message = Self.validationMessage(
            from: response,
            executablePath: currentExecutablePath,
            hooksURL: hooksURL
        ) {
            throw HookConfigError.hookValidationFailed(message)
        }
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
        guard let hooks = config["hooks"] as? JSONObject else {
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

        for event in CodexHookEvent.allCases {
            var groups = try eventGroups(named: event.configName, from: hooks)
            groups.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand(executablePath: executablePath),
                        "timeout": 5
                    ]
                ]
            ])
            hooks[event.configName] = groups
        }

        config["hooks"] = hooks
    }

    static func removeCodexBarHooks(
        from config: inout JSONObject,
        executablePath: String
    ) throws {
        guard config["hooks"] != nil else {
            return
        }

        var hooks = try hooksObject(from: config)

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

        config["hooks"] = hooks
    }

    static func validationMessage(
        from response: CodexHooksListResponse,
        executablePath: String,
        hooksURL: URL
    ) -> String? {
        guard !response.data.isEmpty else {
            return "hooks/list 没有返回任何结果"
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
            hasUntrustedHook = hasUntrustedHook || hook.trustStatus == "untrusted" || hook.trustStatus == "modified"
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

    static func hooksObject(from config: JSONObject) throws -> JSONObject {
        guard let value = config["hooks"] else {
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
        guard let handlers = handlers(from: group) else {
            return false
        }

        return handlers.contains {
            isCurrentCodexBarHandler($0, executablePath: executablePath)
        }
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

        groupObject["hooks"] = filteredHandlers
        return groupObject
    }

    static func handlers(from group: Any) -> JSONArray? {
        guard let group = group as? JSONObject else {
            return nil
        }

        return group["hooks"] as? JSONArray
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
              handler["type"] as? String == "command",
              let command = handler["command"] as? String else {
            return nil
        }

        return command
    }

    static func hookCommand(executablePath: String) -> String {
        shellQuoted(executablePath)
    }

    static func isCodexBarCommand(_ command: String, executablePath: String) -> Bool {
        command.contains(hookCommand(executablePath: executablePath))
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
