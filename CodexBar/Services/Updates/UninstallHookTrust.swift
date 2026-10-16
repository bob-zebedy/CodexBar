import Foundation

/// 只使用用户配置层, 避免把项目或系统配置合并回 config.toml
nonisolated struct UninstallHookTrustConfig: Decodable, Sendable {
    let layers: [Layer]

    nonisolated struct Layer: Decodable, Sendable {
        let name: Source
        let version: String
        let config: Config
        let disabledReason: String?
    }

    nonisolated struct Source: Decodable, Sendable {
        let type: String
        let file: String?
        let profile: String?
    }

    nonisolated struct Config: Decodable, Sendable {
        let hooks: Hooks?
    }

    nonisolated struct Hooks: Decodable, Sendable {
        let state: [String: Value]?
    }

    func userLayer(at url: URL) throws -> Layer {
        let matches = layers.filter {
            $0.name.type == "user" && $0.name.profile == nil && $0.name.file.map {
                URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.resolvingSymlinksInPath()
            } == true
        }
        guard matches.count == 1, let layer = matches.first, layer.disabledReason == nil, !layer.version.isEmpty else {
            throw AppUninstallError("无法确认 Codex 用户配置及其版本")
        }
        return layer
    }

    func writeParameters(state: [String: Value], configURL: URL) throws -> [String: Any] {
        let layer = try userLayer(at: configURL)
        return [
            "filePath": configURL.path,
            "expectedVersion": layer.version,
            "reloadUserConfig": true,
            "edits": [["keyPath": "hooks.state", "value": state.mapValues(\.object), "mergeStrategy": "replace"]]
        ]
    }

    /// 保留其他 Hook 的完整记录, 包括当前 App 不认识的字段
    indirect nonisolated enum Value: Codable, Equatable, Sendable {
        case dictionary([String: Value])
        case array([Value])
        case string(String)
        case number(Decimal)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .number(value)
            } else if let value = try? container.decode([Value].self) {
                self = .array(value)
            } else {
                self = try .dictionary(container.decode([String: Value].self))
            }
        }

        var object: Any {
            switch self {
            case let .dictionary(value): value.mapValues(\.object)
            case let .array(value): value.map(\.object)
            case let .string(value): value
            case let .number(value): NSDecimalNumber(decimal: value)
            case let .bool(value): value
            case .null: NSNull()
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .dictionary(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .bool(value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }
}

protocol UninstallHookClient: Sendable {
    func listHooks() async throws -> CodexHooksListResponse
    func readConfig() async throws -> UninstallHookTrustConfig
    func writeState(_ state: [String: UninstallHookTrustConfig.Value], replacing config: UninstallHookTrustConfig, at url: URL) async throws
}

/// 卸载仅访问本机配置, 不初始化账户或复用代理认证设置
actor UninstallCodexClient: UninstallHookClient {
    private let selection: CodexCLISourceSelection
    private let environment: [String: String]
    private var session: AppServerSession?

    init(selection: CodexCLISourceSelection, environment: [String: String] = CodexCLIResolver.environment) {
        self.selection = selection
        self.environment = environment
    }

    private func connectedSession() throws -> AppServerSession {
        if let session {
            return session
        }
        signal(SIGPIPE, SIG_IGN)
        let command = try CodexCLIResolver.command(
            from: CodexCLIResolver.resolveInstallations(environment: environment), source: selection.source
        )
        let opened = try AppServerSession.launch(command: command, environment: environment, timeout: 10, deadline: Date().addingTimeInterval(90))
        do {
            _ = try opened.initialize(minimumVersion: CodexCLIMinimumVersion.advancedMode)
        } catch {
            opened.close()
            throw error
        }
        session = opened
        return opened
    }

    func listHooks() throws -> CodexHooksListResponse {
        try connectedSession().request(
            "hooks/list", params: ["cwds": [CodexCLIResolver.codexHomeDirectory(environment: environment).path]], as: CodexHooksListResponse.self
        )
    }

    func readConfig() throws -> UninstallHookTrustConfig {
        try connectedSession().request("config/read", params: ["includeLayers": true], as: UninstallHookTrustConfig.self)
    }

    func writeState(_ state: [String: UninstallHookTrustConfig.Value], replacing config: UninstallHookTrustConfig, at url: URL) throws {
        _ = try connectedSession().request(
            "config/batchWrite", params: config.writeParameters(state: state, configURL: url), as: CodexConfigWriteResponse.self
        )
    }

    func close() {
        session?.close()
        session = nil
    }
}
