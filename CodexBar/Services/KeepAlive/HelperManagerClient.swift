import Foundation
import ServiceManagement

/// 管理进程只在查询或变更注册时启动, 输出与执行时间由共用进程内核约束
actor HelperManagerClient {
    private let executeCommand: @Sendable (HelperManagement.Command) async throws -> SMAppService.Status
    private let retryDelay: Duration
    private var pending: Task<SMAppService.Status, Error>?
    private var generation: UInt64 = 0

    init(
        appURL: URL = Bundle.main.bundleURL,
        retryDelay: Duration = .seconds(1),
        executeCommand: (@Sendable (HelperManagement.Command) async throws -> SMAppService.Status)? = nil
    ) {
        self.executeCommand = executeCommand ?? { command in
            try await Self.execute(command, appURL: appURL)
        }
        self.retryDelay = retryDelay
    }

    func perform(_ command: HelperManagement.Command) async throws -> SMAppService.Status {
        let previous = pending
        let executeCommand = executeCommand
        let retryDelay = retryDelay
        generation &+= 1
        let requestGeneration = generation
        let task = Task {
            _ = try? await previous?.value
            // 只重试只读查询, 避免重复注册或注销改变系统状态
            var retriesRemaining = command == .status ? 2 : 0
            while true {
                try Task.checkCancellation()
                do {
                    let status = try await executeCommand(command)
                    try Task.checkCancellation()
                    return status
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    guard retriesRemaining > 0 else { throw error }
                    retriesRemaining -= 1
                    try await Task.sleep(for: retryDelay)
                }
            }
        }
        pending = task
        defer {
            if generation == requestGeneration {
                pending = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func execute(_ command: HelperManagement.Command, appURL: URL) async throws -> SMAppService.Status {
        let executable = HelperManagement.bundleURL(in: appURL)
            .appending(path: "Contents/MacOS/\(HelperManagement.executableName)")
        let result = await BoundedProcess.runAsync(
            executable: executable,
            arguments: [command.rawValue],
            timeout: 10,
            configuration: .init(outputMode: .separate)
        )
        try Task.checkCancellation()
        guard result.exitCode == 0, !result.standardOutput.isTruncated else {
            throw ClientError.executionFailed
        }
        return try Self.status(from: result.standardOutput.data, command: command)
    }

    nonisolated static func status(from data: Data, command: HelperManagement.Command) throws -> SMAppService.Status {
        let reply = try JSONDecoder().decode(HelperManagement.Reply.self, from: data)
        guard let status = SMAppService.Status(rawValue: reply.status) else {
            throw ClientError.invalidStatus
        }
        switch status {
        case .notRegistered, .enabled, .requiresApproval, .notFound:
            break
        @unknown default:
            throw ClientError.invalidStatus
        }
        // 首次注册等待系统批准时可能返回 EPERM, 状态已经登记才接受该结果
        if let domain = reply.errorDomain, let code = reply.errorCode {
            if command != .register || (status != .enabled && status != .requiresApproval) {
                throw NSError(domain: domain, code: code)
            }
        }
        return status
    }

    enum ClientError: Error {
        case executionFailed
        case invalidStatus
    }
}
