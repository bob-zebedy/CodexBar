import Foundation

// UI 只关心可展示数据、未登录、初始化失败; 更细的错误保留在交互日志中
nonisolated enum CodexFetchOutcome {
    case data(CodexQuotaSnapshot)
    case notLoggedIn
    case initializationFailed
}

private enum ConnectionResolution {
    case ready(connection: AppServerConnection, reused: Bool)
    case notLoggedIn
    case initializationFailed
}

// 单接口读取结果按后续动作分类: 跳过、刷新认证、重建连接
private enum ReadResult<Value> {
    case value(Value)
    case skipped(ReadSkipReason)
    case authRequired
    case broken
}

private enum ReadSkipReason {
    case requestFailed
    case methodUnsupported
}

private enum FetchFailure: Error {
    case notLoggedIn
    case needsRebuild
}

nonisolated private struct CachedSupplementalRead<Value> {
    let value: Value?
    let isStale: Bool
}

nonisolated private struct SupplementalDataCache {
    var account: CodexAccount?
    var rateLimits: AccountRateLimitsResponse?
    var usage: AccountUsageResponse?

    mutating func useAccount(_ account: CodexAccount) {
        guard self.account != account else { return }
        self = Self(account: account)
    }
}

nonisolated private extension ReadResult {
    var isAuthenticationRequired: Bool {
        if case .authRequired = self {
            return true
        }
        return false
    }

    var value: Value? {
        if case .value(let value) = self {
            return value
        }
        return nil
    }

    // 认证刷新后仍是 authRequired/broken 则上抛, 其余原样返回交给调用方按缓存策略处理
    func resultAfterAuthAttempt() throws -> ReadResult<Value> {
        switch self {
        case .value, .skipped:
            return self
        case .authRequired:
            throw FetchFailure.notLoggedIn
        case .broken:
            throw FetchFailure.needsRebuild
        }
    }
}

