import Foundation
import os

/// 刷新结果携带连接失败原因, 请求响应细节保留在交互日志中
nonisolated enum CodexFetchOutcome {
    case data(CodexQuotaSnapshot)
    case notLoggedIn
    case unsupportedVersion(minimum: String)
    case initializationFailed(message: String)

    var connectionErrorMessage: String? {
        switch self {
        case .data: nil
        case .notLoggedIn: CodexStatusError.notLoggedIn.localizedDescription
        case let .unsupportedVersion(minimum): CodexStatusError.unsupportedVersion(minimum: minimum).localizedDescription
        case let .initializationFailed(message): message
        }
    }
}

/// 一次刷新里各步的结果分类, 只用于日志
/// 成功路径压进收尾那一条, 不为每步单独记一行
nonisolated struct CodexFetchTrace {
    enum ConnectionMode: String {
        case reused
        case new
    }

    enum StepResult: String {
        case ok
        case refreshed
        case cached
        case missing
        case skipped
        case failed
    }

    /// 失败时定位到哪一步, 成功时为 nil
    enum FailureStage: String {
        case connect
        case account
        case snapshot
    }

    var connection: ConnectionMode?
    var account: StepResult?
    var rateLimits: StepResult?
    var usage: StepResult?
    var resetCredits: StepResult?
    var failureStage: FailureStage?
}

nonisolated struct CodexFetchResult {
    let outcome: CodexFetchOutcome
    let trace: CodexFetchTrace
}

private nonisolated enum ConnectionResolution {
    case ready(connection: AppServerConnection, reused: Bool)
    case notLoggedIn
    case unsupportedVersion(minimum: String)
    case initializationFailed(message: String)
}

// 单接口读取结果按后续动作分类: 跳过, 刷新认证, 重建连接
private nonisolated enum ReadResult<Value> {
    case value(Value)
    case skipped(ReadSkipReason)
    case authRequired
    case broken
}

private nonisolated enum ReadSkipReason {
    case requestFailed
    case methodUnsupported
}

private nonisolated enum FetchFailure: Error {
    case notLoggedIn
    case needsRebuild
}

private nonisolated struct CachedSupplementalRead<Value> {
    let value: Value?
    let step: CodexFetchTrace.StepResult

    /// 只驱动 UI 的半透明展示; 新增 step 分支时要确认它算不算"给出的是旧数据"
    var isStale: Bool {
        step == .cached
    }
}

/// 只缓存同一账号下的补充数据, 账号变化时整体丢弃避免串号
private nonisolated struct SupplementalDataCache {
    var account: CodexAccount?
    var rateLimits: AccountRateLimitsResponse?
    var usage: AccountUsageResponse?

    /// 返回是否因为换账号而丢弃了缓存, 调用方据此记日志, 不必再比一遍账号
    @discardableResult
    mutating func useAccount(_ account: CodexAccount) -> Bool {
        guard self.account != account else { return false }
        let hadCachedAccount = self.account != nil
        self = Self(account: account)
        return hadCachedAccount
    }
}

