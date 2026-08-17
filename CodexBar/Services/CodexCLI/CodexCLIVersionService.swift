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

/// 单个安装源的磁盘检测结果
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
            return String(
                localized: "codex-cli.version.not-found",
                defaultValue: "\(source.displayName)"
            )
        }

        return version ?? errorMessage ?? String(localized: "codex-cli.version.unknown")
    }
}

/// 合并磁盘检测版本和当前 app-server 握手版本
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

/// 并发检测 Codex CLI 与 Codex APP 内置 CLI 的磁盘版本
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

        // 两个安装源互不依赖, 并发检测避免两个超时串行叠加
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
            logVersionDetectionFailure(
                source: source,
                stage: "launch",
                detail: error.localizedDescription
            )
            return failedVersionItem(source: source, path: path, failure: .launch)
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
            logVersionDetectionFailure(source: source, stage: "timeout")
            return failedVersionItem(source: source, path: path, failure: .timeout)
        }

        let output = collectedText(from: outputCollector, deadline: deadline)
        let errorOutput = collectedText(from: errorCollector, deadline: deadline)

        guard process.terminationStatus == 0 else {
            logVersionDetectionFailure(
                source: source,
                stage: "exit",
                exitCode: process.terminationStatus
            )
            return failedVersionItem(source: source, path: path, failure: .read)
        }

        guard let version = firstLine(in: output) ?? firstLine(in: errorOutput) else {
            logVersionDetectionFailure(source: source, stage: "parse")
            return failedVersionItem(source: source, path: path, failure: .parse)
        }

        let displayVersion = CodexCLIVersionReader.displayVersion(from: version)
        logVersionDetectionCompleted(source: source, version: displayVersion)
        return CodexCLIVersionItem(
            source: source,
            path: path,
            version: displayVersion
        )
    }

    private static func logVersionDetectionFailure(
        source: CodexCLIExecutableSource,
        stage: String,
        exitCode: Int32? = nil,
        detail: String? = nil
    ) {
        var fields = [
            "source=\(source.rawValue)",
            "stage=\(stage)"
        ]
        if let exitCode {
            fields.append("exit=\(exitCode)")
        }
        if let detail {
            fields.append("detail=\(detail)")
        }
        let details = LogFields.joined(fields)
        AppLog.codexCLI.error("版本检测失败: \(details, privacy: .public)")
    }

    private static func logVersionDetectionCompleted(
        source: CodexCLIExecutableSource,
        version: String
    ) {
        let details = LogFields.joined(
            "source=\(source.rawValue)",
            "version=\(version)"
        )
        AppLog.codexCLI.notice("版本检测完成: \(details, privacy: .public)")
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

    private static func failedVersionItem(
        source: CodexCLIExecutableSource,
        path: String,
        failure: VersionProbeFailure
    ) -> CodexCLIVersionItem {
        CodexCLIVersionItem(source: source, path: path, errorMessage: failure.message)
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

    private enum VersionProbeFailure {
        case launch
        case timeout
        case read
        case parse

        var message: String {
            switch self {
            case .launch:
                String(localized: "codex-cli.version.launch-failed")
            case .timeout:
                String(localized: "codex-cli.version.read-timeout")
            case .read:
                String(localized: "codex-cli.version.read-failed")
            case .parse:
                String(localized: "codex-cli.version.parse-failed")
            }
        }
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

/// CodexBar 各能力依赖的 app-server 最低版本
nonisolated enum CodexCLIMinimumVersion {
    static let global = "0.143.0"
    static let hook = "0.145.0"
}

/// 从 ` codex --version` 的输出中提取用户可读版本号
nonisolated enum CodexCLIVersionReader {
    static func displayVersion(from output: String) -> String {
        output
            .split(whereSeparator: \.isWhitespace)
            .first { $0.first?.isNumber == true }
            .map(String.init) ?? output
    }

    /// 返回 nil 表示任一版本不是可识别的语义版本
    static func isVersion(_ version: String, atLeast minimumVersion: String) -> Bool? {
        guard let parsedVersion = SemanticVersion(version),
              let parsedMinimumVersion = SemanticVersion(minimumVersion) else {
            return nil
        }

        return parsedVersion >= parsedMinimumVersion
    }

    private struct SemanticVersion: Comparable {
        let core: [Int]
        let prerelease: [PrereleaseIdentifier]?

        init?(_ rawValue: String) {
            let displayVersion = CodexCLIVersionReader.displayVersion(from: rawValue)
            let versionWithoutBuild = displayVersion.split(
                separator: "+",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )[0]
            let versionParts = versionWithoutBuild.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            let coreParts = versionParts[0].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard coreParts.count == 3 else {
                return nil
            }

            let core = coreParts.compactMap { Int($0) }
            guard core.count == coreParts.count else {
                return nil
            }
            self.core = core

            guard versionParts.count == 2 else {
                prerelease = nil
                return
            }

            let identifiers = versionParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard !identifiers.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else {
                return nil
            }
            prerelease = identifiers.map(PrereleaseIdentifier.init)
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.core != rhs.core {
                return lhs.core.lexicographicallyPrecedes(rhs.core)
            }

            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case let (lhsIdentifiers?, rhsIdentifiers?):
                return lhsIdentifiers.lexicographicallyPrecedes(rhsIdentifiers)
            }
        }
    }

    private enum PrereleaseIdentifier: Comparable {
        case numeric(Int)
        case text(String)

        init(_ value: Substring) {
            if let number = Int(value) {
                self = .numeric(number)
            } else {
                self = .text(String(value))
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.numeric(lhsValue), .numeric(rhsValue)):
                lhsValue < rhsValue
            case (.numeric, .text):
                true
            case (.text, .numeric):
                false
            case let (.text(lhsValue), .text(rhsValue)):
                lhsValue < rhsValue
            }
        }
    }
}

/// 设置页持有的版本检测状态, 负责节流和丢弃过期刷新结果
@MainActor
final class CodexCLIVersionViewModel: ObservableObject {
    @Published private(set) var snapshot = CodexCLIVersionSnapshot.empty
    @Published private(set) var isRefreshing = false

    /// onAppear 和 didBecomeActive 常连发
    /// 版本检测需要节流以避免频繁启动子进程
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
