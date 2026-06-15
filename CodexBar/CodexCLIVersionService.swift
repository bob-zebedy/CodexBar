//
//  CodexCLIVersionService.swift
//  CodexBar
//
//  Created by Bob on 2026-06-15.
//

import Combine
import Foundation

nonisolated struct CodexCLIVersionSnapshot: Equatable, Sendable {
    let global: CodexCLIVersionItem
    let bundled: CodexCLIVersionItem
    let refreshedAt: Date
    
    // distantPast 让首个 refresh 一定通过新鲜度门槛
    static let empty = CodexCLIVersionSnapshot(
        global: CodexCLIVersionItem(source: .global),
        bundled: CodexCLIVersionItem(source: .bundled),
        refreshedAt: .distantPast
    )
}

nonisolated struct CodexCLIVersionItem: Equatable, Identifiable, Sendable {
    let source: CodexCLIExecutableSource
    let path: String?
    let version: String?
    let errorMessage: String?
    
    var id: CodexCLIExecutableSource { source }
    
    init(
        source: CodexCLIExecutableSource,
        path: String? = nil,
        version: String? = nil,
        errorMessage: String? = nil
    ) {
        self.source = source
        self.path = path
        self.version = version
        self.errorMessage = errorMessage
    }
    
    var displayVersion: String {
        if path == nil {
            return "未找到 \(source.displayName)"
        }
        
        return version ?? errorMessage ?? "未知版本"
    }
}

/// 把磁盘探测(item)与连接握手(connection)两路版本信息合成为一行可直接渲染的展示数据
nonisolated struct CodexCLIVersionDisplay: Equatable {
    let source: CodexCLIExecutableSource
    let isCurrent: Bool
    let displayVersion: String
    let hasVersion: Bool
    let path: String?
    /// 运行版本落后于磁盘已安装版本时(后台升级尚未重连)的新版本号, 否则 nil
    let newerInstalledVersion: String?
    
    init(item: CodexCLIVersionItem, connection: CodexCLIConnectionInfo?) {
        let isCurrent = connection?.source == item.source
        // 当前来源优先用正在运行的版本(连接握手自报), 其余用磁盘安装版本
        let runningVersion = isCurrent ? connection?.version : nil
        let version = runningVersion ?? item.version
        
        self.source = item.source
        self.isCurrent = isCurrent
        self.hasVersion = version != nil
        self.displayVersion = version ?? item.displayVersion
        self.path = (isCurrent ? connection?.executablePath : nil) ?? item.path
        
        if let runningVersion, let installed = item.version, installed != runningVersion {
            self.newerInstalledVersion = installed
        } else {
            self.newerInstalledVersion = nil
        }
    }
}

nonisolated final class CodexCLIVersionService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexBar.codex-version", qos: .utility)
    private let timeout: TimeInterval
    
    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }
    
    func fetchSnapshot() async -> CodexCLIVersionSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.fetchSnapshotOnQueue(timeout: self.timeout))
            }
        }
    }
    
    private static func fetchSnapshotOnQueue(timeout: TimeInterval) -> CodexCLIVersionSnapshot {
        let environment = CodexCLIResolver.environment
        let installations = CodexCLIResolver.resolveInstallations(environment: environment)
        
        // 两个探测互不依赖, 先并发启动子进程, 再分别收集, 避免串行叠加超时
        let globalProbe = startProbe(
            source: .global,
            path: installations.globalPath,
            environment: environment,
            timeout: timeout
        )
        let bundledProbe = startProbe(
            source: .bundled,
            path: installations.bundledPath,
            environment: environment,
            timeout: timeout
        )
        
        return CodexCLIVersionSnapshot(
            global: finishProbe(globalProbe),
            bundled: finishProbe(bundledProbe),
            refreshedAt: Date()
        )
    }
    
    /// 一个已启动、等待收集的版本探测子进程
    private struct RunningProbe {
        let source: CodexCLIExecutableSource
        let path: String
        let process: Process
        let standardOutput: Pipe
        let standardError: Pipe
        let finished: DispatchSemaphore
        let deadline: DispatchTime
    }
    
    private enum ProbeOutcome {
        case resolved(CodexCLIVersionItem)
        case running(RunningProbe)
    }
    
    private static func startProbe(
        source: CodexCLIExecutableSource,
        path: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProbeOutcome {
        guard let path else {
            return .resolved(CodexCLIVersionItem(source: source))
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = environment
        
        let standardOutput = Pipe()
        let standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in finished.signal() }
        
        do {
            try process.run()
        } catch {
            return .resolved(CodexCLIVersionItem(source: source, path: path, errorMessage: "启动失败"))
        }
        
        return .running(RunningProbe(
            source: source,
            path: path,
            process: process,
            standardOutput: standardOutput,
            standardError: standardError,
            finished: finished,
            deadline: .now() + timeout
        ))
    }
    
    private static func finishProbe(_ outcome: ProbeOutcome) -> CodexCLIVersionItem {
        switch outcome {
        case .resolved(let item):
            return item
        case .running(let probe):
            guard probe.finished.wait(timeout: probe.deadline) == .success else {
                probe.process.terminate()
                return CodexCLIVersionItem(source: probe.source, path: probe.path, errorMessage: "读取超时")
            }
            
            let output = String(
                data: probe.standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let errorOutput = String(
                data: probe.standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            
            guard probe.process.terminationStatus == 0 else {
                return CodexCLIVersionItem(source: probe.source, path: probe.path, errorMessage: "读取失败")
            }
            
            guard let version = firstLine(in: output) ?? firstLine(in: errorOutput) else {
                return CodexCLIVersionItem(source: probe.source, path: probe.path, errorMessage: "版本未知")
            }
            
            return CodexCLIVersionItem(
                source: probe.source,
                path: probe.path,
                version: CodexCLIVersionReader.displayVersion(from: version)
            )
        }
    }
    
    private static func firstLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
    
}

nonisolated enum CodexCLIVersionReader {
    static func displayVersion(from output: String) -> String {
        output
            .split(whereSeparator: \.isWhitespace)
            .first { $0.first?.isNumber == true }
            .map(String.init) ?? output
    }
}

@MainActor
final class CodexCLIVersionViewModel: ObservableObject {
    @Published private(set) var snapshot = CodexCLIVersionSnapshot.empty
    @Published private(set) var isRefreshing = false
    
    // 版本几乎不变, 短时间内重复触发(didBecomeActive 频繁到达)直接复用上次结果
    private static let refreshThrottle: TimeInterval = 60
    
    private let service: CodexCLIVersionService
    private var refreshTask: Task<Void, Never>?
    
    init(service: CodexCLIVersionService = CodexCLIVersionService()) {
        self.service = service
    }
    
    deinit {
        refreshTask?.cancel()
    }
    
    func refresh() {
        // 合并并发触发与短时重复触发(onAppear 与 didBecomeActive 常同时/频繁到达), 避免重复启动子进程
        guard !isRefreshing,
              Date().timeIntervalSince(snapshot.refreshedAt) > Self.refreshThrottle else {
            return
        }
        isRefreshing = true
        
        refreshTask = Task {
            let snapshot = await service.fetchSnapshot()
            
            guard !Task.isCancelled else { return }
            
            self.snapshot = snapshot
            self.isRefreshing = false
        }
    }
}
