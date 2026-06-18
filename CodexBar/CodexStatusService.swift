import Foundation

/// UI 只关心可展示数据、未登录、初始化失败; 更细的错误保留在交互日志中
nonisolated enum CodexFetchOutcome {
    case data(CodexQuotaSnapshot)
    case notLoggedIn
    case initializationFailed
}

private enum ConnectionResolution {
    case ready(connection: AppServerConnection, reused: Bool)
    case notLoggedIn
    case initializationFailed
}

/// 单接口读取结果按后续动作分类: 跳过、刷新认证、重建连接
private enum ReadResult<Value> {
    case value(Value)
    case skipped
    case authRequired
    case broken
}

private enum FetchFailure: Error {
    case notLoggedIn
    case needsRebuild
}

nonisolated private extension ReadResult {
    var isAuthenticationRequired: Bool {
        if case .authRequired = self {
            return true
        }
        return false
    }
    
    func valueAfterAuthAttempt() throws -> Value? {
        switch self {
        case .value(let value):
            return value
        case .skipped:
            return nil
        case .authRequired:
            throw FetchFailure.notLoggedIn
        case .broken:
            throw FetchFailure.needsRebuild
        }
    }
}

/// 维持一条 codex app-server stdio 会话, 复用失败后按需重建
nonisolated final class CodexStatusService: @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 20
    // 定期回收连接, 让后台升级后的 codex 二进制有机会生效
    private static let connectionMaxAge: TimeInterval = 1 * 60 * 60
    private static let environment = CodexCLIResolver.environment
    
    // connection 只在这个队列上访问
    private let queue = DispatchQueue(label: "CodexBar.app-server", qos: .utility)
    private var connection: AppServerConnection?
    
    // app-server 退出后继续写管道会触发 SIGPIPE; 忽略信号, 让 write 抛错后走重建
    private static let ignoreBrokenPipeSignal: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
    
    init() {
        _ = Self.ignoreBrokenPipeSignal
    }
    
    deinit {
        connection?.session.close()
    }
    
    func fetchOutcome() async -> CodexFetchOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.resolveOutcomeOnQueue(allowRebuild: true))
            }
        }
    }
    
    func currentConnectionInfo() async -> CodexCLIConnectionInfo? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.currentConnectionInfoOnQueue())
            }
        }
    }
    
    /// 复用连接出现传输故障时只重建重试一次, 避免故障状态下反复拉起进程
    private func resolveOutcomeOnQueue(allowRebuild: Bool) -> CodexFetchOutcome {
        switch ensureConnection() {
        case .notLoggedIn:
            return .notLoggedIn
        case .initializationFailed:
            return .initializationFailed
        case .ready(let connection, let reused):
            do {
                let snapshot = try Self.fetchData(using: connection, refreshAccountInfo: reused)
                return .data(snapshot)
            } catch FetchFailure.notLoggedIn {
                teardownConnection()
                return .notLoggedIn
            } catch FetchFailure.needsRebuild {
                teardownConnection()
                if reused && allowRebuild {
                    return resolveOutcomeOnQueue(allowRebuild: false)
                }
                return .initializationFailed
            } catch {
                teardownConnection()
                return .initializationFailed
            }
        }
    }
    
    private func ensureConnection() -> ConnectionResolution {
        if let connection, connection.session.process.isRunning,
           Date().timeIntervalSince(connection.openedAt) < Self.connectionMaxAge {
            return .ready(connection: connection, reused: true)
        }
        
        teardownConnection()
        
        let command: AppServerCommand
        do {
            command = try CodexCLIResolver.resolveAppServerCommand(environment: Self.environment)
        } catch {
            RequestLogStore.shared.recordFailure(message: error.localizedDescription)
            return .initializationFailed
        }
        
        let resolution = Self.openConnection(
            command: command,
            environment: Self.environment,
            clientVersion: Self.clientVersion(),
            timeout: Self.requestTimeout
        )
        if case .ready(let newConnection, _) = resolution {
            connection = newConnection
        }
        return resolution
    }
    
    private func teardownConnection() {
        connection?.session.close()
        connection = nil
    }
    
    private func currentConnectionInfoOnQueue() -> CodexCLIConnectionInfo? {
        guard let connection, connection.session.process.isRunning else {
            return nil
        }
        
        return connection.commandInfo
    }
    
    /// 额度与用量独立读取; 认证失败全程只刷新一次 token, 传输故障交给外层重建连接
    private static func fetchData(using connection: AppServerConnection, refreshAccountInfo: Bool) throws -> CodexQuotaSnapshot {
        var didRefresh = false
        
        func refreshTokenIfNeeded() throws {
            guard !didRefresh else { throw FetchFailure.notLoggedIn }
            didRefresh = true
            try refreshAccount(using: connection)
        }
        
        func readWithAuthRefresh<Value>(_ read: () -> ReadResult<Value>) throws -> Value? {
            let firstAttempt = read()
            guard firstAttempt.isAuthenticationRequired else {
                return try firstAttempt.valueAfterAuthAttempt()
            }
            
            try refreshTokenIfNeeded()
            return try read().valueAfterAuthAttempt()
        }
        
        // 新建连接已读过 account; 复用连接才刷新账户状态
        if refreshAccountInfo {
            if let response: AccountReadResponse = try readWithAuthRefresh({
                read("account/read", params: ["refreshToken": false], using: connection, as: AccountReadResponse.self)
            }) {
                guard response.account != nil else { throw FetchFailure.notLoggedIn }
                connection.accountResponse = response
            }
        }
        
        let rateLimits: AccountRateLimitsResponse? = try readWithAuthRefresh({
            read("account/rateLimits/read", using: connection, as: AccountRateLimitsResponse.self)
        })
        
        let usage: AccountUsageResponse? = try readWithAuthRefresh {
            readUsage(using: connection)
        }
        
        // rateLimits/usage 都可为空, 只要账户有效就让 UI 展示"暂无数据"
        guard let snapshot = try? CodexQuotaSnapshot(
            accountResponse: connection.accountResponse,
            rateLimitsResponse: rateLimits,
            usageResponse: usage
        ) else {
            throw FetchFailure.notLoggedIn
        }
        
        return snapshot
    }
    
    private static func read<Value: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        using connection: AppServerConnection,
        as type: Value.Type
    ) -> ReadResult<Value> {
        do {
            return .value(try connection.session.request(method, params: params, as: type))
        } catch let error as CodexStatusError {
            return classify(error)
        } catch {
            return .broken
        }
    }
    
    private static func readUsage(using connection: AppServerConnection) -> ReadResult<AccountUsageResponse> {
        guard connection.isUsageReadAvailable else {
            return .skipped
        }
        
        do {
            return .value(try connection.session.request("account/usage/read", as: AccountUsageResponse.self))
        } catch let error as CodexStatusError where error.isUnsupportedUsageMethod {
            // 老版本 codex 不支持该方法时, 后续轮询不再请求 usage
            connection.isUsageReadAvailable = false
            return .skipped
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
        // 非认证的业务错误不阻断整轮刷新, 详情只保留在日志中
        return error.isTransportFailure ? .broken : .skipped
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
    
    /// 初始化失败与未登录在这里分流; 两者都不复用本次新建的进程
    private static func openConnection(
        command: AppServerCommand,
        environment: [String: String],
        clientVersion: String,
        timeout: TimeInterval
    ) -> ConnectionResolution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = environment
        
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let lineReader = JSONLineReader(fileHandle: standardOutput.fileHandleForReading)
        let errorReader = PipeDrain(fileHandle: standardError.fileHandleForReading)
        
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        
        do {
            try process.run()
        } catch {
            RequestLogStore.shared.recordFailure(message: "app-server 启动失败: \(error.localizedDescription)")
            return .initializationFailed
        }
        let openedAt = Date()
        
        let session = AppServerSession(
            process: process,
            input: standardInput,
            lineReader: lineReader,
            errorReader: errorReader,
            timeout: timeout
        )
        
        do {
            let initializeResult = try session.request(
                "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_bar",
                        "title": "Codex Bar",
                        "version": clientVersion
                    ]
                ],
                as: InitializeResult.self
            )
            
            try session.notify("initialized")
            
            let accountResponse = try session.request(
                "account/read",
                params: ["refreshToken": false],
                as: AccountReadResponse.self
            )
            
            guard accountResponse.account != nil else {
                session.close()
                return .notLoggedIn
            }
            
            let commandInfo = CodexCLIConnectionInfo(
                source: command.source,
                executablePath: command.executablePath,
                version: Self.serverVersion(fromUserAgent: initializeResult.userAgent),
                openedAt: openedAt
            )
            
            return .ready(
                connection: AppServerConnection(
                    session: session,
                    accountResponse: accountResponse,
                    commandInfo: commandInfo
                ),
                reused: false
            )
        } catch {
            session.close()
            return .initializationFailed
        }
    }
    
    private nonisolated static func clientVersion() -> String {
        guard let version = Bundle.main.shortVersionString, !version.isEmpty else {
            return "1.0.0"
        }
        
        return version
    }
    
    /// userAgent 形如 "codex_bar/0.139.0 (...)"; 取首个 token 中 "/" 之后的运行版本号
    private nonisolated static func serverVersion(fromUserAgent userAgent: String?) -> String? {
        guard let firstToken = userAgent?.split(separator: " ").first,
              let slashIndex = firstToken.firstIndex(of: "/") else {
            return nil
        }
        
        let version = firstToken[firstToken.index(after: slashIndex)...]
        return version.isEmpty ? nil : String(version)
    }
}

