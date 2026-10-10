import Foundation
import os

/// 启动与连接恢复共用的有界准备, 只启动明确缺失的 Codex 后台服务
actor AppServerStartup {
    private let environment: [String: String]
    private let installations: CodexInstallations?
    private let probeConnection: @Sendable () throws -> Void
    private let commandTimeout: TimeInterval
    private let readinessAttempts: Int
    enum Trigger { case automatic, manual }

    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastFailure: String?
    private var automaticAttempts = 0
    private var retryAfter: ContinuousClock.Instant?
    private var inFlight: (id: UUID, task: Task<Void, any Error>)?
    private var waiters = Set<UUID>()
    private var unfinishedProcess: Process?

    init(
        socketURL: URL = AppServerActivityReader.defaultSocketURL,
        environment: [String: String] = CodexPaths.environment,
        installations: CodexInstallations? = nil,
        commandTimeout: TimeInterval = 15,
        readinessAttempts: Int = 10,
        probeConnection: (@Sendable () throws -> Void)? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.now = now
        self.environment = environment
        self.installations = installations
        self.commandTimeout = commandTimeout
        self.readinessAttempts = max(1, readinessAttempts)
        self.probeConnection = probeConnection ?? {
            let connection = try AppServerSession(socketURL: socketURL, logStorage: nil, connectionName: "startup")
            connection.close()
        }
    }

    func ensureStarted(trigger: Trigger = .automatic) async throws {
        do {
            try await waitForAttempt(trigger: trigger)
        } catch let error as StartupError where trigger == .manual {
            switch error {
            case .retryDeferred, .retryExhausted:
                // 手动请求若赶上自动额度检查, 清理完成后仍允许独立尝试一次
                try await waitForAttempt(trigger: .manual)
            default: throw error
            }
        }
    }

    private func waitForAttempt(trigger: Trigger) async throws {
        try Task.checkCancellation()
        let operation: (id: UUID, task: Task<Void, any Error>)
        if let inFlight {
            operation = inFlight
        } else {
            operation = (UUID(), Task { try await self.startIfAbsent(trigger: trigger) })
            inFlight = operation
        }
        let waiter = UUID()
        waiters.insert(waiter)
        defer {
            if inFlight?.id == operation.id {
                inFlight = nil
                waiters.removeAll()
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await operation.task.value
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.cancelWaiter(waiter, operationID: operation.id) }
            }
        } catch {
            if inFlight?.id == operation.id {
                switch error {
                case is CancellationError, StartupError.retryDeferred, StartupError.retryExhausted: break
                default: lastFailure = error.localizedDescription
                }
            }
            throw error
        }
    }

    private func cancelWaiter(_ waiter: UUID, operationID: UUID) {
        guard inFlight?.id == operationID else { return }
        waiters.remove(waiter)
        // 一个调用方取消不影响其他等待者, 最后一个离开后才取消命令
        if waiters.isEmpty {
            inFlight?.task.cancel()
        }
    }

    private func connectionIsReady() throws {
        try probeConnection()
        automaticAttempts = 0
        retryAfter = nil
        lastFailure = nil
    }

    private func startIfAbsent(trigger: Trigger) async throws {
        try Task.checkCancellation()
        do {
            try connectionIsReady()
            return
        } catch let error as AppServerConnectionError where error.serverIsAbsent {
            // 只有明确缺少监听者才启动, 权限或协议错误不改变服务状态
        }

        guard unfinishedProcess?.isRunning != true else { throw StartupError.notReady }
        unfinishedProcess = nil
        if trigger == .automatic {
            guard automaticAttempts < 3 else { throw StartupError.retryExhausted(lastFailure ?? "") }
            guard retryAfter.map({ now() >= $0 }) ?? true else { throw StartupError.retryDeferred(lastFailure ?? "") }
            automaticAttempts += 1
        }
        retryAfter = now().advanced(by: .seconds(60))
        let executable = try await supportedExecutable()
        try Task.checkCancellation()
        // 能力检测期间其他客户端可能已经启动服务
        do {
            try connectionIsReady()
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
                try connectionIsReady()
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
        var hasSupportedVersion = false
        for path in paths where checked.insert(CodexPaths.canonicalPath(path)).inserted {
            try Task.checkCancellation()
            let executable = URL(fileURLWithPath: path)
            let version = await BoundedProcess.runAsync(
                executable: executable, arguments: ["--version"], timeout: 2.5, environment: environment
            )
            unfinishedProcess = version.runningProcess
            try Task.checkCancellation()
            guard version.runningProcess == nil else { throw StartupError.notReady }
            guard version.exitCode == 0,
                  CodexVersionReader.isVersion(version.output, atLeast: CodexVersionReader.minimumAppServerVersion) == true else { continue }
            hasSupportedVersion = true
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
        guard hasSupportedVersion else { throw CodexStatusError.unsupportedVersion(minimum: CodexVersionReader.minimumAppServerVersion) }
        throw StartupError.unsupportedCommand
    }

    nonisolated enum StartupError: LocalizedError {
        case notInstalled
        case unsupportedCommand
        case timeout
        case commandFailed(Int32)
        case notReady
        case retryDeferred(String)
        case retryExhausted(String)

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
            case let .retryDeferred(reason), let .retryExhausted(reason):
                reason
            }
        }
    }
}
