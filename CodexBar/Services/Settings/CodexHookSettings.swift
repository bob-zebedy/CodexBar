import Combine
import Foundation
import os

/// 设置页的 Codex Hook 开关状态机, 同时管理 hooks.json 和 Codex 信任状态
@MainActor
final class CodexHookSettings: ObservableObject {
    /// 当前进程中的 Hook 开启状态, 首次从现有配置恢复
    /// 开启后配置缺失视为需要自愈, 只有显式关闭或明确的低版本会置为 false
    @Published private(set) var isEnabled = false
    @Published private(set) var isUpdating = false
    /// 最近一次校验的明确结论: Codex 会不会真的执行 CodexBar 的 Hook
    /// 乐观默认: 启动对账开始前没有反证, 不能提前把依赖 Hook 的功能关掉
    /// 只由明确结论写入两个方向, RPC 失败或被取消时保留上次的值:
    /// 连不上 app-server 不说明 Hook 坏了, 那时置灰会把好用的功能关掉
    @Published private(set) var isVerified = true

    /// Hook 链路真的通不通: 当前进程中开启, 且最近一次校验没有明确失败
    /// 依赖 Hook 的下游 (防睡眠, 任务类通知) 一律看这个
    /// Codex 那边全局关掉 hooks 或者不信任我们的 handler 时 isEnabled 照样是 true
    var isOperable: Bool {
        isEnabled && isVerified
    }

    /// 读取 hooks.json 失败, 由 refreshInstallationState() 独立维护
    @Published private var readErrorMessage: String?
    /// 开关操作与 Hook 校验的结果, 只能由下一次操作或校验覆盖
    /// 与读取类错误分开存储: 每轮对账都会读取配置, 不能抹掉校验告警
    @Published private var operationErrorMessage: String?

    var errorMessage: String? {
        operationErrorMessage ?? readErrorMessage
    }

    private let hooksURL: URL
    private let fileManager: FileManager
    private let codexStatusService: CodexStatusService
    private let updateCoordinator = RefreshTaskCoordinator()
    /// refreshInstallationState() 上次读到的安装结论, 首次读取前为 nil
    /// 不能用 isEnabled 代替: 开启后它会刻意不跟随外部配置丢失
    private var lastKnownInstalled: Bool?

    init(
        hooksURL: URL = CodexHookSettings.defaultHooksURL(),
        fileManager: FileManager = .default,
        codexStatusService: CodexStatusService
    ) {
        self.hooksURL = hooksURL
        self.fileManager = fileManager
        self.codexStatusService = codexStatusService
    }

    // MARK: - 对外入口

    private func refreshInstallationState() {
        do {
            let config = try readConfigIfPresent()
            let installed = Self.containsAnyCodexBarHook(
                in: config,
                executablePath: currentExecutablePath
            )
            if installed {
                isEnabled = true
            }
            let isComplete = Self.containsAllCodexBarHooks(
                in: config,
                executablePath: currentExecutablePath
            )
            // 每次开面板都会读一遍, 无条件记会刷屏
            // 只在结论变了才记, 外部改动 ~/.codex/hooks.json 就是从这条看出来的
            // 首次读取没有可比的上次值; 拿 isEnabled 的初始 false 去比, 会让装了 Hook 的用户每次启动误报一条
            if let lastKnownInstalled, lastKnownInstalled != installed {
                AppLog.hooks.notice("Hook 配置变化: installed=\(installed ? 1 : 0)")
            }
            lastKnownInstalled = installed
            if isEnabled, !isComplete {
                assignVerified(false, reason: .configurationDamaged)
            }
            readErrorMessage = nil
        } catch {
            // 只有 I/O 失败和 JSON 格式错误会走到这里, 它们对「Hook 装没装」不提供信息
            // 文件不存在或配置里没有 CodexBar 都由 readConfigIfPresent 正常返回
            // 因此保留上次已知值, 不能把读取失败当成用户关闭了 Hook
            let details = LogFields.joined(
                "detail=\(error.localizedDescription)",
                "action=keepLastKnown"
            )
            AppLog.hooks.error("Hook 读取失败: \(details, privacy: .public)")
            readErrorMessage = String(localized: "hook.error.config-read-failed")
        }
    }

    func setEnabled(_ enabled: Bool) {
        AppLog.hooks.notice("Hook 开关变更: enabled=\(enabled ? 1 : 0)")
        runLatestUpdate(showProgress: true) { settings, generation in
            await settings.applyEnabled(enabled, generation: generation)
        }
    }

