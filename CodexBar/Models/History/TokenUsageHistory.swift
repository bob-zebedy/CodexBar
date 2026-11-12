import Foundation

/// 历史直接累计观测增量, 不依赖根任务归属或轮次展示状态
nonisolated struct TokenUsageAggregate: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var aggregationVersion = AggregationVersion.tokenUsage
    var position: Int64 = 0
    let date: String
    var eventCount = 0
    var tokenUsage: TokenUsage = .zero

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, aggregationVersion, position, date, eventCount, tokenUsage
    }

    init(date: String, tokenUsage: TokenUsage = .zero, eventCount: Int = 0) {
        self.date = date
        self.tokenUsage = tokenUsage
        self.eventCount = eventCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try StorageVersion.require(schemaVersion, current: Self.schemaVersion, name: "TokenUsageAggregate")
        aggregationVersion = try container.decode(Int.self, forKey: .aggregationVersion)
        try AggregationVersion.require(aggregationVersion, current: AggregationVersion.tokenUsage, name: "tokenUsage")
        position = try container.decode(Int64.self, forKey: .position)
        date = try container.decode(String.self, forKey: .date)
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        tokenUsage = try container.decode(TokenUsage.self, forKey: .tokenUsage)
        guard HistoryStorage.isValidDateKey(date), position >= 0, eventCount >= 0, tokenUsage.isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid daily token aggregate"))
        }
    }

    mutating func record(_ observation: TokenUsageObservation) throws {
        guard let delta = observation.delta, let total = tokenUsage.adding(delta), total.isValid else {
            throw StorageCompatibilityError.incompleteSource
        }
        tokenUsage = total
        eventCount += 1
    }

    static func tokenUsageByDate(_ aggregates: [Self], now: Date = Date()) -> [String: TokenUsage] {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        let today = HistoryStorage.dateKey(for: now)
        var result: [String: TokenUsage] = [:]
        for aggregate in aggregates where aggregate.date >= cutoff && aggregate.date <= today && aggregate.tokenUsage.isValid {
            result[aggregate.date] = aggregate.tokenUsage
        }
        return result
    }
}

/// 通知先排队, 比较基线由存储事务决定
nonisolated struct TokenUsageSample: Codable {
    var id = UUID().uuidString.lowercased()
    let observedAt: Date
    let threadID: String
    let turnID: String
    let turnStartedAt: Date?
    let current: TokenUsageUpdate
}

nonisolated struct TokenUsageThreadSnapshot {
    let threadID: String
    var position: Int64 = 0
    var turns: [String: TokenUsage] = [:]
}

/// 相邻会话累计值构成独立观测, 重试复用同一个 ID 和采集时间
nonisolated struct TokenUsageObservation: Codable, Equatable {
    let id: String
    let observedAt: Date
    let threadID: String?
    let turnID: String?
    let turnStartedAt: Date?
    let previous: TokenUsage
    let current: TokenUsageUpdate

    init(
        id: String = UUID().uuidString.lowercased(), observedAt: Date,
        threadID: String? = nil, turnID: String? = nil, turnStartedAt: Date? = nil,
        previous: TokenUsage, current: TokenUsageUpdate
    ) {
        self.id = id
        self.observedAt = JSONLines.storageDate(observedAt)
        self.threadID = threadID
        self.turnID = turnID
        self.turnStartedAt = turnStartedAt.map(JSONLines.storageDate)
        self.previous = previous
        self.current = current
    }

    /// 开始时间未知时仍保存用量, 不因轮次元数据缺失丢弃有效消耗
    var aggregationDate: Date {
        turnStartedAt ?? observedAt
    }

    var delta: TokenUsage? {
        current.total.subtractingCounters(previous)
    }
}
