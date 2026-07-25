import Foundation

/// 简单 JSONL 工具, 读取时跳过坏行以保护历史统计可用性
nonisolated enum JSONLines {
    static let newlineByte: UInt8 = 0x0A

    /// RFC 8259 允许出现在值前后的空白, 用于识别只含空白的空行
    private static let jsonWhitespaceBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

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

    /// 按行解码 JSONL: 切分换行, 跳过空行与解码失败的行
    static func decode<T: Decodable>(_ type: T.Type = T.self, from data: Data) -> [T] {
        decodeWithFailures(type, from: data).values
    }

    static func decodeWithFailures<T: Decodable>(
        _: T.Type = T.self,
        from data: Data
    ) -> JSONLinesDecodeResult<T> {
        let decoder = JSONDecoder()
        var values = [T]()
        var failedLineCount = 0

        // 逐行独立解码: 进程被杀或断电会留下截断的多字节序列
        // 整块处理时一处损坏会连带丢掉同一次读取里的所有完好事件, 且调用方仍会推进 offset
        // 直接把字节切片交给 JSONDecoder: 它自己跳过首尾空白并拒收非法 UTF-8,
        // 省掉每行 String 转换 + trim + 再编码回 Data 的三次拷贝 (单次读取可达上万行)
        for line in data.split(separator: newlineByte) {
            guard line.contains(where: { !Self.jsonWhitespaceBytes.contains($0) }) else {
                continue
            }
            guard let value = try? decoder.decode(T.self, from: Data(line)) else {
                failedLineCount += 1
                continue
            }

            values.append(value)
        }

        return JSONLinesDecodeResult(values: values, failedLineCount: failedLineCount)
    }
}

/// 解码结果同时返回坏行数量, 维护流程据此触发重建
nonisolated struct JSONLinesDecodeResult<T> {
    let values: [T]
    let failedLineCount: Int
}