    func reconcileInstalledHooks() {
        refreshInstallationState()
        guard isEnabled, !isUpdating else {
            return
        }

        runLatestUpdate(showProgress: false) { settings, generation in
            await settings.reconcileInstalledHooks(generation: generation)
        }
    }

    // MARK: - 更新流程与并发控制

    private func applyEnabled(_ enabled: Bool, generation: Int) async {
        do {
            if enabled {
                try await ensureCodexHookVersionSupported()
                try ensureCurrentUpdate(generation)
                try await ensureCodexHooksGloballyEnabled()
                try ensureCurrentUpdate(generation)
                try writeCodexBarHookConfig(enabled: true)
                try ensureCurrentUpdate(generation)
                isEnabled = true
                await verifyInstalledHooksWithAppServer(generation: generation)
            } else {
                try await disableCodexBarHooks(generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            handleApplyError(error, generation: generation)
        }
    }

    /// 与手动关闭共用同一事务, 自动关闭也不会遗留另一套清理语义
    private func disableCodexBarHooks(generation: Int) async throws {
        // 关闭前先通过 hooks/list 拿到 key
        // hooks.json 删除后 app-server 就无法再反查这些 key
        let cleanupPlan = try await hookTrustCleanupPlan(generation: generation)
        try writeCodexBarHookConfig(enabled: false)
        try ensureCurrentUpdate(generation)
        isEnabled = false
        await cleanupCodexHookTrust(
            removing: cleanupPlan.keys,
            discoveryError: cleanupPlan.discoveryError,
            generation: generation
        )
    }

    private func reconcileInstalledHooks(generation: Int) async {
        do {
            try await ensureCodexHookVersionSupported()
            try ensureCurrentUpdate(generation)
        } catch is CancellationError {
            return
        } catch let error as HookConfigError {
            guard case .unsupportedCodexVersion = error else {
                handleVerificationError(error, generation: generation)
                return
            }

            await disableUnsupportedCodexBarHooks(error: error, generation: generation)
            return
        } catch {
            handleVerificationError(error, generation: generation)
            return
        }

        do {
            // 全局开关关闭时不写用户文件, 等 Codex 恢复后再补齐
            let globallyDisabled = try await readGlobalHookDisabled()
            try ensureCurrentUpdate(generation)
            guard !globallyDisabled else {
                assignVerified(false, reason: .globallyDisabled)
                operationErrorMessage = HookConfigError.hooksGloballyDisabled.localizedDescription
                return
            }

            try reconcileCodexBarHookConfig()
            try ensureCurrentUpdate(generation)

            try await validateInstalledHooksWithAppServer()
            try ensureCurrentUpdate(generation)
            assignVerified(true, reason: .verified)
            operationErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            handleVerificationError(error, generation: generation)
        }
    }

    private func disableUnsupportedCodexBarHooks(error: HookConfigError, generation: Int) async {
        assignVerified(false, reason: .unsupportedVersion)

        do {
            try await disableCodexBarHooks(generation: generation)
            try ensureCurrentUpdate(generation)
            if operationErrorMessage == nil {
                operationErrorMessage = error.localizedDescription
            }
            AppLog.hooks.notice("Hook 已自动关闭: reason=unsupportedVersion")
        } catch is CancellationError {
            return
        } catch {
            handleApplyError(error, generation: generation)
        }
    }

    private func verifyInstalledHooksWithAppServer(generation: Int) async {
        do {
            try await ensureCodexHookVersionSupported()
            try ensureCurrentUpdate(generation)

            // 全局开关排在 hooks/list 之前: 它一关, 列表里必然找不到我们的 handler,
            // 那时报"已不完整"会把用户引去翻本来就完好的 hooks.json
            let globallyDisabled = try await readGlobalHookDisabled()
            try ensureCurrentUpdate(generation)
            guard !globallyDisabled else {
                assignVerified(false, reason: .globallyDisabled)
                operationErrorMessage = HookConfigError.hooksGloballyDisabled.localizedDescription
                return
            }

            try await validateInstalledHooksWithAppServer()
            try ensureCurrentUpdate(generation)
            assignVerified(true, reason: .verified)
            operationErrorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            handleVerificationError(error, generation: generation)
        }
    }

    private func handleVerificationError(_ error: Error, generation: Int) {
        guard updateCoordinator.canCommit(generation) else {
            return
        }

        if let error = error as? HookConfigError {
            // HookConfigError 是明确结论: Codex 答复了, 只是答复说这条链路不通
            assignVerified(false, reason: .validationFailed)
            operationErrorMessage = error.localizedDescription
        } else {
            // 这一支是"验不了"而不是"确认不通", isVerified 保留上次的值
            operationErrorMessage = String(
                localized: "hook.error.verification-failed",
                defaultValue: "\(error.localizedDescription)"
            )
        }
    }

    /// @Published 在 willSet 无条件发信号, 而每次 App 激活都会跑一次校验
    /// 同值赋值会让设置页与两个子面板反复空转, 所以走这里
    /// reason 是排查依据: 用户只会说"防睡眠灰了", 那时得能从日志看出是全局禁用还是校验没过
    /// "验不了"那一支不调这里, 结论保持不变也就不该记一条变化
    private func assignVerified(_ verified: Bool, reason: HookVerificationReason) {
        guard isVerified != verified else {
            return
        }

        let details = LogFields.joined(
            "verified=\(verified ? 1 : 0)",
            "reason=\(reason.rawValue)"
        )
        AppLog.hooks.notice("Hook 链路校验结论变化: \(details, privacy: .public)")
        isVerified = verified
    }

    private func runLatestUpdate(
        showProgress: Bool,
        _ operation: @escaping @MainActor @Sendable (CodexHookSettings, Int) async -> Void
    ) {
        if showProgress {
            isUpdating = true
            operationErrorMessage = nil
        }

        updateCoordinator.start { [weak self] generation in
            guard let self else {
                return
            }

            await operation(self, generation)
            updateCoordinator.finish(generation) {
                if showProgress {
                    isUpdating = false
                }
            }
        }
    }

    private func ensureCurrentUpdate(_ generation: Int) throws {
        try Task.checkCancellation()

        guard updateCoordinator.canCommit(generation) else {
            throw CancellationError()
        }
    }

    private func handleApplyError(_ error: Error, generation: Int) {
        guard updateCoordinator.canCommit(generation) else {
            return
        }

        if let hookError = error as? HookConfigError,
           hookError.isPreflightFailure {
            // 前置检查拦下是预期内的拒绝, 配置一个字没动, 不是故障
            AppLog.hooks.notice(
                "Hook 前置检查未通过: detail=\(hookError.localizedDescription, privacy: .public)"
            )
            isEnabled = false
            operationErrorMessage = hookError.localizedDescription
        } else {
            AppLog.hooks.error(
                "Hook 写入失败: detail=\(error.localizedDescription, privacy: .public)"
            )
            refreshInstallationState()
            operationErrorMessage = String(localized: "hook.error.configuration-failed")
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
    }

    /// Hook 链路校验结论的变化理由, 只用于日志的 reason= 取值
    enum HookVerificationReason: String {
        case configurationDamaged
        case globallyDisabled
        case unsupportedVersion
        case validationFailed
        case verified
    }

    enum HookConfigError: LocalizedError {
        case invalidFormat
        case configurationFailed
        case hooksGloballyDisabled
        case codexVersionUnavailable(minimum: String)
        case unsupportedCodexVersion(minimum: String)
        case hookValidationFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat:
                String(localized: "hook.error.invalid-config-format")
            case .configurationFailed:
                String(localized: "hook.error.configuration-failed")
            case .hooksGloballyDisabled:
                String(localized: "hook.status.disabled-by-codex")
            case let .codexVersionUnavailable(minimum):
                String(
                    localized: "codex-hook.version.unavailable",
                    defaultValue: "\(minimum)"
                )
            case let .unsupportedCodexVersion(minimum):
                String(
                    localized: "codex-hook.version.unsupported",
                    defaultValue: "\(minimum)"
                )
            case let .hookValidationFailed(message):
                message
            }
        }

        var isPreflightFailure: Bool {
            switch self {
            case .hooksGloballyDisabled, .codexVersionUnavailable, .unsupportedCodexVersion:
                true
            case .invalidFormat, .configurationFailed, .hookValidationFailed:
                false
            }
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

    /// Codex 的 config.toml 里 features.hooks 是不是关着
    /// 开关流程与校验流程共用这一处读取, 两边对"全局禁用"的判断不会分叉
    func readGlobalHookDisabled() async throws -> Bool {
        try await codexStatusService.readCodexConfig().hooksGloballyDisabled
    }

    func ensureCodexHooksGloballyEnabled() async throws {
        if try await readGlobalHookDisabled() {
            throw HookConfigError.hooksGloballyDisabled
        }
    }

    /// 检查实际用于 hooks/list 的 app-server 握手版本
    /// 不能只看磁盘版本, 否则升级后尚未重连的旧进程会被误判为可用
    func ensureCodexHookVersionSupported() async throws {
        let minimumVersion = CodexCLIMinimumVersion.hook
        let connectionInfo = try await codexStatusService.readyConnectionInfo()
        guard let currentVersion = connectionInfo.version,
              let isSupported = CodexCLIVersionReader.isVersion(
                  currentVersion,
                  atLeast: minimumVersion
              ) else {
            throw HookConfigError.codexVersionUnavailable(minimum: minimumVersion)
        }

        guard isSupported else {
            let details = LogFields.joined(
                "current=\(currentVersion)",
                "minimum=\(minimumVersion)"
            )
            AppLog.hooks.notice("Hook 版本不支持: \(details, privacy: .public)")
            throw HookConfigError.unsupportedCodexVersion(minimum: minimumVersion)
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
            do {
                try await trustCodexBarHooks(entries)
            } catch {
                AppLog.hooks.error(
                    "Hook 信任自愈失败: detail=\(error.localizedDescription, privacy: .public)"
                )
                throw HookConfigError.hookValidationFailed(
                    String(localized: "hook.status.untrusted")
                )
            }
            AppLog.hooks.notice("Hook 信任状态已自愈: keys=\(entries.count)")
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

    func hookTrustCleanupPlan(generation: Int) async throws -> CodexHookTrustCleanupPlan {
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

    // MARK: - hooks.json 读写

    func writeCodexBarHookConfig(enabled: Bool) throws {
        var config = try readConfigIfPresent()
        try Self.removeCodexBarHooks(
            from: &config,
            executablePath: currentExecutablePath
        )

        if enabled {
            _ = try Self.reconcileCodexBarHooks(
                in: &config,
                executablePath: currentExecutablePath
            )
        }

        try write(config)
        // 改的是用户自己的 ~/.codex/hooks.json, 每次写入都要留痕
        AppLog.hooks.notice("Hook 配置已写入: enabled=\(enabled ? 1 : 0)")
    }

    func reconcileCodexBarHookConfig() throws {
        var config = try readConfigIfPresent()
        let repairedEvents = try Self.reconcileCodexBarHooks(
            in: &config,
            executablePath: currentExecutablePath
        )
        guard !repairedEvents.isEmpty else {
            return
        }

        do {
            try write(config)
        } catch {
            AppLog.hooks.error(
                "Hook 补齐写入失败: detail=\(error.localizedDescription, privacy: .public)"
            )
            throw HookConfigError.configurationFailed
        }
        let events = repairedEvents.map(\.rawValue).joined(separator: ",")
        let details = LogFields.joined(
            "count=\(repairedEvents.count)",
            "events=\(events)"
        )
        AppLog.hooks.notice("Hook 配置已自愈: \(details, privacy: .public)")
    }

    func codexBarHookTrustKeysFromAppServer() async throws -> Set<String> {
        let response = try await codexStatusService.listCodexHooks(cwds: [hooksListWorkingDirectory])
        return Self.codexBarHookTrustKeys(
            from: response,
            executablePath: currentExecutablePath,
            hooksURL: hooksURL
        )
    }

    // MARK: - Hook 信任状态

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
                AppLog.hooks.notice("Hook 信任状态已清理: keys=\(keys.count)")
            }

            if let discoveryError {
                let details = LogFields.joined(
                    "stage=discovery",
                    "detail=\(discoveryError.localizedDescription)"
                )
                AppLog.hooks.error("Hook 信任清理失败: \(details, privacy: .public)")
                operationErrorMessage = String(localized: "hook.error.trust-cleanup-failed")
            } else {
                operationErrorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard updateCoordinator.canCommit(generation) else {
                return
            }

            let details = LogFields.joined(
                "stage=remove",
                "detail=\(error.localizedDescription)"
            )
            AppLog.hooks.error("Hook 信任清理失败: \(details, privacy: .public)")
            operationErrorMessage = String(localized: "hook.error.trust-cleanup-failed")
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

    static func containsAllCodexBarHooks(in config: JSONObject, executablePath: String) -> Bool {
        guard let hooks = config[hooksKey] as? JSONObject else {
            return false
        }

        return CodexHookEvent.allCases.allSatisfy { event in
            guard let groups = hooks[event.configName] as? JSONArray else {
                return false
            }

            return isCanonicalCodexBarEvent(
                groups,
                event: event,
                executablePath: executablePath
            )
        }
    }

    static func reconcileCodexBarHooks(
        in config: inout JSONObject,
        executablePath: String
    ) throws -> [CodexHookEvent] {
        var hooks = try hooksObject(from: config)
        var repairedEvents: [CodexHookEvent] = []

        // 每个事件只保留一个标准独立 group, 不和用户已有 group 混写
        for event in CodexHookEvent.allCases {
            var groups = try eventGroups(named: event.configName, from: hooks)
            guard !isCanonicalCodexBarEvent(
                groups,
                event: event,
                executablePath: executablePath
            ) else {
                continue
            }

            groups = groups.compactMap {
                groupRemovingCodexBarHandlers(
                    from: $0,
                    executablePath: executablePath
                )
            }
            groups.append([
                hooksKey: [codexBarHookHandler(for: event, executablePath: executablePath)]
            ])
            hooks[event.configName] = groups
            repairedEvents.append(event)
        }

        config[hooksKey] = hooks
        return repairedEvents
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
        // 结构异常的同级条目一律跳过: 只负责移除自己的 handler, 不校验整个文件
        // 在这里抛错会让开关既关不掉又被 refresh() 翻回打开, 用户无法从 UI 脱困
        for (event, value) in hooks {
            guard let groups = value as? JSONArray else {
                continue
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
            return String(localized: "codex-status.result.empty")
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
            return String(localized: "codex-status.result.error")
        }
        if hasDisabledHook {
            return String(localized: "hook.status.disabled")
        }
        if hasUntrustedHook {
            return String(localized: "hook.status.untrusted")
        }
        if hasMissingEvent {
            return String(localized: "hook.status.incomplete")
        }
        if hasUnexpectedSource {
            return String(localized: "hook.status.unexpected-source")
        }
        if !warnings.isEmpty {
            return String(localized: "codex-status.result.warning")
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

    static func isCanonicalCodexBarEvent(
        _ groups: JSONArray,
        event: CodexHookEvent,
        executablePath: String
    ) -> Bool {
        let managedHandlerCount = groups.reduce(into: 0) { count, group in
            count += handlers(from: group)?.count(where: {
                isCurrentCodexBarHandler($0, executablePath: executablePath)
            }) ?? 0
        }
        guard managedHandlerCount == 1 else {
            return false
        }

        return groups.contains {
            isCanonicalCodexBarGroup(
                $0,
                event: event,
                executablePath: executablePath
            )
        }
    }

    static func isCanonicalCodexBarGroup(
        _ group: Any,
        event: CodexHookEvent,
        executablePath: String
    ) -> Bool {
        guard let group = group as? JSONObject,
              group.count == 1,
              let handlers = handlers(from: group),
              handlers.count == 1,
              let handler = handlers.first as? JSONObject,
              handler.count == 3,
              handler[hookTypeKey] as? String == hookCommandType,
              handler[hookCommandKey] as? String == hookCommand(executablePath: executablePath),
              let timeout = handler[hookTimeoutKey] as? NSNumber else {
            return false
        }

        return timeout.doubleValue == Double(
            WorkflowHookEventRecorder.hookTimeoutSeconds(for: event)
        )
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

    /// 管理项身份只由当前可执行路径和 --hook-event 确定
    /// type 本身可能损坏, 不能用它决定是否允许自愈或清理
    static func isCurrentCodexBarHandler(
        _ handler: Any,
        executablePath: String
    ) -> Bool {
        guard let handler = handler as? JSONObject,
              let command = handler[hookCommandKey] as? String else {
            return false
        }

        return isCodexBarCommand(command, executablePath: executablePath)
    }

    static func codexBarHookHandler(
        for event: CodexHookEvent,
        executablePath: String
    ) -> JSONObject {
        [
            hookTypeKey: hookCommandType,
            hookCommandKey: hookCommand(executablePath: executablePath),
            hookTimeoutKey: WorkflowHookEventRecorder.hookTimeoutSeconds(for: event)
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
