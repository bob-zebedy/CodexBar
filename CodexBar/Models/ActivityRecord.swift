import Foundation

// MARK: - 归一化活动事件

/// 事件来源的本地归一化分类, 不保留原始 context 内容
nonisolated enum ActivityOrigin: String, Codable, Sendable {
    case main
    case autoReview
    case auxiliary
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try? container.decode(String.self)
        self = rawValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

/// app-server 的最小统计事件, 在边界归一化来源与可选元数据
nonisolated struct ActivityRecord: Codable, Equatable {
    let id: String?
    let timestamp: Date
    let name: String
    let origin: ActivityOrigin
    let cwd: String?
    let toolName: String?
    let commandActionTypes: [String]?
    let model: String?
    let effort: String?
    let threadID: String?
    let turnID: String?
    let agentID: String?
    var context: ActivityContext?

    init(
        timestamp: Date,
        name: String,
        origin: ActivityOrigin,
        cwd: String?,
        toolName: String?,
        commandActionTypes: [String]? = nil,
        model: String?,
        effort: String?,
        threadID: String?,
        turnID: String?,
        agentID: String?,
        id: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.origin = origin
        self.cwd = cwd
        self.toolName = toolName
        self.commandActionTypes = commandActionTypes
        self.model = model
        self.effort = effort
        self.threadID = threadID
        self.turnID = turnID
        self.agentID = agentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let phase = try container.decode(String.self, forKey: .name)
        guard let event = ActivityEventKind(rawValue: phase) else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "Unknown activity phase")
        }
        let name = event.rawValue
        context = try container.decodeIfPresent(ActivityContext.self, forKey: .context)

        id = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedOrigin = (try? container.decode(ActivityOrigin.self, forKey: .origin)) ?? .unknown
        let decodedModel = Self.string(from: container, key: .model)

        self.timestamp = timestamp
        self.name = name
        origin = decodedOrigin
        cwd = Self.string(from: container, key: .cwd)
        toolName = Self.string(from: container, key: .toolName)
        commandActionTypes = try container.decodeIfPresent([String].self, forKey: .commandActionTypes)
        model = decodedModel
        effort = Self.string(from: container, key: .effort)
        threadID = Self.string(from: container, key: .threadID)
        turnID = Self.string(from: container, key: .turnID)
        agentID = Self.string(from: container, key: .agentID)
    }

    var eventKind: ActivityEventKind? {
        ActivityEventKind(eventName: name)
    }

    var projectDisplayName: String? {
        guard let cwd, !cwd.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: cwd).standardizedFileURL
        let lastComponent = url.lastPathComponent
        return lastComponent.isEmpty ? cwd : lastComponent
    }

    private static func string(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        guard let value = try? container.decode(String.self, forKey: key) else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        guard let eventKind else {
            throw EncodingError.invalidValue(name, .init(codingPath: encoder.codingPath, debugDescription: "Unknown activity phase"))
        }
        try container.encode(eventKind.rawValue, forKey: .name)
        try container.encode(origin, forKey: .origin)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(commandActionTypes, forKey: .commandActionTypes)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encodeIfPresent(context, forKey: .context)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case name
        case origin
        case cwd
        case toolName
        case commandActionTypes
        case model
        case effort
        case threadID
        case turnID
        case agentID
        case context
    }
}

/// 任务归属与生命周期事实, 时间统一为 Date 和秒, method 仅用于来源诊断
nonisolated struct ActivityContext: Codable, Equatable {
    let method: String
    let threadID: String
    var turnID: String?
    var parentThreadID: String?
    var rootThreadID: String?
    var rootTurnID: String?
    var itemID: String?
    var itemType: String?
    var itemStatus: String?
    var agentThreadID: String?
    var itemKind: String?
    var requestID: String?
    var turnStatus: ActivityTurnStatus?
    var turnStartedAt: Date?
    var turnCompletedAt: Date?
    var duration: TimeInterval?
}
