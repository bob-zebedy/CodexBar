import Combine
import Foundation
import os

/// 设置页版本区域的完整快照
nonisolated struct CodexCLIVersionSnapshot: Equatable {
    let global: CodexCLIVersionItem
    let bundled: CodexCLIVersionItem
    let refreshedAt: Date

    /// 让首次 refresh 不受节流限制
    static let empty = CodexCLIVersionSnapshot(
        global: CodexCLIVersionItem(source: .global),
        bundled: CodexCLIVersionItem(source: .bundled),
        refreshedAt: .distantPast
    )
}

/// 单个安装源的磁盘探测结果
nonisolated struct CodexCLIVersionItem: Equatable, Identifiable {
    let source: CodexCLIExecutableSource
    let path: String?
    let version: String?
    let errorMessage: String?

    var id: CodexCLIExecutableSource {
        source
    }

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

/// 合并磁盘探测版本和当前 app-server 握手版本
nonisolated struct CodexCLIVersionDisplay: Equatable {
    let source: CodexCLIExecutableSource
    let isCurrent: Bool
    let displayVersion: String
    let hasVersion: Bool
    let path: String?
    /// 当前会话尚未重连到新安装版本时显示的新版本号
    let newerInstalledVersion: String?

    init(item: CodexCLIVersionItem, connection: CodexCLIConnectionInfo?) {
        let isCurrent = connection?.source == item.source
        // 当前来源优先显示正在运行的版本, 避免后台升级后误报已生效
        let runningVersion = isCurrent ? connection?.version : nil
        let version = runningVersion ?? item.version

        source = item.source
        self.isCurrent = isCurrent
        hasVersion = version != nil
        displayVersion = version ?? item.displayVersion
        path = (isCurrent ? connection?.executablePath : nil) ?? item.path

        if let runningVersion,
           let installed = item.version,
           Self.isInstalledVersionNewer(installed, than: runningVersion) {
            newerInstalledVersion = installed
        } else {
            newerInstalledVersion = nil
        }
    }

    private static func isInstalledVersionNewer(
        _ installedVersion: String,
        than runningVersion: String
    ) -> Bool {
        guard let installedComponents = normalizedVersionComponents(from: installedVersion),
              let runningComponents = normalizedVersionComponents(from: runningVersion) else {
            return false
        }

        return runningComponents.lexicographicallyPrecedes(installedComponents)
    }

    private static func normalizedVersionComponents(from version: String) -> [Int]? {
        let components = version
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { $0.isEmpty ? nil : Int($0) }
        guard !components.isEmpty else {
            return nil
        }

        return Array(components.reversed().drop(while: { $0 == 0 }).reversed())
    }
}

/// 并发探测 Codex CLI 与 Codex APP 内置 CLI 的磁盘版本
actor CodexCLIVersionService {
    private let timeout: TimeInterval
    private static let pipeDrainTimeout: TimeInterval = 0.25
    private static let maxPipeOutputBytes = 64 * 1024

    init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    func fetchSnapshot() async -> CodexCLIVersionSnapshot {
        await Self.fetchSnapshot(timeout: timeout)
    }

    private static func fetchSnapshot(timeout: TimeInterval) async -> CodexCLIVersionSnapshot {
        let environment = CodexCLIResolver.environment
        let installations = CodexCLIResolver.resolveInstallations(environment: environment)

        // 两个安装源互不依赖, 并发探测避免两个超时串行叠加
        async let global = probeVersion(
            source: .global,
            path: installations.globalPath,
            environment: environment,
            timeout: timeout
        )
        async let bundled = probeVersion(
            source: .bundled,
            path: installations.bundledPath,
            environment: environment,
            timeout: timeout
        )
        let (globalItem, bundledItem) = await (global, bundled)

        return CodexCLIVersionSnapshot(
            global: globalItem,
            bundled: bundledItem,
            refreshedAt: Date()
        )
    }

    private static func probeVersion(
        source: CodexCLIExecutableSource,
        path: String?,
        environment: [String: String],
        timeout: TimeInterval
    ) async -> CodexCLIVersionItem {
        guard let path else {
            return CodexCLIVersionItem(source: source)
        }

        let deadline = Date().addingTimeInterval(timeout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        let outputCollector = PipeReadBuffer(
            fileHandle: standardOutput.fileHandleForReading,
            maxBytes: Self.maxPipeOutputBytes
        )
        let errorCollector = PipeReadBuffer(
            fileHandle: standardError.fileHandleForReading,
            maxBytes: Self.maxPipeOutputBytes
        )
        let exitWaiter = ProcessExitWaiter()

        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in
            exitWaiter.finish(true)
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stopCollectors(outputCollector: outputCollector, errorCollector: errorCollector)
            return CodexCLIVersionItem(source: source, path: path, errorMessage: "启动失败")
        }
        defer {
            process.terminationHandler = nil
        }

        guard await exitWaiter.wait(timeout: max(0, deadline.timeIntervalSinceNow)) else {
            terminateTimedOutProbe(
                process: process,
                outputCollector: outputCollector,
                errorCollector: errorCollector
            )
            return CodexCLIVersionItem(source: source, path: path, errorMessage: "读取超时")
        }

        let output = collectedText(from: outputCollector, deadline: deadline)
        let errorOutput = collectedText(from: errorCollector, deadline: deadline)

        guard process.terminationStatus == 0 else {
            return CodexCLIVersionItem(source: source, path: path, errorMessage: "读取失败")
        }

        guard let version = firstLine(in: output) ?? firstLine(in: errorOutput) else {
            return CodexCLIVersionItem(source: source, path: path, errorMessage: "版本未知")
        }

        return CodexCLIVersionItem(
            source: source,
            path: path,
            version: CodexCLIVersionReader.displayVersion(from: version)
        )
    }

    private static func terminateTimedOutProbe(
        process: Process,
        outputCollector: PipeReadBuffer,
        errorCollector: PipeReadBuffer
    ) {
        _ = ProcessTermination.terminate(
            process,
            gracefulTimeout: 0.2,
            killTimeout: 0.2
        )
        stopCollectors(outputCollector: outputCollector, errorCollector: errorCollector)
    }

    private static func stopCollectors(outputCollector: PipeReadBuffer, errorCollector: PipeReadBuffer) {
        _ = outputCollector.stopAndRead()
        _ = errorCollector.stopAndRead()
    }

    private static func collectedText(from collector: PipeReadBuffer, deadline: Date) -> String {
        let drainTimeout = min(Self.pipeDrainTimeout, max(0, deadline.timeIntervalSinceNow))
        _ = collector.waitUntilClosed(timeout: drainTimeout)
        return String(bytes: collector.stopAndRead(), encoding: .utf8) ?? ""
    }

    private static func firstLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

/// 将 Process.terminationHandler 桥接成可超时等待的 async 结果
private final nonisolated class ProcessExitWaiter: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Bool, Never>?
        var result: Bool?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait(timeout: TimeInterval) async -> Bool {
        await withTaskCancellationHandler {
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(max(0, timeout)))
                } catch {
                    return
                }

                self?.finish(false)
            }
            defer {
                timeoutTask.cancel()
            }

            return await withCheckedContinuation { continuation in
                let immediateResult: Bool? = state.withLock {
                    if let result = $0.result {
                        return result
                    }

                    $0.continuation = continuation
                    return nil
                }

                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            finish(false)
        }
    }

    func finish(_ result: Bool) {
        let continuation: CheckedContinuation<Bool, Never>? = state.withLock {
            guard $0.result == nil else {
                return nil
            }

            $0.result = result
            let continuation = $0.continuation
            $0.continuation = nil
            return continuation
        }

        continuation?.resume(returning: result)
    }
}

