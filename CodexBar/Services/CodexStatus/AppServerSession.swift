import Foundation

final nonisolated class AppServerSession {
    let process: Process

    private typealias EncodedMessage = (data: Data, text: String)
    private typealias ResponseLine = (text: String, data: Data)

    private static let writeFailureMessage = "连接已断开, 无法发送请求"
    private static let responseConnectionClosedMessage = "连接已断开, 等待响应失败"
    private static let responseTimeoutMessage = "等待响应超时"
    private static let closeGracefulTimeout: TimeInterval = 1.0
    private static let closeKillTimeout: TimeInterval = 0.5

    private let input: Pipe
    private let lineReader: JSONLineReader
    private let errorReader: PipeDrain
    private let timeout: TimeInterval
    private var nextId = 1
    private var unsupportedMethods: Set<String> = []

    init(
        process: Process,
        input: Pipe,
        lineReader: JSONLineReader,
        errorReader: PipeDrain,
        timeout: TimeInterval
    ) {
        self.process = process
        self.input = input
        self.lineReader = lineReader
        self.errorReader = errorReader
        self.timeout = timeout
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
                RequestLogStore.shared.recordFailure(message: "app-server 退出超时, 已强制结束")
            case .stillRunning:
                RequestLogStore.shared.recordFailure(message: "app-server 退出超时, 可能仍在后台运行")
            }
        }
    }

    func notify(_ method: String, params: [String: Any]? = nil) throws {
        let encoded = try encodeMessage(method: method, id: nil, params: params)

        try writeEncoded(encoded) {
            RequestLogStore.shared.recordFailure(method: method, message: Self.writeFailureMessage)
        }
        RequestLogStore.shared.recordRequestWithEmptyResponse(method: method, payload: encoded.text)
    }

    func request<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        guard !unsupportedMethods.contains(method) else {
            throw CodexStatusError.unsupportedMethod
        }

        do {
            return try performRequestRememberingUnsupported(method, params: params, as: type)
        } catch let error as CodexStatusError where error.isRetriableServerError {
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
        let token = RequestLogStore.shared.beginRequest(method: method, payload: encoded.text)

        try writeEncoded(encoded) {
            RequestLogStore.shared.failRequest(token, message: Self.writeFailureMessage)
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
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()

        while Date() < deadline {
            guard let line = try nextResponseLine(
                matching: id,
                before: deadline,
                token: token,
                decoder: decoder
            ) else {
                continue
            }

            let result = try decodeResponse(line, as: type, token: token, decoder: decoder)
            RequestLogStore.shared.finishRequest(token, response: line.text)
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
        guard let text = lineReader.nextLine(timeout: max(0, deadline.timeIntervalSinceNow)) else {
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
        if let errorEnvelope = try? decoder.decode(RPCErrorEnvelope.self, from: line.data),
           let error = errorEnvelope.error {
            try failRequest(token, message: line.text, error: .serverError(error.message))
        }

        guard let envelope = try? decoder.decode(RPCResponseEnvelope<Response>.self, from: line.data),
              let result = envelope.result else {
            try failRequest(token, message: line.text, error: .invalidServerResponse)
        }

        return result
    }

    private func failRequest(_ token: UUID, message: String, error: CodexStatusError) throws -> Never {
        RequestLogStore.shared.failRequest(token, message: message)
        throw error
    }
}

private nonisolated struct RPCIDEnvelope: Decodable {
    let id: Int?
}

private nonisolated struct RPCResponseEnvelope<Response: Decodable>: Decodable {
    let id: Int?
    let result: Response?
}

private nonisolated struct RPCErrorEnvelope: Decodable {
    let id: Int?
    let error: RPCError?
}

private nonisolated struct RPCError: Decodable {
    let message: String
}
