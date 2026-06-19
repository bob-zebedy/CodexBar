import Foundation

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
            return "找不到 Codex CLI 或 Codex APP"
        default:
            return nil
        }
    }
    
    // codex app-server 未登录
    var isAuthenticationRequired: Bool {
        serverErrorMessageContains("codex account authentication required")
    }
    
    // codex app-server 不支持的方法
    var isUnsupportedMethod: Bool {
        switch self {
        case .unsupportedMethod:
            return true
        default:
            return serverErrorMessageContains("Invalid request: unknown variant")
        }
    }
    
    var isRetriableServerError: Bool {
        guard case .serverError = self else {
            return false
        }
        
        return !isAuthenticationRequired && !isUnsupportedMethod
    }
    
    // 连接断开、超时、无法解析都需要重建 app-server 会话
    var isTransportFailure: Bool {
        switch self {
        case .serverConnectionClosed, .serverTimeout, .invalidServerResponse:
            return true
        default:
            return false
        }
    }
    
    private func serverErrorMessageContains(_ keyword: String) -> Bool {
        guard case .serverError(let message) = self else {
            return false
        }
        
        return message.range(of: keyword, options: .caseInsensitive) != nil
    }
}
