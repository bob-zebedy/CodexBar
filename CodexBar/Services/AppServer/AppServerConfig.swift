import Foundation

/// config/read 的最小响应模型, 只解出 TUI 通知相关状态
nonisolated struct ConfigReadResponse: Decodable {
    let config: AppServerConfig

    var areTUINotificationsEnabled: Bool {
        config.tui?.notifications?.isEnabled ?? true
    }
}

/// Codex 用户配置根节点, 字段保持 optional 以兼容不同 Codex 版本
nonisolated struct AppServerConfig: Decodable {
    let tui: AppServerTUI?
}

/// tui.notifications 支持布尔值或事件名数组; 空数组等价于不发送通知
nonisolated struct AppServerTUI: Decodable {
    let notifications: AppServerTUINotifications?
}

nonisolated enum AppServerTUINotifications: Decodable {
    case boolean(Bool)
    case events([String])

    var isEnabled: Bool {
        switch self {
        case let .boolean(isEnabled):
            isEnabled
        case let .events(events):
            !events.isEmpty
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let isEnabled = try? container.decode(Bool.self) {
            self = .boolean(isEnabled)
            return
        }

        self = try .events(container.decode([String].self))
    }
}

/// config/batchWrite 的单条编辑, 直接转成 app-server 期望的 JSON 对象
nonisolated struct ConfigBatchEdit: Sendable {
    let keyPath: String
    let mergeStrategy: String

    private let value: Bool

    init(
        keyPath: String,
        value: Bool,
        mergeStrategy: String
    ) {
        self.keyPath = keyPath
        self.value = value
        self.mergeStrategy = mergeStrategy
    }

    var appServerObject: [String: Any] {
        [
            "keyPath": keyPath,
            "value": value,
            "mergeStrategy": mergeStrategy
        ]
    }
}

nonisolated struct ConfigWriteResponse: Decodable {}
