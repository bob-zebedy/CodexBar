import Combine
import Foundation
import os

/// 设置页版本区域的完整快照
nonisolated struct CodexVersionSnapshot: Equatable {
    let global: CodexVersionItem
    let bundled: CodexVersionItem
    let refreshedAt: Date

    /// 让首次 refresh 不受节流限制
    static let empty = CodexVersionSnapshot(
        global: CodexVersionItem(source: .global),
        bundled: CodexVersionItem(source: .bundled),
        refreshedAt: .distantPast
    )
}

/// 单个安装源的磁盘检测结果
nonisolated struct CodexVersionItem: Equatable, Identifiable {
    let source: CodexExecutableSource
    let path: String?
    let version: String?
    let errorMessage: String?

    var id: CodexExecutableSource {
        source
    }

    init(
        source: CodexExecutableSource,
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
        version ?? errorMessage ?? String(localized: "codex.version.unknown")
    }
}

/// 并发检测 Codex CLI 与 Codex App 内置 CLI 的磁盘版本
actor CodexVersionService {
    private let timeout: TimeInterval
    private let environment: [String: String]?
    private let installations: CodexInstallations?
    private var activeSources = Set<CodexExecutableSource>()
    private var unfinishedProcesses: [CodexExecutableSource: Process] = [:]

    init(timeout: TimeInterval = 5, environment: [String: String]? = nil, installations: CodexInstallations? = nil) {
        self.timeout = timeout
        self.environment = environment
        self.installations = installations
    }

    func fetchSnapshot() async -> CodexVersionSnapshot {
        let environment = environment ?? CodexPaths.environment
        let installations = installations ?? CodexPaths.resolveInstallations(environment: environment)

        // 两个安装源互不依赖, 并发检测避免两个超时串行叠加
        async let global = probeVersion(
            source: .global,
            path: installations.globalPath,
            environment: environment
        )
        async let bundled = probeVersion(
            source: .bundled,
            path: installations.bundledPath,
            environment: environment
        )
        let (globalItem, bundledItem) = await (global, bundled)

        return CodexVersionSnapshot(
            global: globalItem,
            bundled: bundledItem,
            refreshedAt: Date()
        )
    }

    private func probeVersion(
        source: CodexExecutableSource,
        path: String?,
        environment: [String: String]
    ) async -> CodexVersionItem {
        guard let path else { return CodexVersionItem(source: source) }
        // await 会让出 actor, 同一安装源的旧命令退出前不能再次启动
        guard !activeSources.contains(source), unfinishedProcesses[source]?.isRunning != true else {
            Self.logVersionDetectionFailure(source: source, stage: "busy")
            return Self.failedVersionItem(source: source, path: path, failure: .read)
        }
        unfinishedProcesses[source] = nil
        activeSources.insert(source)
        defer { activeSources.remove(source) }
        let result = await BoundedProcess.runAsync(
            executable: URL(fileURLWithPath: path), arguments: ["--version"], timeout: timeout, environment: environment,
            configuration: .init(
                outputMode: .separate, gracefulTimeout: 0.2, killTimeout: 0.2,
                deadline: timeout.isFinite ? ContinuousClock.now.advanced(by: .seconds(max(0, timeout))) : nil
            )
        )
        unfinishedProcesses[source] = result.runningProcess
        switch result.completion {
        case .exited:
            guard result.exitCode == 0 else {
                Self.logVersionDetectionFailure(source: source, stage: "exit", exitCode: result.exitCode)
                return Self.failedVersionItem(source: source, path: path, failure: .read)
            }
        case let .launchFailed(detail):
            Self.logVersionDetectionFailure(source: source, stage: "launch", detail: detail)
            return Self.failedVersionItem(source: source, path: path, failure: .launch)
        case .timedOut:
            Self.logVersionDetectionFailure(source: source, stage: "timeout")
            return Self.failedVersionItem(source: source, path: path, failure: .timeout)
        case .cancelled:
            // 刷新协调器会丢弃取消结果, 不将主动取消记录为超时
            return Self.failedVersionItem(source: source, path: path, failure: .timeout)
        case .ioFailed, .invalidConfiguration:
            Self.logVersionDetectionFailure(source: source, stage: "read")
            return Self.failedVersionItem(source: source, path: path, failure: .read)
        }

        let output = String(data: result.standardOutput.data, encoding: .utf8) ?? ""
        let errorOutput = String(data: result.standardError.data, encoding: .utf8) ?? ""
        guard let version = Self.firstLine(in: output) ?? Self.firstLine(in: errorOutput) else {
            Self.logVersionDetectionFailure(source: source, stage: "parse")
            return Self.failedVersionItem(source: source, path: path, failure: .parse)
        }

        let displayVersion = CodexVersionReader.displayVersion(from: version)
        Self.logVersionDetectionCompleted(source: source, version: displayVersion)
        return CodexVersionItem(source: source, path: path, version: displayVersion)
    }

    private static func logVersionDetectionFailure(
        source: CodexExecutableSource,
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
        AppLog.codex.error("版本检测失败: \(details, privacy: .public)")
    }

    private static func logVersionDetectionCompleted(
        source: CodexExecutableSource,
        version: String
    ) {
        let details = LogFields.joined(
            "source=\(source.rawValue)",
            "version=\(version)"
        )
        AppLog.codex.notice("版本检测完成: \(details, privacy: .public)")
    }

    private static func failedVersionItem(
        source: CodexExecutableSource,
        path: String,
        failure: VersionProbeFailure
    ) -> CodexVersionItem {
        CodexVersionItem(source: source, path: path, errorMessage: failure.message)
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
                String(localized: "codex.version.launch-failed")
            case .timeout:
                String(localized: "codex.version.read-timeout")
            case .read:
                String(localized: "codex.version.read-failed")
            case .parse:
                String(localized: "codex.version.parse-failed")
            }
        }
    }
}

/// CodexBar 各能力依赖的 app-server 最低版本
nonisolated enum CodexMinimumVersion {
    static let account = "0.157.0"
    static let activity = "0.157.0"
}

/// 从 ` codex --version` 的输出中提取用户可读版本号
nonisolated enum CodexVersionReader {
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
            let displayVersion = CodexVersionReader.displayVersion(from: rawValue)
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

// 设置页持有的版本检测状态, 负责节流和丢弃过期刷新结果
