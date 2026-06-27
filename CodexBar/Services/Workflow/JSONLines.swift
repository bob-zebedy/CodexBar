import Foundation

/// 简单 JSONL 工具, 读取时跳过坏行以保护历史统计可用性
nonisolated enum JSONLines {
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
