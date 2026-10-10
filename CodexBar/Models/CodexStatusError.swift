import Foundation

/// UI 和日志共用的 app-server 错误分类, 保留可重试/需重连判断
nonisolated enum CodexStatusError: LocalizedError {
    case serverTimeout
    case serverConnectionClosed
    case invalidServerResponse
    case invalidResponsePayload
    case serverError(AppServerRPCError)
    case unsupportedMethod
    case unsupportedVersion(minimum: String)
    case notLoggedIn
    case authenticationRequired

    var errorDescription: String? {
        switch self {
        case .serverTimeout:
            String(localized: "codex-status.app-server.error.server-timeout")
        case .serverConnectionClosed:
            String(localized: "codex-status.app-server.error.connection-closed")
        case .invalidServerResponse, .invalidResponsePayload:
            String(localized: "codex-status.app-server.error.invalid-response")
        case let .serverError(error):
            error.message
        case .unsupportedMethod:
            String(localized: "codex-status.app-server.error.unsupported-method")
        case let .unsupportedVersion(minimum):
            String(localized: "codex-version.requirement", defaultValue: "\(minimum)")
        case .authenticationRequired:
            "Codex account authentication required"
        case .notLoggedIn:
            String(localized: "codex-status.account.error.not-logged-in")
        }
    }

    /// codex app-server 未登录
    var isAuthenticationRequired: Bool {
        switch self {
        case .notLoggedIn, .authenticationRequired:
            true
        default:
            serverErrorMessageContains("codex account authentication required")
        }
    }

    /// codex app-server 不支持的方法
    var isUnsupportedMethod: Bool {
        switch self {
        case .unsupportedMethod:
            true
        default:
            serverErrorCode == -32601 || serverErrorMessageContains("Invalid request: unknown variant")
        }
    }

    var isRetriableServerError: Bool {
        guard case .serverError = self else {
            return false
        }

        return !isAuthenticationRequired && !isUnsupportedMethod && !isProtocolOrParameterFailure
    }

    /// 服务端也用 -32600 表示线程历史不可用, 仅匹配当前线程的已知错误
    func isMissingRollout(for threadID: String) -> Bool {
        guard case let .serverError(error) = self else { return false }
        return error.code == -32600 && error.message == "no rollout found for thread id \(threadID)"
    }

    /// 参数或协议形状不正确时继续用同一请求重试不会恢复
    var isProtocolOrParameterFailure: Bool {
        switch self {
        case .invalidResponsePayload, .unsupportedMethod, .unsupportedVersion:
            true
        case .serverError:
            [-32700, -32600, -32602].contains(serverErrorCode ?? 0) || serverErrorMessageContains("invalid params")
                || serverErrorMessageContains("invalid request")
                || serverErrorMessageContains("missing field")
                || serverErrorMessageContains("unknown field")
                || serverErrorMessageContains("invalid type")
        default:
            false
        }
    }

    /// 连接断开, 超时或 JSON-RPC 信封无效时需要重建 app-server 会话
    var isTransportFailure: Bool {
        switch self {
        case .serverConnectionClosed, .serverTimeout, .invalidServerResponse:
            true
        default:
            false
        }
    }

    private var serverErrorCode: Int? {
        guard case let .serverError(error) = self else { return nil }
        return error.code
    }

    private func serverErrorMessageContains(_ keyword: String) -> Bool {
        guard case let .serverError(error) = self else {
            return false
        }

        return error.message.range(of: keyword, options: .caseInsensitive) != nil
    }
}
