import Darwin
import Foundation

/// 用于展示已安装版本的来源
nonisolated enum CodexExecutableSource: String, Equatable {
    case global
    case bundled

    var displayName: String {
        switch self {
        case .global: "Codex CLI"
        case .bundled: "Codex App"
        }
    }
}

/// 当前 Codex 后台服务的握手信息, 不将安装路径误作服务运行来源
nonisolated struct CodexServerConnectionInfo: Equatable {
    let socketPath: String
    /// 来自 initialize 握手, 代表当前 app-server 进程真实运行的版本
    let version: String?
    let openedAt: Date
}

/// 一次 PATH 扫描得到的安装结果, 供版本检测使用
nonisolated struct CodexInstallations: Equatable {
    let globalPath: String?
    let bundledPath: String?
}

/// 解析真实用户环境下的 Codex 可执行文件, 避免使用 Xcode/container 的 HOME
nonisolated enum CodexPaths {
    static let bundledResourceURL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources", isDirectory: true)
    static let environment = resolvedEnvironment()

    private struct PackageManifest: Decodable {
        let entrypoint: String
    }

    /// Codex 配置目录: 优先 CODEX_HOME, 回退真实用户 HOME 下的 .codex
    /// Codex 后台服务 socket 位置统一从这里解析
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

    static func resolveInstallations(
        environment: [String: String] = environment,
        bundledResourceURL: URL = bundledResourceURL
    ) -> CodexInstallations {
        let bundledExecutablePaths = [
            packageExecutablePath(in: bundledResourceURL),
            bundledResourceURL.appendingPathComponent("codex").path
        ].compactMap(\.self)
        let cliPath = findExecutable(named: "codex", environment: environment)
        let cliIsBundled = cliPath.map { path in
            bundledExecutablePaths.contains { pathsAreEquivalent(path, $0) }
        } ?? false

        let bundledPath = bundledExecutablePaths.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? (cliIsBundled ? cliPath : nil)

        return CodexInstallations(
            globalPath: cliIsBundled ? nil : cliPath,
            bundledPath: bundledPath
        )
    }

    private static func packageExecutablePath(in resources: URL) -> String? {
        let packageDirectory = resources.appendingPathComponent("codex-cli", isDirectory: true)
        let manifestURL = packageDirectory.appendingPathComponent("codex-package.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data),
              !manifest.entrypoint.isEmpty else {
            return nil
        }
        return packageDirectory.appendingPathComponent(manifest.entrypoint).path
    }

    private static func resolvedEnvironment() -> [String: String] {
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

    /// "两个路径是否指向同一文件"的统一口径
    static func canonicalPath(_ path: String) -> String {
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
