import Foundation

/// 格式不支持与损坏分开传递, 调用方不得将版本错误转换为空数据
nonisolated enum StorageCompatibilityError: Error, Equatable {
    case unsupportedFormat(String, Int)
    case unsupportedAlgorithm(String, Int)
    case incompleteSource
    case sourceConflict
}

nonisolated enum StorageVersion {
    private struct Header: Decodable { let version: Int }

    static func validate(_ data: Data, current: Int, name: String) throws {
        try require(JSONDecoder().decode(Header.self, from: data).version, current: current, name: name)
    }

    static func require(_ version: Int, current: Int, name: String) throws {
        guard version == current else { throw StorageCompatibilityError.unsupportedFormat(name, version) }
    }

    static func validateExistingFile(at url: URL, current: Int, name: String) throws {
        do {
            try validate(Data(contentsOf: url), current: current, name: name)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return
        }
    }
}

nonisolated enum AggregationVersion {
    static let activity = 1
    static let tokens = 1

    static func require(_ version: Int, current: Int, name: String) throws {
        guard version > 0, version <= current else { throw StorageCompatibilityError.unsupportedAlgorithm(name, version) }
    }
}

/// 每段以排他的源边界结束, 连续使用同一算法时只扩展末段
nonisolated struct AggregationRange: Codable, Equatable {
    var version: Int
    var end: UInt64

    static func appending(to ranges: [Self], version: Int, end: UInt64) -> [Self] {
        var result = ranges
        if result.last?.version == version {
            result[result.count - 1].end = end
        } else {
            result.append(Self(version: version, end: end))
        }
        return result
    }

    static func validate(_ ranges: [Self], end: UInt64, current: Int) throws {
        var previous: UInt64 = 0
        for range in ranges {
            try AggregationVersion.require(range.version, current: current, name: "AggregationRange")
            guard range.end > previous, range.end <= end else { throw StorageCompatibilityError.incompleteSource }
            previous = range.end
        }
        guard ranges.isEmpty || previous == end else { throw StorageCompatibilityError.incompleteSource }
    }
}
