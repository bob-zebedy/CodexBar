import Foundation
import os

/// 对 app-server stdio JSON-RPC 的薄封装
/// 负责日志记录, 超时和 unsupported 方法缓存
final nonisolated class AppServerSession {
    let process: Process

    private typealias EncodedMessage = (data: Data, text: String)
    private typealias ResponseLine = (text: String, data: Data)

    private static let writeFailureMessage = String(localized: "request-log.error.write-connection-closed")
    private static let responseConnectionClosedMessage = String(localized: "request-log.error.response-connection-closed")
    private static let responseTimeoutMessage = String(localized: "request-log.error.response-timeout")
    private static let closeGracefulTimeout: TimeInterval = 1.0
    private static let closeKillTimeout: TimeInterval = 0.5

    private let input: Pipe
    private let lineReader: JSONLineReader
    private let errorReader: PipeDrain
    private let timeout: TimeInterval
    private let deadline: Date?
    private let logStorage: RequestLogStorage?
    private var nextId = 1
    private var unsupportedMethods: Set<String> = []

    private init(
        process: Process,
        input: Pipe,
        lineReader: JSONLineReader,
        errorReader: PipeDrain,
        timeout: TimeInterval,
        deadline: Date?
    ) {
        self.process = process
        self.input = input
        self.lineReader = lineReader
        self.errorReader = errorReader
        self.timeout = timeout
        self.deadline = deadline
        logStorage = deadline == nil ? .shared : nil
    }

    static func launch(
        command: AppServerCommand,
        environment: [String: String],
        timeout: TimeInterval,
        deadline: Date? = nil,
        usesCustomProxy: Bool = false
    ) throws -> AppServerSession {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        // 只覆盖本次子进程, 避免系统优先策略盖过用户在 App 中指定的代理
        process.arguments = command.arguments + (usesCustomProxy ? ["-c", "features.respect_system_proxy=false"] : [])
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let reader = JSONLineReader(fileHandle: output.fileHandleForReading)
        let errorReader = PipeDrain(fileHandle: error.fileHandleForReading)
        do {
            try process.run()
        } catch {
            reader.stop()
            errorReader.stop()
            throw error
        }
        return AppServerSession(
            process: process,
            input: input,
            lineReader: reader,
            errorReader: errorReader,
            timeout: timeout,
            deadline: deadline
        )
    }

    static func redactingProxyCredentials(_ text: String) -> String {
        func redact(_ value: Any) -> Any {
            switch value {
            case let string as String:
                string.replacingOccurrences(
                    of: #"(?i)(https?://)[^\s/"@]+@"#,
                    with: "$1<redacted>@",
                    options: .regularExpression
                )
            case let object as [String: Any]: object.mapValues(redact)
            case let array as [Any]: array.map(redact)
            default: value
            }
        }

        // 先解码 JSON 转义, 避免 URL 中的斜杠或 Unicode 转义绕过脱敏
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed),
           let data = try? JSONSerialization.data(withJSONObject: redact(object), options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
           let result = String(data: data, encoding: .utf8) {
            return result
        }
        return redact(text) as? String ?? text
    }

    func initializeAccount() throws -> (version: String, account: AccountReadResponse) {
        let result = try request(
            "initialize",
            params: ["clientInfo": [
                "name": "codex_bar",
                "title": "Codex Bar",
                "version": Self.clientVersion()
            ]],
            as: InitializeResult.self
        )
        let version = Self.serverVersion(fromUserAgent: result.userAgent)
        let minimum = CodexCLIMinimumVersion.global
        guard let version, CodexCLIVersionReader.isVersion(version, atLeast: minimum) == true else {
            let error = CodexStatusError.unsupportedVersion(minimum: minimum)
            if let logStorage {
                let details = LogFields.joined("current=\(version ?? "unknown")", "minimum=\(minimum)")
                AppLog.codexCLI.notice("Codex 版本不支持: \(details, privacy: .public)")
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
        lineReader.stop()
        errorReader.stop()
        try? input.fileHandleForWriting.close()

        if process.isRunning {
            switch ProcessTermination.terminate(
                process,
                gracefulTimeout: Self.closeGracefulTimeout,
                killTimeout: Self.closeKillTimeout
            ) {
            case .alreadyExited, .terminated:
                break
            case .killed:
                logStorage?.recordFailure(
                    message: String(localized: "request-log.error.exit-timeout-killed")
                )
            case .stillRunning:
                logStorage?.recordFailure(
                    message: String(localized: "request-log.error.exit-timeout-running")
                )
            }
        }
    }

    func notify(_ method: String, params: [String: Any]? = nil) throws {
        let encoded = try encodeMessage(method: method, id: nil, params: params)

        try writeEncoded(encoded) {
            logStorage?.recordFailure(method: method, message: Self.writeFailureMessage)
        }
        logStorage?.recordRequestWithEmptyResponse(method: method, payload: encoded.text)
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
        } catch let error as CodexStatusError where deadline == nil && error.isRetriableServerError {
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
        let id = nextId
        nextId += 1
        let encoded = try encodeMessage(method: method, id: id, params: params)
        let token = logStorage?.beginRequest(method: method, payload: encoded.text) ?? UUID()

        try writeEncoded(encoded) {
            logStorage?.failRequest(token, message: Self.writeFailureMessage)
        }

        return try waitForResponse(id: id, token: token, decode: type)
    }

    private func encodeMessage(method: String, id: Int?, params: [String: Any]?) throws -> EncodedMessage {
        try encode(message(method: method, id: id, params: params))
    }

    private func message(method: String, id: Int?, params: [String: Any]?) -> [String: Any] {
        var object: [String: Any] = ["method": method]
        if let id {
            object["id"] = id
        }
        if let params {
            object["params"] = params
        }
        return object
    }

    private func encode(_ object: [String: Any]) throws -> EncodedMessage {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                object,
                .init(codingPath: [], debugDescription: "Encoded app-server JSON was not UTF-8")
            )
        }
        return (data, text)
    }

    private func writeEncoded(_ encoded: EncodedMessage, onFailure: () -> Void) throws {
        do {
            try writeData(encoded.data)
        } catch {
            onFailure()
            throw CodexStatusError.serverConnectionClosed
        }
    }

    private func writeData(_ data: Data) throws {
        var payload = data
        payload.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: payload)
    }

    private func waitForResponse<Response: Decodable>(
        id: Int,
        token: UUID,
        decode type: Response.Type
    ) throws -> Response {
        let deadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(timeout))
        let decoder = JSONDecoder()

        // stdout 可能混有无关日志行, 只消费 id 匹配的 JSON-RPC 响应
        while Date() < deadline {
            if self.deadline != nil {
                try Task.checkCancellation()
            }
            guard let line = try nextResponseLine(
                matching: id,
                before: deadline,
                token: token,
                decoder: decoder
            ) else {
                continue
            }

            let result = try decodeResponse(line, as: type, token: token, decoder: decoder)
            logStorage?.finishRequest(token, response: Self.redactingProxyCredentials(line.text))
            return result
        }

        try failRequest(token, message: Self.responseTimeoutMessage, error: .serverTimeout)
    }

    private func nextResponseLine(
        matching id: Int,
        before deadline: Date,
        token: UUID,
        decoder: JSONDecoder
    ) throws -> ResponseLine? {
        let remaining = max(0, deadline.timeIntervalSinceNow)
        let wait = self.deadline == nil ? remaining : min(0.1, remaining)
        guard let text = lineReader.nextLine(timeout: wait) else {
            if lineReader.isClosed {
                try failRequest(token, message: Self.responseConnectionClosedMessage, error: .serverConnectionClosed)
            }

            return nil
        }

        guard let data = text.data(using: .utf8),
              let idEnvelope = try? decoder.decode(RPCIDEnvelope.self, from: data),
              idEnvelope.id == id else {
            return nil
        }

        return (text, data)
    }

    private func decodeResponse<Response: Decodable>(
        _ line: ResponseLine,
        as _: Response.Type,
        token: UUID,
        decoder: JSONDecoder
    ) throws -> Response {
        let envelope: RPCResponseEnvelope<Response>
        do {
            envelope = try decoder.decode(RPCResponseEnvelope<Response>.self, from: line.data)
        } catch is RPCResponsePayloadDecodingError {
            try failRequest(token, message: line.text, error: .invalidResponsePayload)
        } catch {
            try failRequest(token, message: line.text, error: .invalidServerResponse)
        }

        if let error = envelope.error {
            try failRequest(token, message: line.text, error: .serverError(Self.redactingProxyCredentials(error.message)))
        }
        if let result = envelope.result {
            return result
        }

        try failRequest(token, message: line.text, error: .invalidServerResponse)
    }

    private func failRequest(_ token: UUID, message: String, error: CodexStatusError) throws -> Never {
        logStorage?.failRequest(token, message: Self.redactingProxyCredentials(message))
        throw error
    }
}

private nonisolated struct InitializeResult: Decodable {
    let userAgent: String?
}

/// 先轻量读取 id, 避免把其他请求或日志行误当成本次响应
private nonisolated struct RPCIDEnvelope: Decodable {
    let id: Int?
}

/// error 与 result 合并在同一个信封里一次解码
/// result 形状不匹配时单独分类, 响应行已消费不会破坏会话边界
private nonisolated struct RPCResponseEnvelope<Response: Decodable>: Decodable {
    let error: RPCError?
    let result: Response?

    private enum CodingKeys: String, CodingKey {
        case error
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        guard error == nil else {
            result = nil
            return
        }

        do {
            result = try container.decodeIfPresent(Response.self, forKey: .result)
        } catch {
            throw RPCResponsePayloadDecodingError()
        }
    }
}

private nonisolated struct RPCResponsePayloadDecodingError: Error {}

private nonisolated struct RPCError: Decodable {
    let message: String
}
