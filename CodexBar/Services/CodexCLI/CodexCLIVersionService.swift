import Combine
import Foundation

nonisolated struct CodexCLIVersionSnapshot: Equatable, Sendable {
    let global: CodexCLIVersionItem
    let bundled: CodexCLIVersionItem
    let refreshedAt: Date

    // 让首次 refresh 不受节流限制
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

// 合并磁盘探测版本和当前 app-server 握手版本
nonisolated struct CodexCLIVersionDisplay: Equatable {
    let source: CodexCLIExecutableSource
    let isCurrent: Bool
    let displayVersion: String
    let hasVersion: Bool
    let path: String?
    // 当前会话尚未重连到新安装版本时显示的新版本号
    let newerInstalledVersion: String?

    init(item: CodexCLIVersionItem, connection: CodexCLIConnectionInfo?) {
        let isCurrent = connection?.source == item.source
        // 当前来源优先显示正在运行的版本, 避免后台升级后误报已生效
        let runningVersion = isCurrent ? connection?.version : nil
        let version = runningVersion ?? item.version

        self.source = item.source
        self.isCurrent = isCurrent
        self.hasVersion = version != nil
        self.displayVersion = version ?? item.displayVersion
        self.path = (isCurrent ? connection?.executablePath : nil) ?? item.path

        if let runningVersion,
           let installed = item.version,
           Self.isInstalledVersionNewer(installed, than: runningVersion) {
            self.newerInstalledVersion = installed
        } else {
            self.newerInstalledVersion = nil
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

nonisolated final class CodexCLIVersionService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexBar.codex-version", qos: .utility)
    private let timeout: TimeInterval
    private static let pipeDrainTimeout: TimeInterval = 0.25
    private static let maxPipeOutputBytes = 64 * 1024

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

        // 两个安装源互不依赖, 先并发启动再收集, 避免两个超时串行叠加
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

    private struct RunningProbe {
        let source: CodexCLIExecutableSource
        let path: String
        let process: Process
        let outputCollector: PipeCollector
        let errorCollector: PipeCollector
        let finished: DispatchSemaphore
        let deadline: Date
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
        let outputCollector = PipeCollector(
            fileHandle: standardOutput.fileHandleForReading,
            maxBytes: Self.maxPipeOutputBytes
        )
        let errorCollector = PipeCollector(
            fileHandle: standardError.fileHandleForReading,
            maxBytes: Self.maxPipeOutputBytes
        )
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
            outputCollector: outputCollector,
            errorCollector: errorCollector,
            finished: finished,
            deadline: Date().addingTimeInterval(timeout)
        ))
    }

    private static func finishProbe(_ outcome: ProbeOutcome) -> CodexCLIVersionItem {
        switch outcome {
        case .resolved(let item):
            return item
        case .running(let probe):
            guard probe.finished.wait(timeout: .now() + max(0, probe.deadline.timeIntervalSinceNow)) == .success else {
                terminateTimedOutProbe(probe)
                return CodexCLIVersionItem(source: probe.source, path: probe.path, errorMessage: "读取超时")
            }

            let output = collectedText(from: probe.outputCollector, deadline: probe.deadline)
            let errorOutput = collectedText(from: probe.errorCollector, deadline: probe.deadline)

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

    private static func terminateTimedOutProbe(_ probe: RunningProbe) {
        _ = ProcessTermination.terminate(
            probe.process,
            gracefulTimeout: 0.2,
            killTimeout: 0.2
        )
        stopCollectors(for: probe)
    }

    private static func stopCollectors(for probe: RunningProbe) {
        _ = probe.outputCollector.stopAndRead()
        _ = probe.errorCollector.stopAndRead()
    }

    private static func collectedText(from collector: PipeCollector, deadline: Date) -> String {
        let drainTimeout = min(Self.pipeDrainTimeout, max(0, deadline.timeIntervalSinceNow))
        _ = collector.waitUntilClosed(timeout: drainTimeout)
        return String(data: collector.stopAndRead(), encoding: .utf8) ?? ""
    }

    private static func firstLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

}

private nonisolated final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let closedSemaphore = DispatchSemaphore(value: 0)
    private let fileHandle: FileHandle
    private let maxBytes: Int
    private var data = Data()
    private var isClosed = false

    init(fileHandle: FileHandle, maxBytes: Int) {
        self.fileHandle = fileHandle
        self.maxBytes = max(maxBytes, 0)
        fileHandle.readabilityHandler = { [weak self] handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else {
                handle.readabilityHandler = nil
                self?.markClosed()
                return
            }

            self?.append(availableData)
        }
    }

    func waitUntilClosed(timeout: TimeInterval) -> Bool {
        lock.lock()
        let closed = isClosed
        lock.unlock()

        guard !closed else {
            return true
        }

        return closedSemaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func stopAndRead() -> Data {
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()

        lock.lock()
        let snapshot = data
        isClosed = true
        lock.unlock()
        closedSemaphore.signal()

        return snapshot
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard data.count < maxBytes else {
            return
        }

        data.append(chunk.prefix(maxBytes - data.count))
    }

    private func markClosed() {
        lock.lock()
        isClosed = true
        lock.unlock()
        closedSemaphore.signal()
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

    // onAppear 和 didBecomeActive 常连发, 版本探测需要节流以避免频繁启动子进程
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
