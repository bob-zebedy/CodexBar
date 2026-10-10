import Foundation

/// 统一日志的版本与类型边界, Token 快照不会作为活动进入计数
nonisolated struct AppServerEventRecord: Codable, Equatable {
    enum Kind: String, Codable { case activity, tokenSnapshot, tokenObservation }

    static let currentVersion = 1
    let version: Int
    let kind: Kind
    let recordedAt: Date
    let context: ActivityContext?
    private let activityPayload: ActivityRecord?
    let token: TokenTurn?
    let observation: TokenObservation?

    var deduplicationID: String? {
        if let id = activityPayload?.id {
            return "activity:" + id
        }
        if let observation {
            return "token:\(observation.turn.id):\(observation.streamID):\(observation.sequence)"
        }
        return nil
    }

    var activity: ActivityRecord? {
        guard var activity = activityPayload else { return nil }
        activity.context = context
        return activity
    }

    init(activity: ActivityRecord, recordedAt: Date = Date()) {
        version = Self.currentVersion
        kind = .activity
        self.recordedAt = recordedAt
        context = activity.context
        var payload = activity
        payload.context = nil
        activityPayload = payload
        token = nil
        observation = nil
    }

    init(token: TokenTurn, context: ActivityContext? = nil, recordedAt: Date) {
        version = Self.currentVersion
        kind = .tokenSnapshot
        self.recordedAt = recordedAt
        self.context = context
        activityPayload = nil
        self.token = token
        observation = nil
    }

    init(observation: TokenObservation, recordedAt: Date) {
        version = Self.currentVersion
        kind = .tokenObservation
        self.recordedAt = recordedAt
        context = nil
        activityPayload = nil
        token = nil
        self.observation = observation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported event version")
        }
        kind = try container.decode(Kind.self, forKey: .kind)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        context = try container.decodeIfPresent(ActivityContext.self, forKey: .context)
        observation = try container.decodeIfPresent(TokenObservation.self, forKey: .observation)
        switch kind {
        case .activity:
            activityPayload = try container.decode(ActivityRecord.self, forKey: .activityPayload)
            token = nil
            guard !container.contains(.token), observation == nil else {
                throw DecodingError.dataCorruptedError(forKey: .token, in: container, debugDescription: "Activity cannot contain tokens")
            }
        case .tokenObservation:
            activityPayload = nil
            token = nil
            guard observation != nil, !container.contains(.token), !container.contains(.activityPayload) else {
                throw DecodingError.dataCorruptedError(forKey: .observation, in: container, debugDescription: "Missing observation")
            }
        case .tokenSnapshot:
            token = try container.decode(TokenTurn.self, forKey: .token)
            activityPayload = nil
            guard !container.contains(.activityPayload), observation == nil, token?.usage?.isValid != false else {
                throw DecodingError.dataCorruptedError(forKey: .token, in: container, debugDescription: "Invalid token snapshot")
            }
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
        case version
        case kind
        case recordedAt
        case context
        case activityPayload
        case token
        case observation
    }
}
