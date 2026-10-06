import Foundation

// MARK: - 归一化活动事件

/// 事件来源的本地归一化分类, 不保留原始 source 内容
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
    let tool: String?
    let model: String?
    let effort: String?
    let approvalReviewer: ApprovalReviewer?
    let sessionID: String?
    let turnID: String?
    let agentID: String?
    var source: AppServerEventSource?

    init(
        timestamp: Date,
        name: String,
        origin: ActivityOrigin,
        cwd: String?,
        tool: String?,
        model: String?,
        effort: String?,
        approvalReviewer: ApprovalReviewer?,
        sessionID: String?,
        turnID: String?,
        agentID: String?,
        id: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.origin = Self.resolvedOrigin(origin, model: model)
        self.cwd = cwd
        self.tool = tool
        self.model = model
        self.effort = effort
        self.approvalReviewer = approvalReviewer
        self.sessionID = sessionID
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
        source = try container.decodeIfPresent(AppServerEventSource.self, forKey: .source)

        id = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedOrigin = (try? container.decode(ActivityOrigin.self, forKey: .origin)) ?? .unknown
        let decodedModel = Self.string(from: container, key: .model)

        self.timestamp = timestamp
        self.name = name
        origin = Self.resolvedOrigin(decodedOrigin, model: decodedModel)
        cwd = Self.string(from: container, key: .cwd)
        tool = Self.string(from: container, key: .tool)
        model = decodedModel
        effort = Self.string(from: container, key: .effort)
        approvalReviewer = try? container.decode(
            ApprovalReviewer.self,
            forKey: .approvalReviewer
        )
        sessionID = Self.string(from: container, key: .sessionID)
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

    /// 来源元数据缺失时, 专用审核模型只作为未知来源的保守后备
    private static func resolvedOrigin(
        _ origin: ActivityOrigin,
        model: String?
    ) -> ActivityOrigin {
        guard origin == .unknown,
              model == autoReviewModelName else {
            return origin
        }
        return .autoReview
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
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(approvalReviewer, forKey: .approvalReviewer)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encodeIfPresent(source, forKey: .source)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case name
        case origin
        case cwd
        case tool
        case model
        case effort
        case approvalReviewer
        case sessionID
        case turnID
        case agentID
        case source
    }

    private static let autoReviewModelName = "codex-auto-review"
}
