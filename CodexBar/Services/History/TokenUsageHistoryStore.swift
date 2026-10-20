import Foundation
import os

/// 原始观测与派生 Token 状态分别提交, 采集租约独立于数据库写锁
final nonisolated class TokenUsageHistoryStore: Sendable {
    private let directoryURL: URL
    private let database: HistoryDatabaseStore
    private let recordingLease = OSAllocatedUnfairLock<Int32?>(initialState: nil)

    init(directoryURL: URL = HistoryStorage.directoryURL()) {
        self.directoryURL = directoryURL
        database = HistoryDatabaseStore.shared(in: directoryURL)
    }

    deinit {
        recordingLease.withLock {
            if let lease = $0 {
                JSONFileStorage.releaseLock(lease)
            }
        }
    }

    /// 租约不进入历史读写队列, 慢聚合不能阻塞连接启动和退出
    func acquireRecordingLease() throws -> Bool {
        try recordingLease.withLock { lease in
            if lease != nil {
                return true
            }
            lease = try JSONFileStorage.acquireLock(in: directoryURL.appendingPathComponent("Locks"), name: "tokenUsage.lock", nonblocking: true)
            return lease != nil
        }
    }

    func releaseRecordingLease() {
        recordingLease.withLock { lease in
            if let lease {
                JSONFileStorage.releaseLock(lease)
            }
            lease = nil
        }
    }

    func appendObservation(_ observation: TokenUsageObservation, now: Date = Date()) async throws {
        _ = try await database.access { try $0.append(AppServerEventRecord(tokenUsage: observation, recordedAt: now)) }
    }

    func record(_ sample: TokenUsageSample) async throws -> TokenUsageThreadSnapshot {
        try await database.access {
            try $0.appendTokenUsage(sample)
            return try $0.tokenUsageSnapshot(threadID: sample.threadID)
        }
    }

    func snapshot(threadID: String) async throws -> TokenUsageThreadSnapshot {
        try await database.access { try $0.tokenUsageSnapshot(threadID: threadID) }
    }

    func refresh(now: Date = Date()) async throws -> [TokenUsageAggregate] {
        try await loadSnapshot(now: now).aggregates
    }

    func loadSnapshot(now: Date = Date()) async throws -> TokenUsageHistorySnapshot {
        try await readSnapshot(now: now)
    }

    private func readSnapshot(now: Date) async throws -> TokenUsageHistorySnapshot {
        let dates = try await database.access { try $0.pendingTokenUsageDates() }
        for date in dates {
            do {
                _ = try await database.access { try $0.aggregateTokenUsage(date: date) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单日失败保留上次提交结果, 其他日期继续处理
            }
        }
        return try await database.access { database in
            try database.transaction {
                try TokenUsageHistorySnapshot(
                    aggregates: Self.retained(database.tokenUsageAggregates(), now: now),
                    coverage: database.pendingTokenUsageDates().isEmpty ? .complete : .partial
                )
            }
        }
    }

    func persistedAggregates(now: Date = Date()) async throws -> [TokenUsageAggregate] {
        try await database.access { try Self.retained($0.tokenUsageAggregates(), now: now) }
    }

    func rebuild(for dateKeys: [String]) async throws -> TokenUsageRebuildResult {
        let dates = try await database.access { try $0.tokenUsageDates(in: dateKeys) }
        var result = TokenUsageRebuildResult.empty
        for date in dates {
            do {
                let aggregate = try await database.access { try $0.aggregateTokenUsage(date: date, rebuilding: true) }
                result.dateKeys.append(date)
                result.eventCount += aggregate.eventCount
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.failedDateKeys.append(date)
            }
        }
        return result
    }

    private static func retained(_ aggregates: [TokenUsageAggregate], now: Date) -> [TokenUsageAggregate] {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        return aggregates.filter { $0.date >= cutoff }
    }
}

nonisolated struct TokenUsageHistorySnapshot {
    let aggregates: [TokenUsageAggregate]
    let coverage: TokenUsageReplayCoverage
}

nonisolated enum TokenUsageReplayCoverage: Equatable {
    case complete, partial, unavailable
    var isComplete: Bool {
        self == .complete
    }
}

nonisolated struct TokenUsageRebuildResult {
    var dateKeys: [String] = []
    var eventCount = 0
    var failedDateKeys: [String] = []
    static let empty = Self()
}

nonisolated struct TokenUsageFileCache<Value: Codable & Equatable> {
    let url: URL
    private var data: Data?
    private var value: Value?

    init(url: URL) {
        self.url = url
    }

    mutating func load(validate: (Data) throws -> Void = { _ in }) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            data = nil
            value = nil
            return nil
        }
        let current = try Data(contentsOf: url)
        if current == data {
            return value
        }
        try validate(current)
        let decoded = try JSONLines.decoder.decode(Value.self, from: current)
        data = current
        value = decoded
        return decoded
    }

    mutating func save(_ updated: Value) throws {
        let current = try? Data(contentsOf: url)
        if let current, current == data, updated == value {
            return
        }
        let encoded = try JSONLines.stableEncoder.encode(updated)
        if current != encoded {
            try encoded.write(to: url, options: .atomic)
        }
        data = encoded
        value = updated
    }
}
