import Foundation

/// 代理配置和密码作为一条本机偏好保存, 不参与云同步
nonisolated enum CodexProxyStore {
    private static let configurationKey = "CodexProxy.configuration"

    struct StoredConfiguration: Codable {
        let configuration: CodexProxyConfiguration
        let password: String
    }

    static func containsConfiguration(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: configurationKey) != nil
    }

    static func save(_ configuration: CodexProxyConfiguration?, password: String, to defaults: UserDefaults) throws {
        guard let configuration else {
            defaults.removeObject(forKey: configurationKey)
            return
        }
        // 停用时保留原始字段, 无效配置也必须能够关闭
        let stored = try StoredConfiguration(
            configuration: configuration.isEnabled ? configuration.validated() : configuration,
            password: configuration.usesAuthentication ? password : ""
        )
        try defaults.set(JSONEncoder().encode(stored), forKey: configurationKey)
    }

    static func load(from defaults: UserDefaults) throws -> StoredConfiguration? {
        guard containsConfiguration(in: defaults) else { return nil }
        guard let data = defaults.data(forKey: configurationKey),
              let stored = try? JSONDecoder().decode(StoredConfiguration.self, from: data) else {
            throw CodexProxyError.invalidStoredConfiguration
        }
        // 读取时保留原始输入, 让设置窗口能够回填并修正无效配置
        return StoredConfiguration(
            configuration: stored.configuration,
            password: stored.configuration.usesAuthentication ? stored.password : ""
        )
    }
}
