import Foundation

/// 账户通知只触发重新读取, 不将不完整的推送载荷合并进账户快照
nonisolated enum AccountChange: Sendable {
    case account
    case rateLimits

    init?(method: String) {
        switch method {
        case "account/updated": self = .account
        case "account/rateLimits/updated": self = .rateLimits
        default: return nil
        }
    }

    func merging(_ other: Self?) -> Self {
        self == .account || other == .account ? .account : .rateLimits
    }
}

/// 账户连接负责业务解码与重试, 传输和请求日志复用共享 WebSocket
final nonisolated class AccountSession {
    private let transport: AppServerSession
    private let timeout: TimeInterval
    private var unsupportedMethods: Set<String> = []

    var isOpen: Bool {
        transport.isOpen
    }

    init(socketURL: URL, timeout: TimeInterval = 20, logStorage: AppServerLogStore?) throws {
        transport = try AppServerSession(socketURL: socketURL, retainsNotifications: false, logStorage: logStorage, connectionName: "account")
        self.timeout = timeout
    }

    func initializeAccount() throws -> (version: String, account: AccountReadResponse) {
        let version = try transport.initialize(
            clientName: "codex_bar_account", minimumVersion: CodexVersionReader.minimumAppServerVersion, timeout: timeout, title: "Codex Bar"
        )
        let account = try perform(AccountRequests.account(refreshToken: false))
        return (version, account)
    }

    /// 与请求共用所属 actor, 空闲读取不会与响应读取并发
    func pollChanges() throws -> AccountChange? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        for _ in 0 ..< 32 {
            guard ContinuousClock.now < deadline, try transport.nextEvent() != nil else { break }
        }
        return transport.takeAccountChange()
    }

    func close() {
        transport.close()
    }

    func perform<Response>(_ request: AppServerRequest<Response>) throws -> Response {
        guard !unsupportedMethods.contains(request.method) else {
            throw CodexStatusError.unsupportedMethod
        }

        // app-server 偶发业务错误可重试一次; 传输错误由上层重建连接
        do {
            return try performRequestRememberingUnsupported(request)
        } catch let error as CodexStatusError where error.isRetriableServerError && AppServerRPC.permitsRetry(request.method) {
            return try performRequestRememberingUnsupported(request)
        }
    }

    private func performRequestRememberingUnsupported<Response>(
        _ request: AppServerRequest<Response>
    ) throws -> Response {
        do {
            return try transport.request(request.method, params: request.params, timeout: request.timeout ?? timeout)
        } catch let error as CodexStatusError {
            if error.isUnsupportedMethod {
                unsupportedMethods.insert(request.method)
            }
            throw error
        }
    }
}
