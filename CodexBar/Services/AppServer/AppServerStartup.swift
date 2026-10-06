import Foundation
import os

/// App 启动入口的一次性准备, 只请求官方启动命令, 不接管 Codex 后台服务生命周期
actor AppServerStartup {
    private let environment: [String: String]
    private let installations: CodexInstallations?
    private let probeConnection: @Sendable () throws -> Void
    private let commandTimeout: TimeInterval
    private let readinessAttempts: Int
    private var isStarting = false
    private var unfinishedProcess: Process?

    init(
        socketURL: URL = AppServerActivityReader.defaultSocketURL,
        environment: [String: String] = CodexPaths.environment,
        installations: CodexInstallations? = nil,
        commandTimeout: TimeInterval = 15,
        readinessAttempts: Int = 10,
        probeConnection: (@Sendable () throws -> Void)? = nil
    ) {
        self.environment = environment
        self.installations = installations
        self.commandTimeout = commandTimeout
        self.readinessAttempts = max(1, readinessAttempts)
        self.probeConnection = probeConnection ?? {
            let connection = try AppServerSession(socketURL: socketURL, logStorage: nil, connectionName: "startup")
            connection.close()
        }
    }

    func ensureStarted() async throws {
        try Task.checkCancellation()
        // 异步命令执行期间允许 actor 重入, 但不能重叠启动命令
        guard !isStarting, unfinishedProcess?.isRunning != true else { throw StartupError.notReady }
        unfinishedProcess = nil
        isStarting = true
        defer { isStarting = false }
        do {
            try probeConnection()
            AppLog.codex.notice("Codex 后台服务已就绪: source=existing")
            return
        } catch let error as AppServerConnectionError where error.serverIsAbsent {
            // 只有明确缺少监听者才启动, 权限或协议错误不改变服务状态
        }

        let executable = try await supportedExecutable()
        try Task.checkCancellation()
        // 能力检测期间其他客户端可能已经启动服务
        do {
            try probeConnection()
            return
        } catch let error as AppServerConnectionError where error.serverIsAbsent {}

        AppLog.codex.notice("Codex 后台服务启动请求已发送")
        let result = await BoundedProcess.runAsync(
            executable: executable,
            arguments: ["app-server", "daemon", "start"],
            timeout: commandTimeout,
            environment: environment
        )
        unfinishedProcess = result.runningProcess
        try Task.checkCancellation()
        // 命令失败也探测一次, 允许与其他客户端并发启动后复用已就绪的服务
        for attempt in 0 ..< readinessAttempts {
            do {
                try probeConnection()
                AppLog.codex.notice("Codex 后台服务已就绪: source=daemonStart")
                return
            } catch let error as AppServerConnectionError where error.serverIsAbsent {
                if result.timedOut {
                    throw StartupError.timeout
                }
                guard result.exitCode == 0 else { throw StartupError.commandFailed(result.exitCode) }
                guard attempt + 1 < readinessAttempts else { throw StartupError.notReady }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func supportedExecutable() async throws -> URL {
        let installations = installations ?? CodexPaths.resolveInstallations(environment: environment)
        let paths = [installations.globalPath, installations.bundledPath].compactMap(\.self)
        guard !paths.isEmpty else { throw StartupError.notInstalled }
        var checked = Set<String>()
        for path in paths where checked.insert(CodexPaths.canonicalPath(path)).inserted {
            try Task.checkCancellation()
            let executable = URL(fileURLWithPath: path)
            let result = await BoundedProcess.runAsync(
                executable: executable,
                arguments: ["app-server", "daemon", "start", "--help"],
                timeout: 2.5,
                environment: environment
            )
            unfinishedProcess = result.runningProcess
            try Task.checkCancellation()
            guard result.runningProcess == nil else { throw StartupError.notReady }
            if result.exitCode == 0, result.output.contains("daemon start") {
                return executable
            }
        }
        throw StartupError.unsupportedCommand
    }

    nonisolated enum StartupError: LocalizedError {
        case notInstalled
        case unsupportedCommand
        case timeout
        case commandFailed(Int32)
        case notReady

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                String(localized: "codex.daemon.not-installed")
            case .unsupportedCommand:
                String(localized: "codex.daemon.unsupported-command")
            case .timeout:
                String(localized: "codex.daemon.timeout")
            case let .commandFailed(code):
                String(localized: "codex.daemon.command-failed", defaultValue: "\(code)")
            case .notReady:
                String(localized: "codex.daemon.not-ready")
            }
        }
    }
}
