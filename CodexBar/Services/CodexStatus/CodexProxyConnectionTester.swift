import Foundation

/// 独立于正式连接的探测, 所有请求共享截止时间且不写入额度交互日志
nonisolated enum CodexProxyConnectionTester {
    static func test(
        configuration: CodexProxyConfiguration,
        password: String,
        source: CodexCLISourceSelection
    ) throws {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(8)
        var configuration = configuration
        configuration.isEnabled = true
        let environment = try configuration.environment(overriding: CodexCLIResolver.environment, password: password)
        let command = try CodexCLIResolver.command(
            from: CodexCLIResolver.resolveInstallations(),
            source: source.source
        )
        let session = try AppServerSession.launch(command: command, environment: environment, timeout: 8, deadline: deadline, usesCustomProxy: true)
        defer { session.close() }
        _ = try session.initializeAccount()
        _ = try session.request("account/rateLimits/read", as: AccountRateLimitsResponse.self)
        try Task.checkCancellation()
    }
}
