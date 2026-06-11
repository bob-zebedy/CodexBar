//
//  CodexRateLimitService.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Darwin
import Foundation

/// 与 codex app-server 维持一条常驻连接: 首次拉取时启动进程并完成握手
/// 之后所有额度读取复用同一会话; 进程退出或请求失败时自动重建连接
nonisolated final class CodexRateLimitService: @unchecked Sendable {
    private nonisolated static let bundledExecutablePath = "/Applications/Codex.app/Contents/Resources/codex"
    private static let requestTimeout: TimeInterval = 20
    // 连接定期回收: 覆盖 codex 全局升级后换用新二进制
    private static let connectionMaxAge: TimeInterval = 1 * 60 * 60
    // 进程环境在应用启动后不会变化, 只构建一次
    private static let environment = appServerEnvironment()
    
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
        
        let command = try Self.resolveAppServerCommand(environment: Self.environment)
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
    
    private static func fetchSnapshot(using connection: AppServerConnection) throws -> CodexQuotaSnapshot {
        let rateLimitsResponse: AccountRateLimitsResponse
        do {
            rateLimitsResponse = try connection.session.request(
                "account/rateLimits/read",
                as: AccountRateLimitsResponse.self
            )
        } catch let error as CodexRateLimitError where error.isAuthenticationRequired {
            connection.accountResponse = try connection.session.request(
                "account/read",
                params: ["refreshToken": true],
                as: AccountReadResponse.self
            )
            
            do {
                rateLimitsResponse = try connection.session.request(
                    "account/rateLimits/read",
                    as: AccountRateLimitsResponse.self
                )
            } catch let retryError as CodexRateLimitError where retryError.isAuthenticationRequired {
                throw CodexRateLimitError.authenticationRequired
            }
        }
        
        let usageResponse = try? connection.session.request(
            "account/usage/read",
            as: AccountUsageResponse.self
        )
        
        return try CodexQuotaSnapshot(
            accountResponse: connection.accountResponse,
            rateLimitsResponse: rateLimitsResponse,
            usageResponse: usageResponse
        )
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
        let errorReader = PipeTextCollector(fileHandle: standardError.fileHandleForReading)
        
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        
        do {
            try process.run()
        } catch {
            throw CodexRateLimitError.serverStartFailed(error.localizedDescription)
        }
        
        let session = AppServerSession(
            process: process,
            input: standardInput,
            lineReader: lineReader,
            errorReader: errorReader,
            timeout: timeout
        )
        
        do {
            _ = try session.request(
                "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_bar",
                        "title": "Codex Bar",
                        "version": clientVersion
                    ]
                ],
                as: EmptyResponse.self
            )
            
            try session.notify("initialized")
            
            let accountResponse = try session.request(
                "account/read",
                params: ["refreshToken": false],
                as: AccountReadResponse.self
            )
            
            return AppServerConnection(
                session: session,
                accountResponse: accountResponse
            )
        } catch {
            session.close()
            throw error
        }
    }
    
    private nonisolated static func appServerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDirectory = realUserHomeDirectory()
        let path = environment["PATH"] ?? ""
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.volta/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        
        environment["HOME"] = homeDirectory
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        environment["PATH"] = mergedPath(path, fallbackPaths: fallbackPaths)
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        
        return environment
    }
    
    private nonisolated static func resolveAppServerCommand(environment: [String: String]) throws -> AppServerCommand {
        let cliPath = findExecutable(named: "codex", environment: environment)
        
        if let cliPath, standardizedPath(cliPath) != standardizedPath(bundledExecutablePath) {
            return AppServerCommand(executablePath: cliPath)
        }
        
        if FileManager.default.isExecutableFile(atPath: bundledExecutablePath) {
            return AppServerCommand(executablePath: bundledExecutablePath)
        }
        
        if let cliPath {
            return AppServerCommand(executablePath: cliPath)
        }
        
        throw CodexRateLimitError.executableNotFound
    }
    
    private nonisolated static func findExecutable(
        named executableName: String,
        environment: [String: String]
    ) -> String? {
        guard let path = environment["PATH"] else {
            return nil
        }
        
        for directory in path.split(separator: ":") {
            let executablePath = "\(directory)/\(executableName)"
            if FileManager.default.isExecutableFile(atPath: executablePath) {
                return executablePath
            }
        }
        
        return nil
    }
    
    private nonisolated static func mergedPath(_ path: String, fallbackPaths: [String]) -> String {
        var components: [String] = []
        var seen = Set<String>()
        
        for component in path.split(separator: ":").map(String.init) + fallbackPaths {
            guard !component.isEmpty, !seen.contains(component) else {
                continue
            }
            
            components.append(component)
            seen.insert(component)
        }
        
        return components.joined(separator: ":")
    }
    
    private nonisolated static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
    
    private nonisolated static func clientVersion() -> String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return "1.0.0"
        }
        
        return version
    }
    
    private nonisolated static func realUserHomeDirectory() -> String {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        
        return String(cString: home)
    }
}

