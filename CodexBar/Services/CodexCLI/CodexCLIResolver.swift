import Darwin
import Foundation

nonisolated enum CodexCLIExecutableSource: String, Sendable, Equatable {
    case global
    case bundled

    var displayName: String {
        switch self {
        case .global: return "Codex CLI"
        case .bundled: return "Codex APP"
        }
    }
}

nonisolated struct AppServerCommand: Sendable, Equatable {
    let source: CodexCLIExecutableSource
    let executablePath: String
    let arguments = ["app-server", "--listen", "stdio://"]
}

nonisolated struct CodexCLIConnectionInfo: Sendable, Equatable {
    let source: CodexCLIExecutableSource
    let executablePath: String
    // 来自 initialize 握手, 代表当前 app-server 进程真实运行的版本
    let version: String?
    let openedAt: Date
}

nonisolated struct CodexCLIInstallations: Sendable, Equatable {
    let globalPath: String?
    let bundledPath: String?

    // 与启动优先级一致: 全局优先, 回退内置
    var activeSource: CodexCLIExecutableSource? {
        if globalPath != nil { return .global }
        if bundledPath != nil { return .bundled }
        return nil
    }

    func path(for source: CodexCLIExecutableSource) -> String? {
        switch source {
        case .global: return globalPath
        case .bundled: return bundledPath
        }
    }
}

nonisolated enum CodexCLIResolver {
    static let bundledExecutablePath = "/Applications/Codex.app/Contents/Resources/codex"
    static let environment = appServerEnvironment()

    static func resolveAppServerCommand(environment: [String: String] = environment) throws -> AppServerCommand {
        try command(from: resolveInstallations(environment: environment))
    }

    // 从已解析的安装信息派生命令, 避免重复扫描 PATH
    static func command(from installations: CodexCLIInstallations) throws -> AppServerCommand {
        guard let source = installations.activeSource,
              let path = installations.path(for: source) else {
            throw CodexStatusError.executableNotFound
        }

        return AppServerCommand(source: source, executablePath: path)
    }

    static func resolveInstallations(environment: [String: String] = environment) -> CodexCLIInstallations {
        let cliPath = findExecutable(named: "codex", environment: environment)
        let cliIsBundled = cliPath.map { pathsAreEquivalent($0, bundledExecutablePath) } ?? false

        let bundledPath: String?
        if FileManager.default.isExecutableFile(atPath: bundledExecutablePath) {
            bundledPath = bundledExecutablePath
        } else {
            bundledPath = cliIsBundled ? cliPath : nil
        }

        return CodexCLIInstallations(
            globalPath: cliIsBundled ? nil : cliPath,
            bundledPath: bundledPath
        )
    }

    private static func appServerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDirectory = realUserHomeDirectory()
        let path = environment["PATH"] ?? ""
        // 菜单栏应用通常拿不到用户 shell PATH, 需要补上常见 CLI 安装目录
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

    private static func findExecutable(
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

    private static func mergedPath(_ path: String, fallbackPaths: [String]) -> String {
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

    private static func pathsAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func realUserHomeDirectory() -> String {
        guard let passwd = getpwuid(getuid()),
              let home = passwd.pointee.pw_dir else {
            return NSHomeDirectory()
        }

        return String(cString: home)
    }
}
