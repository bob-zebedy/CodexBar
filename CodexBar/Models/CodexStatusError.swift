import Foundation

/// UI 和日志共用的 app-server 错误分类, 保留可重试/需重连判断
nonisolated enum CodexStatusError: LocalizedError {
    case executableNotFound
    case serverTimeout
    case serverConnectionClosed
    case invalidServerResponse
    case invalidResponsePayload
    case serverError(String)
    case unsupportedMethod
    case unsupportedVersion(minimum: String)
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            String(localized: "codex-status.error.executable-not-found")
        case .serverTimeout:
            String(localized: "codex-status.error.server-timeout")
        case .serverConnectionClosed:
            String(localized: "codex-status.error.connection-closed")
        case .invalidServerResponse, .invalidResponsePayload:
            String(localized: "codex-status.error.invalid-response")
        case let .serverError(message):
            message
        case .unsupportedMethod:
            String(localized: "codex-status.error.unsupported-method")
        case let .unsupportedVersion(minimum):
            String(localized: "codex-version.requirement", defaultValue: "\(minimum)")
        case .notLoggedIn:
            String(localized: "codex-status.error.not-logged-in")
        }
    }

    /// codex app-server 未登录
    var isAuthenticationRequired: Bool {
        switch self {
        case .notLoggedIn:
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
            serverErrorMessageContains("Invalid request: unknown variant")
        }
    }

    var isRetriableServerError: Bool {
        guard case .serverError = self else {
            return false
        }

        return !isAuthenticationRequired && !isUnsupportedMethod
    }

    /// 参数或协议形状不正确时继续用同一请求重试不会恢复
    var isProtocolOrParameterFailure: Bool {
        switch self {
        case .invalidResponsePayload, .unsupportedMethod, .unsupportedVersion:
            true
        case .serverError:
            serverErrorMessageContains("invalid params")
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

    private func serverErrorMessageContains(_ keyword: String) -> Bool {
        guard case let .serverError(message) = self else {
            return false
        }

        return message.range(of: keyword, options: .caseInsensitive) != nil
    }
}
