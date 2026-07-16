import Foundation

/// 简单 JSONL 工具, 读取时跳过坏行以保护历史统计可用性
nonisolated enum JSONLines {
    static let newlineByte: UInt8 = 0x0A

    /// 落盘 JSON 统一的稳定输出配置, 保证文件可 diff 且格式一致
    /// 配置后不再修改, encode 可重入, 可跨并发域缓存共享
    static let stableEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// 从文件中部 seek 读取时首行必然残缺: 丢弃首个换行(含)之前的内容
    /// 找不到换行时原样返回, 交给按行解码当坏行跳过
    static func droppingLeadingPartialLine(_ data: Data) -> Data {
        guard let firstNewlineIndex = data.firstIndex(of: newlineByte) else {
            return data
        }

        let firstCompleteIndex = data.index(after: firstNewlineIndex)
        return firstCompleteIndex < data.endIndex ? Data(data[firstCompleteIndex...]) : Data()
    }

    /// 按行解码 JSONL: 切分换行, trim, 跳过空行与解码失败的行
    static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) -> [T] {
        decodeWithFailures(type, from: data).values
    }

    static func decodeWithFailures<T: Decodable>(
        _: T.Type = T.self,
        from data: Data
    ) -> JSONLinesDecodeResult<T> {
        guard let text = String(bytes: data, encoding: .utf8) else {
            return JSONLinesDecodeResult(values: [], failedLineCount: data.isEmpty ? 0 : 1)
        }

        let decoder = JSONDecoder()
        var failedLineCount = 0

        let values = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> T? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty, let lineData = trimmedLine.data(using: .utf8) else {
                    return nil
                }

                if let value = try? decoder.decode(T.self, from: lineData) {
                    return value
                }

                failedLineCount += 1
                return nil
            }

        return JSONLinesDecodeResult(values: values, failedLineCount: failedLineCount)
    }
}

/// 解码结果同时返回坏行数量, 维护流程据此触发重建
nonisolated struct JSONLinesDecodeResult<T> {
    let values: [T]
    let failedLineCount: Int
}
