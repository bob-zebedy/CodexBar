import Foundation
import os

/// 原始观测与派生 Token 状态分别提交, 采集租约独立于数据库写锁
actor TokenUsageHistoryStore {
    private let directoryURL: URL
    private var threadSnapshots: [String: TokenUsageThreadSnapshot] = [:]
    private var snapshotAccess: [String: Date] = [:]
    private nonisolated let recordingLease = OSAllocatedUnfairLock<Int32?>(initialState: nil)

    init(directoryURL: URL = HistoryStorage.directoryURL()) {
        self.directoryURL = directoryURL
    }

    deinit {
        recordingLease.withLock {
            if let lease = $0 {
                JSONFileStorage.releaseLock(lease)
            }
        }
    }

    /// 租约不进入历史读写队列, 慢聚合不能阻塞连接启动和退出
    nonisolated func acquireRecordingLease() throws -> Bool {
        try recordingLease.withLock { lease in
            if lease != nil {
                return true
            }
            lease = try JSONFileStorage.acquireLock(in: directoryURL.appendingPathComponent("Locks"), name: "tokenUsage.lock", nonblocking: true)
            return lease != nil
        }
    }

    nonisolated func releaseRecordingLease() {
        recordingLease.withLock { lease in
            if let lease {
                JSONFileStorage.releaseLock(lease)
            }
            lease = nil
        }
    }

    func appendObservation(_ observation: TokenUsageObservation, now: Date = Date()) throws {
        try HistoryDatabase(directoryURL: directoryURL).append(AppServerEventRecord(tokenUsage: observation, recordedAt: now))
    }

    func record(_ sample: TokenUsageSample) throws -> TokenUsageThreadSnapshot {
        let database = try HistoryDatabase(directoryURL: directoryURL)
        try database.appendTokenUsage(sample)
        return try snapshot(threadID: sample.threadID, database: database)
    }

    func snapshot(threadID: String) throws -> TokenUsageThreadSnapshot {
        try snapshot(threadID: threadID, database: HistoryDatabase(directoryURL: directoryURL))
    }

    private func snapshot(threadID: String, database: HistoryDatabase) throws -> TokenUsageThreadSnapshot {
        let result = try database.tokenUsageSnapshot(threadSnapshots[threadID] ?? TokenUsageThreadSnapshot(threadID: threadID))
        threadSnapshots[threadID] = result
        snapshotAccess[threadID] = Date()
        if threadSnapshots.count > 128, let oldest = snapshotAccess.min(by: { $0.value < $1.value })?.key {
            threadSnapshots[oldest] = nil
            snapshotAccess[oldest] = nil
        }
        return result
    }

    func refresh(now: Date = Date()) throws -> [TokenUsageAggregate] {
        try loadSnapshot(now: now).aggregates
    }

    func loadSnapshot(now: Date = Date()) throws -> TokenUsageHistorySnapshot {
        try readSnapshot(now: now)
    }

    private nonisolated func readSnapshot(now: Date) throws -> TokenUsageHistorySnapshot {
        let database = try HistoryDatabase(directoryURL: directoryURL)
        for date in try database.pendingTokenUsageDates() {
            do {
                _ = try database.aggregateTokenUsage(date: date)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 单日失败保留上次提交结果, 其他日期继续处理
            }
        }
        return try database.transaction {
            try TokenUsageHistorySnapshot(
                aggregates: retained(database.tokenUsageAggregates(), now: now),
                coverage: database.pendingTokenUsageDates().isEmpty ? .complete : .partial
            )
        }
    }

    func persistedAggregates(now: Date = Date()) throws -> [TokenUsageAggregate] {
        try retained(HistoryDatabase(directoryURL: directoryURL).tokenUsageAggregates(), now: now)
    }

    func rebuild(for dateKeys: [String]) throws -> TokenUsageRebuildResult {
        let database = try HistoryDatabase(directoryURL: directoryURL)
        let available = try Set(database.tokenUsageDates())
        var result = TokenUsageRebuildResult.empty
        for date in Set(dateKeys).intersection(available).sorted() {
            do {
                let aggregate = try database.aggregateTokenUsage(date: date, rebuilding: true)
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

    private nonisolated func retained(_ aggregates: [TokenUsageAggregate], now: Date) -> [TokenUsageAggregate] {
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
