import Combine
import Foundation

@MainActor
final class CodexHookSettings: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let hooksURL: URL
    private let fileManager: FileManager

    init(
        hooksURL: URL = CodexHookSettings.defaultHooksURL(),
        fileManager: FileManager = .default
    ) {
        self.hooksURL = hooksURL
        self.fileManager = fileManager
    }

    func refresh() {
        do {
            let config = try readConfigIfPresent()
            isEnabled = Self.containsCodexBarHooks(
                in: config,
                executablePath: currentExecutablePath
            )
            errorMessage = nil
        } catch {
            isEnabled = false
            errorMessage = "读取 Codex Hook 配置失败: \(error.localizedDescription)"
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            var config = try readConfigIfPresent()
            try Self.removeCodexBarHooks(
                from: &config,
                executablePath: currentExecutablePath
            )

            if enabled {
                try Self.installCodexBarHooks(
                    in: &config,
                    executablePath: currentExecutablePath
                )
            }

            try write(config)
            isEnabled = enabled
        } catch {
            refresh()
            errorMessage = "设置 Codex Hook 失败: \(error.localizedDescription)"
        }
    }
}

private extension CodexHookSettings {
    typealias JSONObject = [String: Any]
    typealias JSONArray = [Any]

    enum HookConfigError: LocalizedError {
        case invalidRoot
        case invalidHooks
        case invalidEvent(String)

        var errorDescription: String? {
            switch self {
            case .invalidRoot:
                return "hooks.json 顶层必须是 JSON 对象"
            case .invalidHooks:
                return "hooks 字段必须是 JSON 对象"
            case .invalidEvent(let event):
                return "\(event) 配置必须是数组"
            }
        }
    }

    static let codexBarEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PreCompact",
        "PostCompact",
        "Stop",
        "SubagentStart",
        "SubagentStop"
    ]

    nonisolated static func defaultHooksURL() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
    }

    var currentExecutablePath: String {
        Bundle.main.executableURL?.path
        ?? CommandLine.arguments.first
        ?? "/Applications/CodexBar.app/Contents/MacOS/CodexBar"
    }

    func readConfigIfPresent() throws -> JSONObject {
        guard fileManager.fileExists(atPath: hooksURL.path) else {
            return [:]
        }

        return try readConfig()
    }

    func readConfig() throws -> JSONObject {
        let data = try Data(contentsOf: hooksURL)
        guard !data.isEmpty else {
            return [:]
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let config = object as? JSONObject else {
            throw HookConfigError.invalidRoot
        }

        return config
    }

    func write(_ config: JSONObject) throws {
        try fileManager.createDirectory(
            at: hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: hooksURL, options: .atomic)
    }

    static func containsCodexBarHooks(in config: JSONObject, executablePath: String) -> Bool {
        guard let hooks = config["hooks"] as? JSONObject else {
            return false
        }

        return codexBarEvents.allSatisfy { event in
            guard let groups = hooks[event] as? JSONArray else {
                return false
            }

            return groups.contains { group in
                guard let group = group as? JSONObject,
                      let handlers = group["hooks"] as? JSONArray else {
                    return false
                }

                return handlers.contains {
                    isCurrentCodexBarHandler($0, event: event, executablePath: executablePath)
                }
            }
        }
    }

    static func installCodexBarHooks(in config: inout JSONObject, executablePath: String) throws {
        var hooks = try hooksObject(from: config)

        for event in codexBarEvents {
            var groups = try eventGroups(named: event, from: hooks)
            groups.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": hookCommand(for: event, executablePath: executablePath),
                        "timeout": 5
                    ]
                ]
            ])
            hooks[event] = groups
        }

        config["hooks"] = hooks
    }

    static func removeCodexBarHooks(
        from config: inout JSONObject,
        executablePath: String
    ) throws {
        guard config["hooks"] != nil else {
            return
        }

        var hooks = try hooksObject(from: config)

        for (event, value) in hooks {
            guard let groups = value as? JSONArray else {
                throw HookConfigError.invalidEvent(event)
            }

            let filteredGroups = groups.compactMap { group -> Any? in
                guard var groupObject = group as? JSONObject,
                      let handlers = groupObject["hooks"] as? JSONArray else {
                    return group
                }

                let filteredHandlers = handlers.filter {
                    !isCurrentCodexBarHandler(
                        $0,
                        event: event,
                        executablePath: executablePath
                    )
                }
                guard !filteredHandlers.isEmpty else {
                    return nil
                }

                groupObject["hooks"] = filteredHandlers
                return groupObject
            }

            if filteredGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = filteredGroups
            }
        }

        config["hooks"] = hooks
    }

    static func hooksObject(from config: JSONObject) throws -> JSONObject {
        guard let value = config["hooks"] else {
            return [:]
        }

        guard let hooks = value as? JSONObject else {
            throw HookConfigError.invalidHooks
        }

        return hooks
    }

    static func eventGroups(named event: String, from hooks: JSONObject) throws -> JSONArray {
        guard let value = hooks[event] else {
            return []
        }

        guard let groups = value as? JSONArray else {
            throw HookConfigError.invalidEvent(event)
        }

        return groups
    }

    static func isCurrentCodexBarHandler(
        _ handler: Any,
        event: String,
        executablePath: String
    ) -> Bool {
        commandIfCommandHandler(handler) == hookCommand(for: event, executablePath: executablePath)
    }

    // 仅当 handler 是 type == "command" 时返回其 command 字符串, 否则 nil
    private static func commandIfCommandHandler(_ handler: Any) -> String? {
        guard let handler = handler as? JSONObject,
              handler["type"] as? String == "command",
              let command = handler["command"] as? String else {
            return nil
        }

        return command
    }

    static func hookCommand(for event: String, executablePath: String) -> String {
        "\(shellQuoted(executablePath)) --hook-event \(event)"
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
