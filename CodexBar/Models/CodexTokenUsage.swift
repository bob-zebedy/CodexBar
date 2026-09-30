import Foundation

nonisolated struct CodexTokenUsage: Codable, Equatable {
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let totalTokens: Int64

    var cacheHitRate: Double? {
        inputTokens > 0 ? Double(cachedInputTokens) / Double(inputTokens) : nil
    }

    var isValid: Bool {
        let inputAndOutput = inputTokens.addingReportingOverflow(outputTokens)
        let cachedAndWritten = cachedInputTokens.addingReportingOverflow(cacheWriteInputTokens)
        return inputTokens >= 0 && cachedInputTokens >= 0 && cacheWriteInputTokens >= 0
            && outputTokens >= 0 && reasoningOutputTokens >= 0 && totalTokens >= 0
            && !inputAndOutput.overflow && inputAndOutput.partialValue == totalTokens
            && !cachedAndWritten.overflow && cachedAndWritten.partialValue <= inputTokens
            && reasoningOutputTokens <= outputTokens
    }

    func adding(_ other: Self) -> Self? {
        let sums = zip(values, other.values).map { $0.addingReportingOverflow($1) }
        guard !sums.contains(where: \.overflow) else { return nil }
        return Self(
            inputTokens: sums[0].partialValue, cachedInputTokens: sums[1].partialValue,
            cacheWriteInputTokens: sums[2].partialValue, outputTokens: sums[3].partialValue,
            reasoningOutputTokens: sums[4].partialValue, totalTokens: sums[5].partialValue
        )
    }

    private var values: [Int64] {
        [inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, totalTokens]
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

/// 终态读取可能从文件尾部开始, 使用明确归属的轮次累计值避免漏算前面的响应
nonisolated struct CodexRolloutTokenUsageRecord: Decodable {
    let payload: CodexRolloutTokenUsagePayload
}

nonisolated struct CodexRolloutTokenUsagePayload: Decodable {
    let threadID: String
    let sessionID: String
    let turnID: String
    let rootTurnID: String
    let responseID: String
    let turnTokenUsage: CodexTokenUsage

    private enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case rootTurnID = "root_turn_id"
        case responseID = "response_id"
        case turnTokenUsage = "turn_token_usage"
    }
}
