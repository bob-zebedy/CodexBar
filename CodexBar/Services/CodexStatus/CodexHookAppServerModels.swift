import Foundation

nonisolated struct CodexConfigReadResponse: Decodable {
    let config: CodexAppServerConfig

    var hooksGloballyDisabled: Bool {
        guard let features = config.features else {
            return false
        }

        return (features.hooks ?? features.codexHooks) == false
    }
}

nonisolated struct CodexAppServerConfig: Decodable {
    let features: CodexAppServerFeatures?
}

nonisolated struct CodexAppServerFeatures: Decodable {
    let hooks: Bool?
    let codexHooks: Bool?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case codexHooks = "codex_hooks"
    }
}

nonisolated struct CodexHooksListResponse: Decodable {
    let data: [CodexHooksListEntry]
}

nonisolated struct CodexHooksListEntry: Decodable {
    let cwd: String
    let hooks: [CodexHookMetadata]
    let warnings: [String]
    let errors: [CodexHookErrorInfo]
}

nonisolated struct CodexHookMetadata: Decodable {
    let eventName: String
    let command: String?
    let enabled: Bool
    let sourcePath: String
    let trustStatus: String
}

nonisolated struct CodexHookErrorInfo: Decodable {
    let path: String
    let message: String
}
