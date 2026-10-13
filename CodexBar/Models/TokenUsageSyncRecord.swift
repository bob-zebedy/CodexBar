import Foundation

/// 云端每台设备每天只保存一份数量, 本地观测不会从云端导入
nonisolated struct TokenUsageSyncRecord: SyncCacheRecord {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var aggregationVersion = AggregationVersion.tokenUsage
    let deviceID: String
    let date: String
    let tokenUsage: TokenUsage?
    var updatedAt: Date?

    var id: String {
        recordName
    }

    var recordName: String {
        "tokenUsage_\(deviceID)_\(date)"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, aggregationVersion, deviceID, date, recordName, updatedAt, tokenUsage
    }

    init(
        aggregationVersion: Int = AggregationVersion.tokenUsage, deviceID: String, date: String,
        tokenUsage: TokenUsage?, updatedAt: Date? = nil
    ) {
        self.aggregationVersion = aggregationVersion
        self.deviceID = deviceID
        self.date = date
        self.tokenUsage = tokenUsage
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try StorageVersion.require(schemaVersion, current: Self.schemaVersion, name: "TokenUsageSyncRecord")
        aggregationVersion = try container.decode(Int.self, forKey: .aggregationVersion)
        try AggregationVersion.require(aggregationVersion, current: AggregationVersion.tokenUsage, name: "tokenUsage")
        deviceID = try container.decode(String.self, forKey: .deviceID)
        date = try container.decode(String.self, forKey: .date)
        tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        guard !deviceID.isEmpty, HistoryStorage.isValidDateKey(date), tokenUsage?.isValid != false,
              try container.decode(String.self, forKey: .recordName) == recordName else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid daily token record"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(aggregationVersion, forKey: .aggregationVersion)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(date, forKey: .date)
        try container.encode(recordName, forKey: .recordName)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(tokenUsage, forKey: .tokenUsage)
    }

    /// 云端更新时间不参与上传判断, 只比较设备日期对应的业务数据
    func hasSameData(as other: Self) -> Bool {
        aggregationVersion == other.aggregationVersion && deviceID == other.deviceID
            && date == other.date && tokenUsage == other.tokenUsage
    }

    static func dailyRecords(local: [TokenUsageAggregate], deviceID: String, now: Date = Date()) throws -> [Self] {
        for aggregate in local {
            try AggregationVersion.require(aggregate.aggregationVersion, current: AggregationVersion.tokenUsage, name: "tokenUsage")
        }
        return TokenUsageAggregate.tokenUsageByDate(local, now: now).sorted { $0.key < $1.key }.map {
            Self(deviceID: deviceID, date: $0.key, tokenUsage: $0.value)
        }
    }

    static func tokenUsageByDate(_ records: [Self], now: Date = Date()) -> [String: TokenUsage] {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        let today = HistoryStorage.dateKey(for: now)
        var result: [String: TokenUsage] = [:]
        var unavailableDates = Set<String>()
        for record in records where record.date >= cutoff && record.date <= today {
            guard let tokenUsage = record.tokenUsage, tokenUsage.isValid,
                  let sum = (result[record.date] ?? .zero).adding(tokenUsage), sum.isValid else {
                unavailableDates.insert(record.date)
                continue
            }
            result[record.date] = sum
        }
        for date in unavailableDates {
            result.removeValue(forKey: date)
        }
        return result
    }
}