private nonisolated final class AppServerConnection {
    let session: AppServerSession
    let commandInfo: CodexCLIConnectionInfo
    var accountResponse: AccountReadResponse
    var isUsageReadAvailable = true
    
    var openedAt: Date { commandInfo.openedAt }
    
    init(
        session: AppServerSession,
        accountResponse: AccountReadResponse,
        commandInfo: CodexCLIConnectionInfo
    ) {
        self.session = session
        self.accountResponse = accountResponse
        self.commandInfo = commandInfo
    }
}

private nonisolated final class AppServerSession {
    let process: Process
    
    private typealias EncodedMessage = (data: Data, text: String)
    private typealias ResponseLine = (text: String, data: Data)
    
    private static let writeFailureMessage = "连接断开, 无法写入请求"
    private static let responseConnectionClosedMessage = "连接断开, 等待响应失败"
    private static let responseTimeoutMessage = "响应超时"
    
    private let input: Pipe
    private let lineReader: JSONLineReader
    private let errorReader: PipeDrain
    private let timeout: TimeInterval
    private var nextId = 1
    
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
            process.terminate()
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
        return (data, String(decoding: data, as: UTF8.self))
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
        as type: Response.Type,
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

private nonisolated struct InitializeResult: Decodable {
    let userAgent: String?
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

private nonisolated final class JSONLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let fileHandle: FileHandle
    private var buffer = Data()
    private var lines: [String] = []
    private var closed = false
    
    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.markClosed()
                return
            }
            self?.append(data)
        }
    }
    
    func nextLine(timeout: TimeInterval) -> String? {
        if let line = popLine() {
            return line
        }
        
        if isClosed {
            return nil
        }
        
        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success else {
            return nil
        }
        
        return popLine()
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
        markClosed()
    }
    
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        
        return closed && lines.isEmpty
    }
    
    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        
        buffer.append(data)
        
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer[..<newlineRange.lowerBound]
            buffer.removeSubrange(...newlineRange.lowerBound)
            
            if let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
                semaphore.signal()
            }
        }
    }
    
    private func markClosed() {
        lock.lock()
        defer {
            lock.unlock()
            semaphore.signal()
        }
        
        if !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
            }
            buffer.removeAll()
        }
        
        closed = true
    }
    
    private func popLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        guard !lines.isEmpty else {
            return nil
        }
        
        return lines.removeFirst()
    }
}

private nonisolated final class PipeDrain: @unchecked Sendable {
    private let fileHandle: FileHandle
    
    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { handle in
            guard !handle.availableData.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
        }
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
    }
}