// 维持一条 codex app-server stdio 会话, 复用失败后按需重建
nonisolated final class CodexStatusService: @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 20
    // 定期回收连接, 让后台升级后的 codex 二进制有机会生效
    private static let connectionMaxAge: TimeInterval = 1 * 60 * 60
    private static let environment = CodexCLIResolver.environment

    // connection 只在这个队列上访问
    private let queue = DispatchQueue(label: "CodexBar.app-server", qos: .utility)
    private var connection: AppServerConnection?
    private var supplementalDataCache = SupplementalDataCache()

    // app-server 退出后继续写管道会触发 SIGPIPE; 忽略信号, 让 write 抛错后走重建
    private static let ignoreBrokenPipeSignal: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    init() {
        _ = Self.ignoreBrokenPipeSignal
    }

    deinit {
        connection?.session.close()
    }

    func fetchOutcome() async -> CodexFetchOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.resolveOutcomeOnQueue(allowRebuild: true))
            }
        }
    }

    func currentConnectionInfo() async -> CodexCLIConnectionInfo? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.currentConnectionInfoOnQueue())
            }
        }
    }

    // 复用连接出现传输故障时只重建重试一次, 避免故障状态下反复拉起进程
    private func resolveOutcomeOnQueue(allowRebuild: Bool) -> CodexFetchOutcome {
        switch ensureConnection() {
        case .notLoggedIn:
            return .notLoggedIn
        case .initializationFailed:
            return .initializationFailed
        case .ready(let connection, let reused):
            do {
                let snapshot = try fetchData(using: connection, refreshAccountInfo: reused)
                return .data(snapshot)
            } catch FetchFailure.notLoggedIn {
                supplementalDataCache = SupplementalDataCache()
                teardownConnection()
                return .notLoggedIn
            } catch FetchFailure.needsRebuild {
                teardownConnection()
                if reused && allowRebuild {
                    return resolveOutcomeOnQueue(allowRebuild: false)
                }
                return .initializationFailed
            } catch {
                teardownConnection()
                return .initializationFailed
            }
        }
    }

    private func ensureConnection() -> ConnectionResolution {
        if let connection, connection.session.process.isRunning,
           Date().timeIntervalSince(connection.openedAt) < Self.connectionMaxAge {
            return .ready(connection: connection, reused: true)
        }

        teardownConnection()

        let command: AppServerCommand
        do {
            command = try CodexCLIResolver.resolveAppServerCommand(environment: Self.environment)
        } catch {
            RequestLogStore.shared.recordFailure(message: error.localizedDescription)
            return .initializationFailed
        }

        let resolution = Self.openConnection(
            command: command,
            environment: Self.environment,
            clientVersion: Self.clientVersion(),
            timeout: Self.requestTimeout
        )
        if case .ready(let newConnection, _) = resolution {
            connection = newConnection
        }
        return resolution
    }

    private func teardownConnection() {
        connection?.session.close()
        connection = nil
    }

    private func currentConnectionInfoOnQueue() -> CodexCLIConnectionInfo? {
        guard let connection, connection.session.process.isRunning else {
            return nil
        }

        return connection.commandInfo
    }

    // 额度与用量独立读取; 认证失败全程只刷新一次 token, 传输故障交给外层重建连接
    private func fetchData(using connection: AppServerConnection, refreshAccountInfo: Bool) throws -> CodexQuotaSnapshot {
        var didRefresh = false

        func refreshTokenIfNeeded() throws {
            guard !didRefresh else { throw FetchFailure.notLoggedIn }
            didRefresh = true
            try Self.refreshAccount(using: connection)
        }

        func readResultWithAuthRefresh<Value>(_ read: () -> ReadResult<Value>) throws -> ReadResult<Value> {
            let firstAttempt = read()
            guard firstAttempt.isAuthenticationRequired else {
                return try firstAttempt.resultAfterAuthAttempt()
            }

            try refreshTokenIfNeeded()
            return try read().resultAfterAuthAttempt()
        }

        func readSupplemental<Value: Decodable>(
            _ method: String,
            as type: Value.Type,
            cache: inout Value?
        ) throws -> CachedSupplementalRead<Value> {
            try cachedRead(
                readResultWithAuthRefresh {
                    Self.read(method, using: connection, as: type)
                },
                cache: &cache
            )
        }

        // 新建连接已读过 account; 复用连接才刷新账户状态
        if refreshAccountInfo {
            let accountResult: ReadResult<AccountReadResponse> = try readResultWithAuthRefresh {
                Self.read("account/read", params: ["refreshToken": false], using: connection, as: AccountReadResponse.self)
            }
            if let response = accountResult.value {
                guard response.account != nil else { throw FetchFailure.notLoggedIn }
                connection.accountResponse = response
            }
        }

        guard let account = connection.accountResponse.account else {
            throw FetchFailure.notLoggedIn
        }

        supplementalDataCache.useAccount(account)

        let rateLimitsRead = try readSupplemental(
            "account/rateLimits/read",
            as: AccountRateLimitsResponse.self,
            cache: &supplementalDataCache.rateLimits
        )

        let usageRead = try readSupplemental(
            "account/usage/read",
            as: AccountUsageResponse.self,
            cache: &supplementalDataCache.usage
        )

        // rateLimits/usage 都可为空, 只要账户有效就让 UI 展示"暂无数据"
        guard let snapshot = try? CodexQuotaSnapshot(
            accountResponse: connection.accountResponse,
            rateLimitsResponse: rateLimitsRead.value,
            usageResponse: usageRead.value,
            isRateLimitsStale: rateLimitsRead.isStale,
            isUsageStale: usageRead.isStale
        ) else {
            throw FetchFailure.notLoggedIn
        }

        return snapshot
    }

    // 新值更新缓存; 本轮请求失败则回退到缓存并标记陈旧; 方法不支持/认证/断连一律视为无数据
    private func cachedRead<Value>(
        _ result: ReadResult<Value>,
        cache: inout Value?
    ) -> CachedSupplementalRead<Value> {
        switch result {
        case .value(let value):
            cache = value
            return CachedSupplementalRead(value: value, isStale: false)
        case .skipped(.requestFailed):
            return CachedSupplementalRead(value: cache, isStale: cache != nil)
        default:
            return CachedSupplementalRead(value: nil, isStale: false)
        }
    }

    private static func read<Value: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        using connection: AppServerConnection,
        as type: Value.Type
    ) -> ReadResult<Value> {
        do {
            return .value(try connection.session.request(method, params: params, as: type))
        } catch let error as CodexStatusError {
            return classify(error)
        } catch {
            return .broken
        }
    }

    private static func classify<Value>(_ error: CodexStatusError) -> ReadResult<Value> {
        if error.isAuthenticationRequired {
            return .authRequired
        }
        if error.isUnsupportedMethod {
            return .skipped(.methodUnsupported)
        }
        // 重试后仍失败的非认证业务错误不阻断整轮刷新
        return error.isTransportFailure ? .broken : .skipped(.requestFailed)
    }

    private static func refreshAccount(using connection: AppServerConnection) throws {
        let response: AccountReadResponse
        do {
            response = try connection.session.request(
                "account/read",
                params: ["refreshToken": true],
                as: AccountReadResponse.self
            )
        } catch let error as CodexStatusError {
            throw error.isTransportFailure ? FetchFailure.needsRebuild : FetchFailure.notLoggedIn
        } catch {
            throw FetchFailure.needsRebuild
        }

        connection.accountResponse = response
        if response.account == nil {
            throw FetchFailure.notLoggedIn
        }
    }

    // 初始化失败与未登录在这里分流; 两者都不复用本次新建的进程
    private static func openConnection(
        command: AppServerCommand,
        environment: [String: String],
        clientVersion: String,
        timeout: TimeInterval
    ) -> ConnectionResolution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = environment

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let lineReader = JSONLineReader(fileHandle: standardOutput.fileHandleForReading)
        let errorReader = PipeDrain(fileHandle: standardError.fileHandleForReading)

        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            RequestLogStore.shared.recordFailure(message: "app-server 启动失败: \(error.localizedDescription)")
            return .initializationFailed
        }
        let openedAt = Date()

        let session = AppServerSession(
            process: process,
            input: standardInput,
            lineReader: lineReader,
            errorReader: errorReader,
            timeout: timeout
        )

        do {
            let initializeResult = try session.request(
                "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_bar",
                        "title": "Codex Bar",
                        "version": clientVersion
                    ]
                ],
                as: InitializeResult.self
            )

            try session.notify("initialized")

            let accountResponse = try session.request(
                "account/read",
                params: ["refreshToken": false],
                as: AccountReadResponse.self
            )

            guard accountResponse.account != nil else {
                session.close()
                return .notLoggedIn
            }

            let commandInfo = CodexCLIConnectionInfo(
                source: command.source,
                executablePath: command.executablePath,
                version: Self.serverVersion(fromUserAgent: initializeResult.userAgent),
                openedAt: openedAt
            )

            return .ready(
                connection: AppServerConnection(
                    session: session,
                    accountResponse: accountResponse,
                    commandInfo: commandInfo
                ),
                reused: false
            )
        } catch {
            session.close()
            return .initializationFailed
        }
    }

    private nonisolated static func clientVersion() -> String {
        guard let version = Bundle.main.shortVersionString, !version.isEmpty else {
            return "1.0.0"
        }

        return version
    }

    // userAgent 形如 "codex_bar/0.139.0 (...)"; 取首个 token 中 "/" 之后的运行版本号
    private nonisolated static func serverVersion(fromUserAgent userAgent: String?) -> String? {
        guard let firstToken = userAgent?.split(separator: " ").first,
              let slashIndex = firstToken.firstIndex(of: "/") else {
            return nil
        }

        let version = firstToken[firstToken.index(after: slashIndex)...]
        return version.isEmpty ? nil : String(version)
    }
}

private nonisolated final class AppServerConnection {
    let session: AppServerSession
    let commandInfo: CodexCLIConnectionInfo
    var accountResponse: AccountReadResponse

    var openedAt: Date { commandInfo.openedAt }

    init(
        session: AppServerSession,
        accountResponse: AccountReadResponse,
        commandInfo: CodexCLIConnectionInfo
    ) {
        self.session = session
        self.accountResponse = accountResponse
        self.commandInfo = commandInfo
    }
}

private nonisolated struct InitializeResult: Decodable {
    let userAgent: String?
}
