nonisolated struct TokenUsage: Codable, Equatable {
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

    static let zero = Self(inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)

    func subtracting(_ other: Self) -> Self? {
        guard isValid, other.isValid else { return nil }
        let differences = zip(values, other.values).map { $0.subtractingReportingOverflow($1) }
        guard !differences.contains(where: { $0.overflow || $0.partialValue < 0 }) else { return nil }
        let result = Self(
            inputTokens: differences[0].partialValue, cachedInputTokens: differences[1].partialValue,
            cacheWriteInputTokens: differences[2].partialValue, outputTokens: differences[3].partialValue,
            reasoningOutputTokens: differences[4].partialValue, totalTokens: differences[5].partialValue
        )
        return result.isValid ? result : nil
    }

    private var values: [Int64] {
        [inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens, totalTokens]
    }
}
