import Foundation

/// UI 和日志共用的 app-server 错误分类, 保留可重试/需重连判断
nonisolated enum CodexStatusError: LocalizedError {
    case executableNotFound
    case serverTimeout
    case serverConnectionClosed
    case invalidServerResponse
    case serverError(String)
    case unsupportedMethod
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "找不到 Codex CLI 或 Codex APP"
        case .serverTimeout:
            "Codex app-server 等待响应超时"
        case .serverConnectionClosed:
            "Codex app-server 连接已断开"
        case .invalidServerResponse:
            "Codex app-server 返回无法解析"
        case let .serverError(message):
            message
        case .unsupportedMethod:
            "Codex app-server 不支持该接口"
        case .notLoggedIn:
            "Codex 未登录"
        }
    }

    /// codex app-server 未登录
    var isAuthenticationRequired: Bool {
        serverErrorMessageContains("codex account authentication required")
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

    /// 连接断开, 超时, 无法解析都需要重建 app-server 会话
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
