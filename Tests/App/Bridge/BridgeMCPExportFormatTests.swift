import Foundation
import Testing

struct BridgeMCPExportFormatTests {
    @Test func offersTheSupportedConfigurationFormatsInOrder() {
        let formats = BridgeMCPExportFormat.allCases
        let titles = formats.dropLast().map(\.title)
        #expect(titles == ["Claude CLI", "Claude Desktop", "Codex", "Cursor", "GitHub Copilot", "Google Antigravity", "Hermes Agent", "Kiro", "OpenClaw", "OpenCode", "Qoder"])
        #expect(formats.last == .genericJSON)
    }

    @Test func showsWhereToAddEachConfiguration() {
        #expect(BridgeMCPExportFormat.claudeCLI.defaultFilePath == "~/.claude.json")
        #expect(BridgeMCPExportFormat.antigravity.defaultFilePath == "~/.gemini/config/mcp_config.json")
        #expect(BridgeMCPExportFormat.hermes.defaultFilePath == "~/.hermes/config.yaml")
        #expect(BridgeMCPExportFormat.kiro.defaultFilePath == "~/.kiro/settings/mcp.json")
        #expect(BridgeMCPExportFormat.openClaw.defaultFilePath == "~/.openclaw/openclaw.json")
        #expect(BridgeMCPExportFormat.qoder.defaultFilePath == "~/.qoder/settings.json")
        #expect(BridgeMCPExportFormat.genericJSON.defaultFilePath == nil)
        #expect(BridgeMCPExportFormat.allCases.filter { $0 != .genericJSON }.allSatisfy { $0.defaultFilePath?.hasPrefix("~/") == true })
    }

    @Test(arguments: BridgeMCPExportFormat.allCases)
    func exportsLocalServerWithItsOriginalArguments(format: BridgeMCPExportFormat) throws {
        let command = #"/tmp/我的 "CodexBar" : \Debug.app/Contents/MacOS/CodexBar"#
        let token = "clientFixtureToken123"
        let text = try format.render(command: command, token: token)
        if format == .codex {
            #expect(text.contains(#"command = "/tmp/我的 \"CodexBar\" : \\Debug.app/Contents/MacOS/CodexBar""#))
            #expect(text.contains("[mcp_servers.codex.env]"))
            #expect(text.contains("CODEXBAR_BRIDGE_TOKEN = \"\(token)\""))
            return
        }
        if format == .hermes {
            #expect(text == #"""
            mcp_servers:
              codex:
                command: "/tmp/我的 \"CodexBar\" : \\Debug.app/Contents/MacOS/CodexBar"
                args: ["--mcp"]
                env:
                  CODEXBAR_BRIDGE_TOKEN: "\#(token)"
            """#)
            return
        }
        let json = try JSONDecoder().decode(BridgeJSON.self, from: Data(text.utf8))
        if format == .openCode {
            let server = json["mcp"]["servers"]["codex"]
            #expect(server["command"] == [.string(command), "--mcp"])
            #expect(server["environment"]["CODEXBAR_BRIDGE_TOKEN"] == .string(token))
            #expect(server["type"] == "local")
            return
        }
        let server = format == .openClaw ? json["mcp"]["servers"]["codex"] : json["mcpServers"]["codex"]
        #expect(server["command"] == .string(command))
        #expect(server["args"] == ["--mcp"])
        #expect(server["env"]["CODEXBAR_BRIDGE_TOKEN"] == .string(token))
        if format == .copilot {
            #expect(server["type"] == "stdio")
            #expect(server["tools"] == ["*"])
        }
    }

    @Test func hermesPreservesUnicodeLineBreaksAndStringTokens() throws {
        let text = try BridgeMCPExportFormat.hermes.render(command: "/tmp/\u{85}\u{2028}\u{2029}CodexBar", token: "true")
        #expect(text.contains(#"command: "/tmp/\u0085\u2028\u2029CodexBar""#))
        #expect(text.contains(#"CODEXBAR_BRIDGE_TOKEN: "true""#))
    }
}
