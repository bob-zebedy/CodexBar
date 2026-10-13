import Foundation

/// 数据库仅保存活动事实和 Token 原始观测, 派生快照不能作为重建来源
nonisolated struct AppServerEventRecord: Codable, Equatable {
    enum Kind: String, Codable { case activityData, tokenUsage }

    static let schemaVersion = 1
    let schemaVersion: Int
    let recordedAt: Date
    let context: ActivityDataContext?
    private let storedActivityData: ActivityDataRecord?
    let tokenUsage: TokenUsageObservation?

    var kind: Kind {
        storedActivityData == nil ? .tokenUsage : .activityData
    }

    var deduplicationID: String? {
        if let id = storedActivityData?.id {
            return "activityData:" + id
        }
        if let tokenUsage {
            return "tokenUsage:" + tokenUsage.id
        }
        return nil
    }

    var activityData: ActivityDataRecord? {
        guard var activityData = storedActivityData else { return nil }
        activityData.context = context
        return activityData
    }

    init(activityData: ActivityDataRecord, recordedAt: Date = Date()) {
        schemaVersion = Self.schemaVersion
        self.recordedAt = recordedAt
        context = activityData.context
        var payload = activityData
        payload.context = nil
        storedActivityData = payload
        tokenUsage = nil
    }

    init(tokenUsage: TokenUsageObservation, recordedAt: Date) {
        schemaVersion = Self.schemaVersion
        self.recordedAt = recordedAt
        context = nil
        storedActivityData = nil
        self.tokenUsage = tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unsupported event schema version")
        }
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        context = try container.decodeIfPresent(ActivityDataContext.self, forKey: .context)
        tokenUsage = try container.decodeIfPresent(TokenUsageObservation.self, forKey: .tokenUsage)
        storedActivityData = try container.decodeIfPresent(ActivityDataRecord.self, forKey: .storedActivityData)
        guard (storedActivityData != nil) != (tokenUsage != nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected exactly one event payload"))
        }
    }

    func jsonLineData() throws -> Data {
        try Self.encoder.encode(self) + Data([JSONLines.newlineByte])
    }

    static func decode(from data: Data) throws -> Self {
        try decode(Self.self, from: data)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try decoder.decode(type, from: data)
    }

    static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    private static let encoder = JSONLines.stableEncoder
    private static let decoder = JSONLines.decoder

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case recordedAt
        case context
        case storedActivityData = "activityData"
        case tokenUsage
    }
}
