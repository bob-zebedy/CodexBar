import Combine
import Foundation
import os

/// CodexBar 每次启动后, 首次连上 daemon 时应用已保存的 Codex Desktop 启动设置
/// 打开设置窗口时只核对当前登录会话的环境变量
@MainActor
final class CodexDesktopLaunchSettings: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var isEnabled: Bool
    @Published private(set) var isUpdating = false
    @Published private(set) var hasMismatch = false
    @Published private var failure: Failure?

    var updateFailed: Bool {
        failure != nil
    }

    var canRestore: Bool {
        hasMismatch || (isEnabled && failure == .connection)
    }

    private enum Operation: Equatable {
        case read
        case change(Bool)
    }

    private enum Failure: Equatable {
        case connection
        case environment(Operation)
    }

    typealias LaunchctlCommand = (String, String, String?) async throws -> String?

    private let codexHome: URL
    private let defaults: UserDefaults
    private let isDesktopInstalled: () async -> Bool
    private let launchctl: LaunchctlCommand
    private let addressKey = "CODEX_APP_SERVER_WS_URL"
    private let forceCLIKey = "CODEX_APP_SERVER_FORCE_CLI"
    private let daemonForceCLIValue = "0"
    private static let enabledKey = "CodexDesktopDaemon.isEnabled"
    private var processingTask: Task<Void, Never>?
    private var pendingOperation: Operation?
    private var isPreparingForTermination = false
    private var appliesSavedPreferenceOnResume = false

    init(
        codexHome: URL = CodexPaths.codexHomeDirectory(),
        defaults: UserDefaults = .standard,
        isDesktopInstalled: @escaping () async -> Bool = desktopAppIsInstalled,
        launchctl: @escaping LaunchctlCommand = runLaunchctl
    ) {
        self.codexHome = codexHome
        self.defaults = defaults
        self.isDesktopInstalled = isDesktopInstalled
        self.launchctl = launchctl
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func refresh() {
        enqueue(.read)
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        enqueue(.change(enabled))
    }

    func restore() {
        guard canRestore else { return }
        enqueue(.change(isEnabled))
    }

    func applySavedPreference() {
        // 首次连接回调只触发一次, 退出被取消时仍需应用当时延后的偏好
        if isPreparingForTermination {
            appliesSavedPreferenceOnResume = true
            return
        }
        enqueue(.change(isEnabled))
    }

    func prepareForTermination() async {
        isPreparingForTermination = true
        await processingTask?.value
    }

    func resumeAfterTerminationCancellation() {
        isPreparingForTermination = false
        if appliesSavedPreferenceOnResume {
            appliesSavedPreferenceOnResume = false
            applySavedPreference()
        }
    }

    private func enqueue(_ operation: Operation) {
        guard !isPreparingForTermination else { return }
        switch operation {
        case .read:
            guard pendingOperation == nil else { return }
        case .change:
            guard !isUpdating else { return }
            isUpdating = true
        }
        pendingOperation = operation
        guard processingTask == nil else { return }
        processingTask = Task {
            while let operation = pendingOperation {
                pendingOperation = nil
                await update(operation)
            }
            processingTask = nil
            if isUpdating {
                isUpdating = false
            }
        }
    }

    private func update(_ operation: Operation) async {
        let installed = await isDesktopInstalled()
        if isInstalled != installed {
            isInstalled = installed
        }
        guard installed else {
            hasMismatch = false
            failure = nil
            return
        }

        switch operation {
        case .read: await refreshEnvironment()
        case let .change(enabled): await applyPreference(enabled)
        }
    }

    @concurrent
    private static func desktopAppIsInstalled() async -> Bool {
        CodexPaths.desktopApplication() != nil
    }

    private func refreshEnvironment() async {
        let needsAddress = isEnabled || failure == .environment(.change(true))
        let daemonAddress = needsAddress ? await CodexDesktopDaemonEndpoint.resolve(in: codexHome)?.address : nil
        let environment: LaunchEnvironment
        do {
            environment = try await readEnvironment(for: isEnabled)
        } catch {
            hasMismatch = false
            if failure == nil {
                AppLog.settings.error("无法读取 Codex Desktop 的启动设置: \(String(describing: error), privacy: .public)")
                failure = .environment(.read)
            }
            return
        }
        hasMismatch = !matchesPreference(environment, enabled: isEnabled, daemonAddress: daemonAddress)
        // 环境变量匹配只能确认读写结果, 连接失败需要重新握手确认
        guard case let .environment(failedOperation) = failure else { return }
        switch failedOperation {
        case .read: failure = nil
        case .change(true) where !isEnabled:
            // 关闭状态只看地址, 这里核对 FORCE_CLI 是为了判断能否清除上次开启失败的提示
            guard let daemonAddress, environment.address == daemonAddress else { return }
            let forceCLI = try? await launchctl("getenv", forceCLIKey, nil)
            if forceCLI == daemonForceCLIValue {
                failure = nil
            }
        case let .change(target) where matchesPreference(environment, enabled: target, daemonAddress: daemonAddress): failure = nil
        default: break
        }
    }

    private func applyPreference(_ enabled: Bool) async {
        let daemonAddress: String?
        if enabled {
            do {
                guard let endpoint = await CodexDesktopDaemonEndpoint.resolve(in: codexHome) else { throw LaunchctlError.verificationFailed }
                try await endpoint.verifyConnection()
                daemonAddress = endpoint.address
            } catch {
                failure = .connection
                AppLog.settings.error("无法验证 Codex Desktop 的后台服务地址: \(String(describing: error), privacy: .public)")
                return
            }
        } else {
            daemonAddress = nil
        }

        do {
            try await applyEnvironment(daemonAddress: daemonAddress)
            failure = nil
        } catch {
            AppLog.settings.error("无法应用 Codex Desktop 的启动设置: \(String(describing: error), privacy: .public)")
            failure = .environment(.change(enabled))
            // 回读属于已接受的写入, 即使正在退出也要执行
            pendingOperation = .read
        }
    }

    private func applyEnvironment(daemonAddress: String?) async throws {
        let enabled = daemonAddress != nil
        let environment = try await readEnvironment(for: enabled)
        let needsWrite = !matchesPreference(environment, enabled: enabled, daemonAddress: daemonAddress)
        if needsWrite {
            if let daemonAddress {
                try await ensureDaemonEnvironment(environment, socketAddress: daemonAddress)
            } else {
                _ = try await launchctl("unsetenv", addressKey, nil)
            }
        }
        // 先保存用户的选择, 即使回读失败, 下次启动也会按这个选择设置环境变量
        if enabled != isEnabled {
            defaults.set(enabled, forKey: Self.enabledKey)
            isEnabled = enabled
            AppLog.settings.notice("Codex Desktop 后台服务开关变更: enabled=\(enabled ? 1 : 0)")
        }
        hasMismatch = false
        if needsWrite {
            let actual = try await readEnvironment(for: enabled)
            hasMismatch = !matchesPreference(actual, enabled: enabled, daemonAddress: daemonAddress)
            guard !hasMismatch else { throw LaunchctlError.verificationFailed }
        }
    }

    private typealias LaunchEnvironment = (address: String?, forceCLI: String?)

    private func matchesPreference(_ environment: LaunchEnvironment, enabled: Bool, daemonAddress: String?) -> Bool {
        guard enabled else { return environment.address == nil }
        guard let daemonAddress else { return false }
        return environment.address == daemonAddress && environment.forceCLI == daemonForceCLIValue
    }

    private func readEnvironment(for enabled: Bool) async throws -> LaunchEnvironment {
        let address = try await launchctl("getenv", addressKey, nil)
        guard enabled else { return (address, nil) }
        let forceCLI = try await launchctl("getenv", forceCLIKey, nil)
        return (address, forceCLI)
    }

    private func ensureDaemonEnvironment(_ environment: LaunchEnvironment, socketAddress: String) async throws {
        if environment.address != socketAddress {
            _ = try await launchctl("setenv", addressKey, socketAddress)
        }
        if environment.forceCLI != daemonForceCLIValue {
            do {
                _ = try await launchctl("setenv", forceCLIKey, daemonForceCLIValue)
            } catch {
                // 只撤回本次写入的地址, 保留期间由其他程序设置的地址
                if environment.address != socketAddress, try await launchctl("getenv", addressKey, nil) == socketAddress {
                    _ = try await launchctl(environment.address == nil ? "unsetenv" : "setenv", addressKey, environment.address)
                }
                throw error
            }
        }
    }

    private static func runLaunchctl(_ operation: String, _ key: String, _ value: String?) async throws -> String? {
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: [operation, key, value].compactMap(\.self),
            configuration: .init(outputMode: .separate)
        )
        guard result.exitCode == 0, !result.standardOutput.isTruncated,
              let output = String(data: result.standardOutput.data, encoding: .utf8) else {
            throw LaunchctlError.commandFailed(operation: operation, key: key, code: result.exitCode)
        }
        guard !output.isEmpty else { return nil }
        return output.hasSuffix("\n") ? String(output.dropLast()) : output
    }

    private enum LaunchctlError: Error {
        case commandFailed(operation: String, key: String, code: Int32)
        case verificationFailed
    }
}

private nonisolated struct CodexDesktopDaemonEndpoint {
    private static let rpcPath: StaticString = "/rpc"
    let socketURL: URL

    var address: String {
        "ws+unix://localhost\(socketURL.path):\(Self.rpcPath)"
    }

    @concurrent
    static func resolve(in home: URL) async -> Self? {
        // 用配置目录的 /.vol 路径避开特殊字符, daemon 重建下级目录或 socket 后仍能使用同一地址
        guard let reference = try? CodexPaths.socketDirectoryReference(home) else { return nil }
        return Self(socketURL: CodexPaths.appServerSocket(in: reference))
    }

    @concurrent
    func verifyConnection() async throws {
        let session = try AppServerSession(socketURL: socketURL, handshakePath: Self.rpcPath, logStorage: nil)
        session.close()
    }
}
