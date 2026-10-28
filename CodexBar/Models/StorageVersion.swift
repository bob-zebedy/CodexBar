import Foundation

/// 格式不支持与损坏分开传递, 调用方不得将版本错误转换为空数据
nonisolated enum StorageCompatibilityError: Error, Equatable {
    case unsupportedFormat(String, Int)
    case unsupportedAlgorithm(String, Int)
    case incompleteSource
}

nonisolated enum StorageVersion {
    private struct Header: Decodable { let schemaVersion: Int }

    static func validate(_ data: Data, current: Int, name: String) throws {
        try require(JSONDecoder().decode(Header.self, from: data).schemaVersion, current: current, name: name)
    }

    static func require(_ schemaVersion: Int, current: Int, name: String) throws {
        guard schemaVersion == current else { throw StorageCompatibilityError.unsupportedFormat(name, schemaVersion) }
    }
}

nonisolated enum AggregationVersion {
    static let activityData = 1
    static let tokenUsage = 1

    static func require(_ version: Int, current: Int, name: String) throws {
        guard version > 0, version <= current else { throw StorageCompatibilityError.unsupportedAlgorithm(name, version) }
    }
}