/// 从 ` codex --version` 的输出中提取用户可读版本号
nonisolated enum CodexCLIVersionReader {
    static func displayVersion(from output: String) -> String {
        output
            .split(whereSeparator: \.isWhitespace)
            .first { $0.first?.isNumber == true }
            .map(String.init) ?? output
    }
}

/// 设置页持有的版本探测状态, 负责节流和丢弃过期刷新结果
@MainActor
final class CodexCLIVersionViewModel: ObservableObject {
    @Published private(set) var snapshot = CodexCLIVersionSnapshot.empty
    @Published private(set) var isRefreshing = false

    /// onAppear 和 didBecomeActive 常连发
    /// 版本探测需要节流以避免频繁启动子进程
    private static let refreshThrottle: TimeInterval = 60

    private let service: CodexCLIVersionService
    private let refreshCoordinator = RefreshTaskCoordinator()

    init(service: CodexCLIVersionService = CodexCLIVersionService()) {
        self.service = service
    }

    deinit {
        refreshCoordinator.cancel()
    }

    func refresh() {
        guard !isRefreshing,
              Date().timeIntervalSince(snapshot.refreshedAt) > Self.refreshThrottle else {
            return
        }

        refreshCoordinator.run(
            setRefreshing: { [weak self] in self?.isRefreshing = $0 },
            operation: { [service = self.service] in await service.fetchSnapshot() },
            commit: { [weak self] snapshot in self?.snapshot = snapshot }
        )
    }
}