private nonisolated final class AppServerConnection {
    let session: AppServerSession
    let openedAt = Date()
    var accountResponse: AccountReadResponse
    
    init(session: AppServerSession, accountResponse: AccountReadResponse) {
        self.session = session
        self.accountResponse = accountResponse
    }
}

private nonisolated final class AppServerSession {
    let process: Process
    
    private let input: Pipe
    private let lineReader: JSONLineReader
    private let errorReader: PipeTextCollector
    private let timeout: TimeInterval
    private var nextId = 1
    
    init(
        process: Process,
        input: Pipe,
        lineReader: JSONLineReader,
        errorReader: PipeTextCollector,
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
        try write(message(method: method, id: nil, params: params))
    }
    
    func request<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        let id = nextId
        nextId += 1
        try write(message(method: method, id: id, params: params))
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
    
    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        input.fileHandleForWriting.write(data)
    }
    
    private func waitForResponse<Response: Decodable>(
        id: Int,
        step: String,
        decode type: Response.Type
    ) throws -> Response {
        let deadline = Date().addingTimeInterval(timeout)
        let decoder = JSONDecoder()
        
        while Date() < deadline {
            guard let line = lineReader.nextLine(timeout: 0.2) else {
                continue
            }
            
            guard let data = line.data(using: .utf8) else {
                continue
            }
            
            if let errorEnvelope = try? decoder.decode(RPCErrorEnvelope.self, from: data),
               errorEnvelope.id == id,
               let error = errorEnvelope.error {
                throw CodexRateLimitError.serverError(error.message)
            }
            
            guard let envelope = try? decoder.decode(RPCResponseEnvelope<Response>.self, from: data),
                  envelope.id == id,
                  let result = envelope.result else {
                continue
            }
            
            return result
        }
        
        let stderr = errorReader.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty {
            throw CodexRateLimitError.serverTimeout(step)
        }
        
        throw CodexRateLimitError.serverTimeout("\(step)：\(stderr)")
    }
}

private nonisolated struct AppServerCommand: Sendable {
    let executablePath: String
    let arguments = ["app-server", "--listen", "stdio://"]
}

private nonisolated struct EmptyResponse: Decodable {}

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
        
        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success else {
            return nil
        }
        
        return popLine()
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
    }
    
    private func append(_ data: Data) {
        guard !data.isEmpty else {
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
    
    private func popLine() -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        guard !lines.isEmpty else {
            return nil
        }
        
        return lines.removeFirst()
    }
}

private nonisolated final class PipeTextCollector: @unchecked Sendable {
    // 常驻连接 stderr 只保留末尾, 避免无界增长
    private static let maxBytes = 16_384
    
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private var data = Data()
    
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
    }
    
    func stop() {
        fileHandle.readabilityHandler = nil
    }
    
    private func append(_ newData: Data) {
        guard !newData.isEmpty else {
            return
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        data.append(newData)
        if data.count > Self.maxBytes {
            data = Data(data.suffix(Self.maxBytes))
        }
    }
}
