import Darwin
import Foundation

/// 可用于启动 app-server 的安装来源
nonisolated enum CodexCLIExecutableSource: String, Equatable {
    case global
    case bundled

    var displayName: String {
        switch self {
        case .global: "Codex CLI"
        case .bundled: "Codex APP"
        }
    }
}

/// 自动沿用 CLI 优先的解析规则, 手动选择只使用指定来源
nonisolated enum CodexCLISourceSelection: String, CaseIterable, Identifiable {
    case automatic
    case global
    case bundled

    var id: Self {
        self
    }

    var source: CodexCLIExecutableSource? {
        switch self {
        case .automatic: nil
        case .global: .global
        case .bundled: .bundled
        }
    }

    var title: String {
        source?.displayName ?? String(localized: "settings.codex-version.source.automatic")
    }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    private static let defaultsKey = "CodexCLI.sourceSelection"
}

/// 启动 app-server 所需的可执行文件和固定 stdio 参数
nonisolated struct AppServerCommand: Equatable {
    let source: CodexCLIExecutableSource
    let executablePath: String
    let arguments = ["app-server", "--listen", "stdio://"]
}

/// 当前已连接 app-server 的来源信息, 设置页用它标记`当前使用`
nonisolated struct CodexCLIConnectionInfo: Equatable {
    let source: CodexCLIExecutableSource
    let executablePath: String
    /// 来自 initialize 握手, 代表当前 app-server 进程真实运行的版本
    let version: String?
    let openedAt: Date
}

/// 一次 PATH 扫描得到的安装结果, 供启动和版本检测复用
nonisolated struct CodexCLIInstallations: Equatable {
    let globalPath: String?
    let bundledPath: String?

    // 与启动优先级一致: 全局优先, 回退内置
    var activeSource: CodexCLIExecutableSource? {
        if globalPath != nil {
            return .global
        }
        if bundledPath != nil {
            return .bundled
        }
        return nil
    }

    func path(for source: CodexCLIExecutableSource) -> String? {
        switch source {
        case .global: globalPath
        case .bundled: bundledPath
        }
    }
}

/// 解析真实用户环境下的 Codex 可执行文件, 避免使用 Xcode/container 的 HOME
nonisolated enum CodexCLIResolver {
    static let bundledExecutablePaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex"
    ]
    static let environment = appServerEnvironment()

    /// 从已解析的安装信息派生命令, 避免重复扫描 PATH
    static func command(
        from installations: CodexCLIInstallations,
        source: CodexCLIExecutableSource? = nil
    ) throws -> AppServerCommand {
        if let source, installations.path(for: source) == nil {
            throw CodexStatusError.sourceUnavailable(source)
        }
        guard let source = source ?? installations.activeSource,
              let path = installations.path(for: source) else {
            throw CodexStatusError.executableNotFound
        }

        return AppServerCommand(source: source, executablePath: path)
    }

    /// Codex 配置目录: 优先 CODEX_HOME, 回退真实用户 HOME 下的 .codex
    /// hooks.json 等配置文件统一从这里解析
    static func codexHomeDirectory(environment: [String: String] = environment) -> URL {
        if let codexHome = nonEmptyEnvironmentValue("CODEX_HOME", in: environment) {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }

        let home = nonEmptyEnvironmentValue("HOME", in: environment) ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static func nonEmptyEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func resolveInstallations(environment: [String: String] = environment) -> CodexCLIInstallations {
        let cliPath = findExecutable(named: "codex", environment: environment)
        let cliIsBundled = cliPath.map { path in
            bundledExecutablePaths.contains { pathsAreEquivalent(path, $0) }
        } ?? false

        let bundledPath = bundledExecutablePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? (cliIsBundled ? cliPath : nil)

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
            guard !component.isEmpty, seen.insert(component).inserted else {
                continue
            }

            components.append(component)
        }

        return components.joined(separator: ":")
    }

    private static func pathsAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    /// "两个路径是否指向同一文件"的统一口径, Hook 配置匹配也复用它
    static func canonicalPath(_ path: String, expandingTilde: Bool = false) -> String {
        let expandedPath = expandingTilde ? (path as NSString).expandingTildeInPath : path
        return URL(fileURLWithPath: expandedPath)
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
