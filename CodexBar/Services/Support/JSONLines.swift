import Foundation

/// 落盘 JSON 与事件行共用的序列化配置
nonisolated enum JSONLines {
    static let newlineByte: UInt8 = 0x0A

    /// 落盘 JSON 统一的稳定输出配置, 保证文件可 diff 且格式一致
    /// 配置后不再修改, encode 可重入, 可跨并发域缓存共享
    static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
            guard let timestamp = Int64(exactly: milliseconds) else {
                throw EncodingError.invalidValue(date, .init(codingPath: encoder.codingPath, debugDescription: "Invalid millisecond timestamp"))
            }
            var container = encoder.singleValueContainer()
            try container.encode(timestamp)
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let timestamp = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(timestamp) / 1000)
        }
        return decoder
    }()

    /// 内存快照与落盘精度一致, 避免重建标记在重新读取后被误判为更旧
    static func storageDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}
