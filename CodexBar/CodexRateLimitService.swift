//
//  CodexRateLimitService.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Foundation

/// 与 codex app-server 维持一条常驻连接: 首次拉取时启动进程并完成握手
/// 之后所有额度读取复用同一会话; 进程退出或请求失败时自动重建连接
nonisolated final class CodexRateLimitService: @unchecked Sendable {
    private static let requestTimeout: TimeInterval = 20
    // 连接定期回收: 覆盖 codex 全局升级后换用新二进制
    private static let connectionMaxAge: TimeInterval = 1 * 60 * 60
    // 进程环境在应用启动后不会变化, 只构建一次
    private static let environment = CodexCLIResolver.environment
    
    // 连接状态只在 queue 上读写
    private let queue = DispatchQueue(label: "CodexBar.app-server", qos: .utility)
    private var connection: AppServerConnection?
    
    init() {}
    
    deinit {
        connection?.session.close()
    }
    
    func fetchRateLimits() async throws -> CodexQuotaSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.fetchRateLimitsOnQueue() })
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
    
    private func fetchRateLimitsOnQueue() throws -> CodexQuotaSnapshot {
        do {
            let (connection, reused) = try ensureConnection()
            do {
                return try Self.fetchSnapshot(using: connection)
            } catch where reused && !((error as? CodexRateLimitError)?.requiresLogin ?? false) {
                // 复用的连接可能已失效 (进程退出、管道断开), 重建一次再试;
                // 全新连接上的失败直接抛出, 避免故障时整套握手做两遍
                teardownConnection()
                return try Self.fetchSnapshot(using: ensureConnection().connection)
            }
        } catch let error as CodexRateLimitError where error.requiresLogin {
            // 凭证失效/已登出: 丢弃旧连接, 用户重新登录后下次轮询起新进程读取最新凭证
            teardownConnection()
            throw error
        }
    }
    
    private func ensureConnection() throws -> (connection: AppServerConnection, reused: Bool) {
        if let connection, connection.session.process.isRunning,
           Date().timeIntervalSince(connection.openedAt) < Self.connectionMaxAge {
            return (connection, reused: true)
        }
        
        teardownConnection()
        
        let command = try CodexCLIResolver.resolveAppServerCommand(environment: Self.environment)
        let newConnection = try Self.openConnection(
            command: command,
            environment: Self.environment,
            clientVersion: Self.clientVersion(),
            timeout: Self.requestTimeout
        )
        
        connection = newConnection
        return (newConnection, reused: false)
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
    
    private static func fetchSnapshot(using connection: AppServerConnection) throws -> CodexQuotaSnapshot {
        func readRateLimits() throws -> AccountRateLimitsResponse {
            try connection.session.request(
                "account/rateLimits/read",
                as: AccountRateLimitsResponse.self
            )
        }
        
        let rateLimitsResponse: AccountRateLimitsResponse
        do {
            rateLimitsResponse = try readRateLimits()
        } catch let error as CodexRateLimitError where error.isAuthenticationRequired {
            connection.accountResponse = try connection.session.request(
                "account/read",
                params: ["refreshToken": true],
                as: AccountReadResponse.self
            )
            
            do {
                rateLimitsResponse = try readRateLimits()
            } catch let retryError as CodexRateLimitError where retryError.isAuthenticationRequired {
                throw CodexRateLimitError.authenticationRequired
            }
        }
        
        let usageResponse = readUsageIfAvailable(using: connection)
        
        return try CodexQuotaSnapshot(
            accountResponse: connection.accountResponse,
            rateLimitsResponse: rateLimitsResponse,
            usageResponse: usageResponse
        )
    }
    
    private static func readUsageIfAvailable(using connection: AppServerConnection) -> AccountUsageResponse? {
        guard connection.isUsageReadAvailable else {
            return nil
        }
        
        do {
            return try connection.session.request(
                "account/usage/read",
                as: AccountUsageResponse.self
            )
        } catch let error as CodexRateLimitError where error.isUnsupportedUsageMethod {
            connection.isUsageReadAvailable = false
            return nil
        } catch {
            return nil
        }
    }
    
    /// 启动 app-server 进程并完成 initialize、account/read 握手, 返回可复用的连接
    private static func openConnection(
        command: AppServerCommand,
        environment: [String: String],
        clientVersion: String,
        timeout: TimeInterval
    ) throws -> AppServerConnection {
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
            throw CodexRateLimitError.serverStartFailed(error.localizedDescription)
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
            
            let commandInfo = CodexCLIConnectionInfo(
                source: command.source,
                executablePath: command.executablePath,
                version: Self.serverVersion(fromUserAgent: initializeResult.userAgent),
                openedAt: openedAt
            )
            
            return AppServerConnection(
                session: session,
                accountResponse: accountResponse,
                commandInfo: commandInfo
            )
        } catch {
            session.close()
            throw error
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
        try write(message(method: method, id: nil, params: params), step: method)
    }
    
    func request<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        let id = nextId
        nextId += 1
        try write(message(method: method, id: id, params: params), step: method)
        return try waitForResponse(id: id, step: method, decode: type)
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
    
    private func write(_ object: [String: Any], step: String) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw CodexRateLimitError.serverConnectionClosed(step)
        }
    }
    
    private func waitForResponse<Response: Decodable>(
        id: Int,
        step: String,
        decode type: Response.Type
    ) throws -> Response {
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        
        while Date() < deadline {
            guard let line = lineReader.nextLine(timeout: deadline.timeIntervalSinceNow) else {
                if lineReader.isClosed {
                    throw CodexRateLimitError.serverConnectionClosed(step)
                }
                
                continue
            }
            
            guard let data = line.data(using: .utf8) else {
                continue
            }
            
            guard let idEnvelope = try? decoder.decode(RPCIDEnvelope.self, from: data),
                  idEnvelope.id == id else {
                continue
            }
            
            if let errorEnvelope = try? decoder.decode(RPCErrorEnvelope.self, from: data),
               let error = errorEnvelope.error {
                throw CodexRateLimitError.serverError(error.message)
            }
            
            guard let envelope = try? decoder.decode(RPCResponseEnvelope<Response>.self, from: data),
                  let result = envelope.result else {
                throw CodexRateLimitError.invalidServerResponse(step)
            }
            
            return result
        }
        
        throw CodexRateLimitError.serverTimeout(step)
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
            self?.append(handle.availableData)
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
        guard !data.isEmpty else {
            markClosed()
            return
        }
        
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
        fileHandle.readabilityHandler = { _ = $0.availableData }
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
    }
}
