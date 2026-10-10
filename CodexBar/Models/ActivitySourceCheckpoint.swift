import CryptoKit
import Foundation

/// 检查点描述原始日志前缀, 不使用统计计数判断来源覆盖
nonisolated struct ActivitySourceCheckpoint: Codable, Equatable {
    let byteCount: UInt64
    let digest: String
    var aggregationRanges: [AggregationRange] = []

    private enum CodingKeys: String, CodingKey { case byteCount, digest, aggregationRanges }

    init(byteCount: UInt64, digest: String) {
        self.byteCount = byteCount
        self.digest = digest
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        byteCount = try values.decode(UInt64.self, forKey: .byteCount)
        digest = try values.decode(String.self, forKey: .digest)
        aggregationRanges = try values.decodeIfPresent([AggregationRange].self, forKey: .aggregationRanges) ?? []
        try AggregationRange.validate(aggregationRanges, end: byteCount, current: AggregationVersion.activity)
        guard byteCount > 0, digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw StorageCompatibilityError.incompleteSource
        }
    }

    func matchesSource(_ other: Self?) -> Bool {
        guard let other else { return false }
        return byteCount == other.byteCount && digest == other.digest
    }

    static func read(at url: URL, byteCount: UInt64) throws -> Self {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var remaining = byteCount
        var hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty else {
                throw StorageCompatibilityError.incompleteSource
            }
            hash.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        return Self(byteCount: byteCount, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
