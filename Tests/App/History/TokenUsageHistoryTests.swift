import Foundation
import Testing

@Suite(.tags(.integration))
struct TokenUsageHistoryTests {
    private let day = HistoryStorage.dateKey(for: TestFixtures.now)
    @Test func cachedTokenUsageFileChecksBytesAcrossExternalWritesAndDeletion() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.json")
        var first = TokenUsageFileCache<[String: Int]>(url: url)
        var second = TokenUsageFileCache<[String: Int]>(url: url)
        try first.save(["cursor": 1])
        #expect(try first.load() == ["cursor": 1])
        #expect(try second.load() == ["cursor": 1])
        let initial = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try first.save(["cursor": 1])
        #expect(try (url.resourceValues(forKeys: [.fileSizeKey])).fileSize == initial.fileSize)
        let modifiedAt = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        try Data("{\"cursor\":2}".utf8).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        #expect(try url.resourceValues(forKeys: [.fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey]).fileSize == initial.fileSize)
        #expect(try first.load() == ["cursor": 2])
        #expect(try second.load() == ["cursor": 2])
        try second.save(["cursor": 3])
        #expect(try first.load() == ["cursor": 3])
        // 内存命中不能跳过另一进程修改后的保存检查点
        try second.save(["cursor": 4])
        try first.save(["cursor": 3])
        #expect(try second.load() == ["cursor": 3])
        try Data("invalid".utf8).write(to: url)
        #expect(throws: (any Error).self) { try first.load() }
        try FileManager.default.removeItem(at: url)
        #expect(try first.load() == nil)
        try first.save(["cursor": 3])
        #expect(try second.load() == ["cursor": 3])
    }

    private func tokenUsage(input: Int64, cached: Int64 = 20) -> TokenUsage {
        TokenUsage(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 5, outputTokens: 10, reasoningOutputTokens: 2, totalTokens: input + 10)
    }

    @Test func dailyAggregatesPreserveCountersAndRetention() throws {
        let now = TestFixtures.now
        var current = TestFixtures.tokenUsageAggregate(at: now, tokenUsage: tokenUsage(input: 100))
        current.position = 42
        let old = TestFixtures.tokenUsageAggregate(at: now.addingTimeInterval(-220 * 86400), tokenUsage: tokenUsage(input: 300))
        let future = TestFixtures.tokenUsageAggregate(at: now.addingTimeInterval(86400), tokenUsage: tokenUsage(input: 500))
        #expect(TokenUsageAggregate.tokenUsageByDate([old, current, future], now: now) == [day: current.tokenUsage])
        #expect(try JSONLines.decoder.decode(TokenUsageAggregate.self, from: JSONLines.stableEncoder.encode(current)) == current)
        let record = try #require(TokenUsageSyncRecord.dailyRecords(local: [current], deviceID: "device", now: now).first)
        let fields = try #require(JSONSerialization.jsonObject(with: JSONLines.stableEncoder.encode(record)) as? [String: Any])
        #expect(fields["position"] == nil)
    }

    @Test func invalidCountersCannotReplaceCommittedAggregate() throws {
        var value = TokenUsageAggregate(date: day)
        let invalid = TokenUsage(inputTokens: 100, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 50)
        let observation = TokenUsageObservation(observedAt: TestFixtures.now, previous: .zero, current: TokenUsageUpdate(total: invalid, last: invalid))
        #expect(throws: StorageCompatibilityError.self) { try value.record(observation) }
        #expect(value.tokenUsage == .zero)
        #expect(value.eventCount == 0)
    }
}
