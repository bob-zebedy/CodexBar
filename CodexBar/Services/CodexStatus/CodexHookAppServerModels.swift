import Foundation

/// config/read 的最小响应模型, 只解出 Hook 开关和信任状态
nonisolated struct CodexConfigReadResponse: Decodable {
    let config: CodexAppServerConfig

    var hooksGloballyDisabled: Bool {
        (config.features?.hooks ?? config.features?.codexHooks) == false
    }

    var hookTrustState: [String: String] {
        config.hooks?.state?.compactMapValues(\.trustedHash) ?? [:]
    }
}

/// Codex 用户配置根节点, 字段保持 optional 以兼容不同 Codex 版本
nonisolated struct CodexAppServerConfig: Decodable {
    let features: CodexAppServerFeatures?
    let hooks: CodexAppServerHooks?
}

/// Codex 新旧配置名可能同时存在, 读取时按 hooks 优先回退 codex_hooks
nonisolated struct CodexAppServerFeatures: Decodable {
    let hooks: Bool?
    let codexHooks: Bool?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case codexHooks = "codex_hooks"
    }
}

/// hooks.state 里保存 hook key 到 trusted_hash 的映射
nonisolated struct CodexAppServerHooks: Decodable {
    let state: [String: CodexHookTrustState]?
}

nonisolated struct CodexHookTrustState: Decodable {
    let trustedHash: String?

    private enum CodingKeys: String, CodingKey {
        case trustedHash = "trusted_hash"
    }
}

/// config/batchWrite 的单条编辑, 直接转成 app-server 期望的 JSON 对象
nonisolated struct CodexConfigBatchEdit {
    let keyPath: String
    let value: [String: [String: String]]
    let mergeStrategy: String

    var appServerObject: [String: Any] {
        [
            "keyPath": keyPath,
            "value": value,
            "mergeStrategy": mergeStrategy
        ]
    }
}

nonisolated struct CodexConfigWriteResponse: Decodable {}

/// hooks/list 的响应列表按 cwd 分组
nonisolated struct CodexHooksListResponse: Decodable {
    let data: [CodexHooksListEntry]
}

/// 单个 cwd 下 Codex 解析出的 Hook 状态
nonisolated struct CodexHooksListEntry: Decodable {
    let cwd: String
    let hooks: [CodexHookMetadata]
    let warnings: [String]
    let errors: [CodexHookErrorInfo]
}

/// hooks/list 返回的单个 Hook 元数据, key/currentHash 用于自动写入信任状态
nonisolated struct CodexHookMetadata: Decodable {
    let eventName: String
    let command: String?
    let enabled: Bool
    let sourcePath: String
    let trustStatus: String
    let key: String?
    let currentHash: String?
}

nonisolated struct CodexHookErrorInfo: Decodable {
    let path: String
    let message: String
}
