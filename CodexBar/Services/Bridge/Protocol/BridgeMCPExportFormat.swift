import Foundation

nonisolated enum BridgeMCPExportFormat: CaseIterable, Hashable, Sendable {
    case claudeCLI, claudeDesktop, codex, cursor, copilot, antigravity, hermes, kiro, openClaw, openCode, qoder, genericJSON

    var title: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Google Antigravity"
        case .hermes: "Hermes Agent"
        case .kiro: "Kiro"
        case .openClaw: "OpenClaw"
        case .openCode: "OpenCode"
        case .qoder: "Qoder"
        case .genericJSON: String(localized: "bridge.export.generic-json")
        }
    }

    var defaultFilePath: String? {
        switch self {
        case .claudeCLI: "~/.claude.json"
        case .claudeDesktop: "~/Library/Application Support/Claude/claude_desktop_config.json"
        case .codex: "~/.codex/config.toml"
        case .cursor: "~/.cursor/mcp.json"
        case .copilot: "~/.copilot/mcp-config.json"
        case .antigravity: "~/.gemini/config/mcp_config.json"
        case .hermes: "~/.hermes/config.yaml"
        case .kiro: "~/.kiro/settings/mcp.json"
        case .openClaw: "~/.openclaw/openclaw.json"
        case .openCode: "~/.config/opencode/opencode.jsonc"
        case .qoder: "~/.qoder/settings.json"
        case .genericJSON: nil
        }
    }

    func render(command: String, token: String) throws -> String {
        let serverName = "codex"
        let env: BridgeJSON = ["CODEXBAR_BRIDGE_TOKEN": .string(token)]
        var server: [String: BridgeJSON] = ["command": .string(command), "args": ["--mcp"], "env": env]
        let config: BridgeJSON
        switch self {
        case .codex:
            return try """
            [mcp_servers.\(serverName)]
            command = \(Self.quotedString(command))
            args = ["--mcp"]

            [mcp_servers.\(serverName).env]
            CODEXBAR_BRIDGE_TOKEN = \(Self.quotedString(token))
            """
        case .hermes:
            return try """
            mcp_servers:
              \(serverName):
                command: \(Self.quotedString(command))
                args: ["--mcp"]
                env:
                  CODEXBAR_BRIDGE_TOKEN: \(Self.quotedString(token))
            """
        case .openClaw:
            config = ["mcp": ["servers": [serverName: .object(server)]]]
        case .openCode:
            config = ["mcp": ["servers": [serverName: ["type": "local", "command": [.string(command), "--mcp"], "environment": env]]]]
        case .copilot:
            server["type"] = "stdio"
            server["tools"] = ["*"]
            config = ["mcpServers": [serverName: .object(server)]]
        case .claudeCLI, .claudeDesktop, .cursor, .antigravity, .kiro, .qoder, .genericJSON:
            config = ["mcpServers": [serverName: .object(server)]]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let text = try String(data: encoder.encode(config), encoding: .utf8) else { throw BridgeFailure("invalid_json") }
        return text
    }

    private static func quotedString(_ value: String) throws -> String {
        // YAML 解析器可能拒绝控制字符或将部分 Unicode 换行符折叠为空格
        try BridgeJSON.string(value).jsonText().unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar.value {
            case 0x7F ... 0x9F, 0x2028, 0x2029, 0xFFFE, 0xFFFF:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
    }
}
