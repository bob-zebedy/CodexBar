import Foundation
import os

/// 账户连接负责业务解码与重试, 传输和请求日志复用共享 WebSocket
final nonisolated class AccountSession {
    private typealias EncodedMessage = (data: Data, text: String)
    private let transport: AppServerSession
    private let timeout: TimeInterval
    private let logStorage: AppServerLogStore?
    private var nextID = 1
    private var unsupportedMethods: Set<String> = []

    var isOpen: Bool {
        transport.isOpen
    }

    init(socketURL: URL, timeout: TimeInterval = 20, logStorage: AppServerLogStore? = .shared) throws {
        transport = try AppServerSession(socketURL: socketURL, retainsNotifications: false, logStorage: logStorage, connectionName: "account")
        self.timeout = timeout
        self.logStorage = logStorage
    }

    func initializeAccount() throws -> (version: String, account: AccountReadResponse) {
        let result = try request(
            "initialize",
            params: ["clientInfo": [
                "name": "codex_bar",
                "title": "Codex Bar",
                "version": Self.clientVersion()
            ], "capabilities": ["experimentalApi": true]],
            as: InitializeResult.self
        )
        let version = Self.serverVersion(fromUserAgent: result.userAgent)
        let minimum = CodexMinimumVersion.global
        // 版本未知不能作为明确的低版本结论
        guard let version, let isSupported = CodexVersionReader.isVersion(version, atLeast: minimum) else {
            throw CodexStatusError.invalidServerResponse
        }
        guard isSupported else {
            let error = CodexStatusError.unsupportedVersion(minimum: minimum)
            if let logStorage {
                let details = LogFields.joined("current=\(version)", "minimum=\(minimum)")
                AppLog.codex.notice("Codex 版本不支持: \(details, privacy: .public)")
                logStorage.recordFailure(message: error.localizedDescription)
            }
            throw error
        }
        try notify("initialized")
        let account = try request("account/read", params: ["refreshToken": false], as: AccountReadResponse.self)
        guard account.account != nil else { throw CodexStatusError.notLoggedIn }
        return (version, account)
    }

    private static func clientVersion() -> String {
        guard let version = Bundle.main.shortVersionString, !version.isEmpty else { return "1.0.0" }
        return version
    }

    /// userAgent 首个 token 中 "/" 之后的部分才是实际运行版本
    private static func serverVersion(fromUserAgent userAgent: String?) -> String? {
        guard let firstToken = userAgent?.split(separator: " ").first,
              let slashIndex = firstToken.firstIndex(of: "/") else { return nil }
        let version = firstToken[firstToken.index(after: slashIndex)...]
        return version.isEmpty ? nil : String(version)
    }

    func close() {
        transport.close()
    }

    func notify(_ method: String, params: [String: Any]? = nil) throws {
        let encoded = try encodeMessage(method: method, id: nil, params: params)

        try transport.notify(encoded.data)
    }

    func request<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        guard !unsupportedMethods.contains(method) else {
            throw CodexStatusError.unsupportedMethod
        }

        // app-server 偶发业务错误可重试一次; 传输错误由上层重建连接
        do {
            return try performRequestRememberingUnsupported(method, params: params, as: type)
        } catch let error as CodexStatusError where error.isRetriableServerError && AppServerRPC.permitsRetry(method) {
            return try performRequestRememberingUnsupported(method, params: params, as: type)
        }
    }

    private func performRequestRememberingUnsupported<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        do {
            return try performRequest(method, params: params, as: type)
        } catch let error as CodexStatusError {
            if error.isUnsupportedMethod {
                unsupportedMethods.insert(method)
            }
            throw error
        }
    }

    private func performRequest<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        let id = nextID
        nextID += 1
        let encoded = try encodeMessage(method: method, id: id, params: params)
        do {
            let data = try transport.exchange(encoded.data, id: id, timeout: timeout)
            return try decodeResponse(data, as: type)
        } catch {
            if let failure = error as? CodexStatusError, failure.isTransportFailure {
                close()
            }
            throw error
        }
    }

    private func encodeMessage(method: String, id: Int?, params: [String: Any]?) throws -> EncodedMessage {
        let data = try AppServerRPC.encode(method: method, id: id, params: params)
        return (data, String(bytes: data, encoding: .utf8) ?? "")
    }

    private func decodeResponse<Response: Decodable>(_ data: Data, as type: Response.Type) throws -> Response {
        try AppServerRPC.decode(data, as: type)
    }
}

private nonisolated struct InitializeResult: Decodable {
    let userAgent: String?
}