private nonisolated extension ReadResult {
    var isAuthenticationRequired: Bool {
        if case .authRequired = self {
            return true
        }
        return false
    }

    var value: Value? {
        if case let .value(value) = self {
            return value
        }
        return nil
    }

    /// 认证刷新后仍是 authRequired/broken 则上抛
    /// 其余原样返回交给调用方按缓存策略处理
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

/// 独立持有账户连接, 与活动监听连接同一个 Codex 后台服务
actor CodexStatusService {
    private var connection: AppServerConnection?
    private var supplementalDataCache = SupplementalDataCache()
    private let socketURL: URL

    init(socketURL: URL = AppServerActivityReader.defaultSocketURL) {
        self.socketURL = socketURL
    }

    // MARK: - 对外入口

    func fetchOutcome() async -> CodexFetchResult {
        var trace = CodexFetchTrace()
        let outcome = resolveOutcome(allowRebuild: true, trace: &trace)
        return CodexFetchResult(outcome: outcome, trace: trace)
    }

    func currentConnectionInfo() async -> CodexServerConnectionInfo? {
        guard let connection, connection.session.isOpen else {
            return nil
        }

        return connection.connectionInfo
    }

    /// 只重建当前客户端连接, 不重启 Codex 后台服务
    func reconnect(minimumVersion: String) throws -> CodexServerConnectionInfo {
        teardownConnection()
        supplementalDataCache = SupplementalDataCache()
        let candidate = try readyConnection()
        guard let version = candidate.connectionInfo.version,
              CodexVersionReader.isVersion(version, atLeast: minimumVersion) == true else {
            teardownConnection()
            throw CodexStatusError.unsupportedVersion(minimum: minimumVersion)
        }
        return candidate.connectionInfo
    }

    func readCodexConfig() async throws -> ConfigReadResponse {
        let connection = try readyConnection()
        return try connection.session.request(
            "config/read",
            params: ["includeLayers": false],
            as: ConfigReadResponse.self
        )
    }

    /// 设置写入统一走批量接口, 让 Codex 负责刷新用户配置
    func writeCodexConfigBatch(edits: [ConfigBatchEdit]) async throws -> ConfigWriteResponse {
        let connection = try readyConnection()
        return try connection.session.request(
            "config/batchWrite",
            params: [
                "edits": edits.map(\.appServerObject),
                "reloadUserConfig": true
            ],
            as: ConfigWriteResponse.self
        )
    }

    /// 自动重置前必须绕过补充数据缓存读取一份新凭证明细
    func readCreditsForAutoReset() throws -> AutoResetRead {
        try withAutoResetConnection { connection in
            try readCreditsForAutoReset(using: connection)
        }
    }

    /// creditId 始终显式传入, 同一凭证的重试始终复用调用方给出的幂等键
    func consumeResetCredit(
        id creditID: String,
        idempotencyKey: String,
        expectedAccountIdentity: String
    ) throws -> ResetCreditConsumeResult {
        let response: ResetCreditConsumeResponse = try withAutoResetConnection { connection in
            let accountResponse = try connection.session.request(
                "account/read",
                params: ["refreshToken": false],
                as: AccountReadResponse.self
            )
            guard let account = accountResponse.account else {
                throw CodexStatusError.notLoggedIn
            }
            guard AutoResetIdentity.accountIdentity(for: account) == expectedAccountIdentity else {
                throw AutoResetServiceError.accountChanged
            }

            connection.accountResponse = accountResponse
            return try connection.session.request(
                "account/rateLimitResetCredit/consume",
                params: [
                    "creditId": creditID,
                    "idempotencyKey": idempotencyKey
                ],
                as: ResetCreditConsumeResponse.self
            )
        }

        // 消费结果已经确定时刷新失败不能覆盖结果
        // 控制器仍会触发完整额度刷新, 这里先满足协议要求并尽快取得剩余次数
        let refreshedRead = try? readCreditsForAutoReset()
        return ResetCreditConsumeResult(
            outcome: response.outcome,
            refreshedRead: refreshedRead
        )
    }

    /// 复用连接出现传输故障时只重建重试一次
    /// 避免故障状态下反复建立连接
    private func resolveOutcome(
        allowRebuild: Bool,
        trace: inout CodexFetchTrace
    ) -> CodexFetchOutcome {
        switch ensureConnection() {
        case .notLoggedIn:
            trace.failureStage = .connect
            return .notLoggedIn
        case let .unsupportedVersion(minimum):
            trace.failureStage = .connect
            return .unsupportedVersion(minimum: minimum)
        case let .initializationFailed(message):
            trace.failureStage = .connect
            return .initializationFailed(message: message)
        case let .ready(connection, reused):
            trace.connection = reused ? .reused : .new
            do {
                let snapshot = try fetchData(
                    using: connection,
                    refreshAccountInfo: reused,
                    trace: &trace
                )
                return .data(snapshot)
            } catch FetchFailure.notLoggedIn {
                supplementalDataCache = SupplementalDataCache()
                teardownConnection()
                return .notLoggedIn
            } catch FetchFailure.needsRebuild {
                teardownConnection()
                if reused, allowRebuild {
                    AppLog.app.notice("codex 连接已失效: reason=transportError")
                    return resolveOutcome(allowRebuild: false, trace: &trace)
                }
                return .initializationFailed(message: CodexStatusError.serverConnectionClosed.localizedDescription)
            } catch {
                teardownConnection()
                return .initializationFailed(message: CodexStatusError.serverConnectionClosed.localizedDescription)
            }
        }
    }

    // MARK: - 连接复用与重建

    private func readyConnection() throws -> AppServerConnection {
        switch ensureConnection() {
        case let .ready(connection, _):
            return connection
        case .notLoggedIn:
            throw CodexStatusError.notLoggedIn
        case let .unsupportedVersion(minimum):
            throw CodexStatusError.unsupportedVersion(minimum: minimum)
        case .initializationFailed:
            throw CodexStatusError.serverConnectionClosed
        }
    }

    /// 自动重置链路在传输故障后重建一次连接
    /// 每次逻辑操作最多刷新一次认证, 不在业务错误上重建连接
    private func withAutoResetConnection<Value>(
        _ operation: (AppServerConnection) throws -> Value
    ) throws -> Value {
        var canRebuild = true

        while true {
            let activeConnection = try readyConnection()

            do {
                return try performAutoResetOperation(
                    using: activeConnection,
                    operation: operation
                )
            } catch let error as CodexStatusError where error.isTransportFailure && canRebuild {
                canRebuild = false
                teardownConnection()
                AppLog.app.notice("自动重置连接已重建: reason=transportError")
            }
        }
    }

    private func performAutoResetOperation<Value>(
        using connection: AppServerConnection,
        operation: (AppServerConnection) throws -> Value
    ) throws -> Value {
        do {
            return try operation(connection)
        } catch let error as CodexStatusError where error.isAuthenticationRequired {
            do {
                try Self.refreshAccount(using: connection)
            } catch FetchFailure.notLoggedIn {
                throw CodexStatusError.notLoggedIn
            } catch FetchFailure.needsRebuild {
                throw CodexStatusError.serverConnectionClosed
            }

            do {
                return try operation(connection)
            } catch let error as CodexStatusError where error.isAuthenticationRequired {
                throw CodexStatusError.notLoggedIn
            }
        }
    }

    private func ensureConnection() -> ConnectionResolution {
        if let connection, connection.session.isOpen {
            return .ready(connection: connection, reused: true)
        }
        teardownConnection()
        let resolution = Self.openConnection(socketURL: socketURL)
        if case let .ready(newConnection, _) = resolution {
            connection = newConnection
        }
        return resolution
    }

    private func teardownConnection() {
        connection?.close()
        connection = nil
    }

    // MARK: - 数据抓取与缓存

    private func readCreditsForAutoReset(
        using connection: AppServerConnection
    ) throws -> AutoResetRead {
        let accountResponse = try connection.session.request(
            "account/read",
            params: ["refreshToken": false],
            as: AccountReadResponse.self
        )
        guard let account = accountResponse.account else {
            throw CodexStatusError.notLoggedIn
        }

        connection.accountResponse = accountResponse
        if supplementalDataCache.useAccount(account) {
            AppLog.app.notice("额度缓存已丢弃: reason=accountChanged")
        }

        let rateLimitsResponse = try connection.session.request(
            "account/rateLimits/read",
            as: AccountRateLimitsResponse.self
        )
        supplementalDataCache.rateLimits = rateLimitsResponse

        let summary = rateLimitsResponse.rateLimitResetCredits
        return AutoResetRead(
            accountIdentity: AutoResetIdentity.accountIdentity(for: account),
            availableCount: summary?.availableCount,
            candidates: summary?.autoResetCandidates
        )
    }

    /// 额度与用量独立读取
    /// 认证失败全程只刷新一次 token
    /// 传输故障交给外层重建连接
    private func fetchData(
        using connection: AppServerConnection,
        refreshAccountInfo: Bool,
        trace: inout CodexFetchTrace
    ) throws -> CodexQuotaSnapshot {
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

        // 失败定位随流程推进, 不靠事后从别的字段反推
        trace.failureStage = .account
        if refreshAccountInfo {
            let accountResult: ReadResult<AccountReadResponse> = try readResultWithAuthRefresh {
                Self.read("account/read", params: ["refreshToken": false], using: connection, as: AccountReadResponse.self)
            }
            if let response = accountResult.value {
                guard response.account != nil else { throw FetchFailure.notLoggedIn }
                connection.accountResponse = response
            }
            trace.account = Self.accountStepResult(response: accountResult.value, didRefresh: didRefresh)
        } else {
            trace.account = .skipped
        }

        guard let account = connection.accountResponse.account else {
            throw FetchFailure.notLoggedIn
        }
        trace.failureStage = .snapshot

        if supplementalDataCache.useAccount(account) {
            AppLog.app.notice("额度缓存已丢弃: reason=accountChanged")
        }

        let rateLimitsRead = try readSupplemental(
            "account/rateLimits/read",
            as: AccountRateLimitsResponse.self,
            cache: &supplementalDataCache.rateLimits
        )
        trace.rateLimits = rateLimitsRead.step

        let usageRead = try readSupplemental(
            "account/usage/read",
            as: AccountUsageResponse.self,
            cache: &supplementalDataCache.usage
        )
        trace.usage = usageRead.step

        trace.resetCredits = Self.resetCreditsStepResult(
            summary: rateLimitsRead.value?.rateLimitResetCredits,
            rateLimitsStep: rateLimitsRead.step
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

        trace.failureStage = nil
        return snapshot
    }

    private static func resetCreditsStepResult(
        summary: RateLimitResetCreditsSummary?,
        rateLimitsStep: CodexFetchTrace.StepResult
    ) -> CodexFetchTrace.StepResult {
        guard let summary else {
            return .missing
        }
        guard summary.availableCount > 0 else {
            return .skipped
        }
        guard summary.credits != nil else {
            return .missing
        }

        return rateLimitsStep == .cached ? .cached : .ok
    }

    /// 读不到账号时后面会沿用连接上缓存的那份
    /// 这种一轮记成 ok 的话, UI 展示的账号其实来自缓存这件事就无从发现
    private static func accountStepResult(
        response: AccountReadResponse?,
        didRefresh: Bool
    ) -> CodexFetchTrace.StepResult {
        guard response != nil else {
            return .cached
        }
        return didRefresh ? .refreshed : .ok
    }

    /// 新值更新缓存
    /// 本轮请求失败则回退到缓存并标记陈旧, 没有缓存才算这一步失败
    /// step 在这里判定而不是事后从 value 与 isStale 反推: 只有这里还看得到原始的 ReadResult
    /// 反推会把"请求失败"和"codex 不支持这个方法"压成同一个值, 而两者的处置完全不同
    private func cachedRead<Value>(
        _ result: ReadResult<Value>,
        cache: inout Value?
    ) -> CachedSupplementalRead<Value> {
        switch result {
        case let .value(value):
            cache = value
            return CachedSupplementalRead(value: value, step: .ok)
        case .skipped(.requestFailed):
            guard let cachedValue = cache else {
                return CachedSupplementalRead(value: nil, step: .failed)
            }
            return CachedSupplementalRead(value: cachedValue, step: .cached)
        case .skipped(.methodUnsupported):
            return CachedSupplementalRead(value: nil, step: .skipped)
        case .authRequired, .broken:
            // resultAfterAuthAttempt 已经把这两种上抛, 到不了这里, 写出来只为穷尽
            return CachedSupplementalRead(value: nil, step: .missing)
        }
    }

    private static func read<Value: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        using connection: AppServerConnection,
        as type: Value.Type
    ) -> ReadResult<Value> {
        do {
            return try .value(connection.session.request(method, params: params, as: type))
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

    /// 初始化失败与未登录在这里分流; 两者都关闭本次新建的连接
    private static func openConnection(socketURL: URL) -> ConnectionResolution {
        do {
            let session = try AccountSession(socketURL: socketURL)
            return initializeConnection(session: session, socketURL: socketURL, openedAt: Date())
        } catch {
            AppServerLogStore.shared.recordFailure(message: error.localizedDescription)
            return .initializationFailed(message: String(localized: "codex-status.daemon.error.unavailable"))
        }
    }

    private static func initializeConnection(
        session: AccountSession,
        socketURL: URL,
        openedAt: Date
    ) -> ConnectionResolution {
        do {
            let initialized = try session.initializeAccount()
            let connectionInfo = CodexServerConnectionInfo(
                socketPath: socketURL.path,
                version: initialized.version,
                openedAt: openedAt
            )

            return .ready(
                connection: AppServerConnection(
                    session: session,
                    accountResponse: initialized.account,
                    connectionInfo: connectionInfo
                ),
                reused: false
            )
        } catch CodexStatusError.notLoggedIn {
            session.close()
            return .notLoggedIn
        } catch let CodexStatusError.unsupportedVersion(minimum) {
            session.close()
            return .unsupportedVersion(minimum: minimum)
        } catch {
            // app-server 链路的细节按既有分工进日志窗口, 不重复写系统日志
            AppServerLogStore.shared.recordFailure(
                message: String(
                    localized: "log.app-server.error.initialization-failed",
                    defaultValue: "\(error.localizedDescription)"
                )
            )
            session.close()
            return .initializationFailed(message: CodexStatusError.serverConnectionClosed.localizedDescription)
        }
    }
}

/// 持有 Codex 后台服务客户端连接及账户和运行版本信息
private final nonisolated class AppServerConnection {
    let session: AccountSession
    let connectionInfo: CodexServerConnectionInfo
    var accountResponse: AccountReadResponse
    private var isClosed = false

    var openedAt: Date {
        connectionInfo.openedAt
    }

    init(
        session: AccountSession,
        accountResponse: AccountReadResponse,
        connectionInfo: CodexServerConnectionInfo
    ) {
        self.session = session
        self.accountResponse = accountResponse
        self.connectionInfo = connectionInfo
    }

    deinit {
        close()
    }

    func close() {
        guard !isClosed else {
            return
        }

        isClosed = true
        session.close()
    }
}
