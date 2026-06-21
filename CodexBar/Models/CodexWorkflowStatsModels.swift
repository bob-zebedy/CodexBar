import Foundation

// Hook 事件类型: 由归一化后的事件名 (去除 _/-、小写) 映射, 是名称到聚合计数的唯一映射来源
nonisolated enum WorkflowEventKind: String {
    case sessionStart = "sessionstart"
    case stop = "stop"
    case preToolUse = "pretooluse"
    case postToolUse = "posttooluse"
    case permissionRequest = "permissionrequest"
    case preCompact = "precompact"
    case postCompact = "postcompact"
    case subagentStart = "subagentstart"
    case subagentStop = "subagentstop"

    init?(normalizedName: String) {
        self.init(rawValue: normalizedName)
    }
}

private nonisolated enum WorkflowStatsJSON {
    static func lineData(_ fields: [String]) -> Data {
        let json = "{\(fields.joined(separator: ","))}"
        return Data(json.utf8) + Data([0x0A])
    }

    static func field<T: Encodable>(_ name: String, _ value: T?) throws -> String {
        "\"\(name)\":\(try Self.value(value))"
    }

    static func value<T: Encodable>(_ value: T?) throws -> String {
        guard let value else {
            return "null"
        }

        return try Self.value(value)
    }

    static func value<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated struct WorkflowHookEvent: Decodable, Equatable {
    let timestamp: Date
    let name: String
    let directoryPath: String?
    let toolName: String?
    let modelName: String?
    let permissionMode: String?
    let sessionId: String?
    let turnId: String?

    init(
        timestamp: Date,
        name: String,
        directoryPath: String?,
        toolName: String?,
        modelName: String?,
        permissionMode: String?,
        sessionId: String?,
        turnId: String?
    ) {
        self.timestamp = timestamp
        self.name = name
        self.directoryPath = directoryPath
        self.toolName = toolName
        self.modelName = modelName
        self.permissionMode = permissionMode
        self.sessionId = sessionId
        self.turnId = turnId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let timestampString = Self.string(from: container, key: .timestamp),
              let timestamp = Self.date(from: timestampString) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing or invalid hook event timestamp")
            )
        }
        guard let name = Self.string(from: container, key: .event) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Missing hook event name")
            )
        }

        self.timestamp = timestamp
        self.name = name
        self.directoryPath = Self.string(from: container, key: .cwd)
        self.toolName = Self.string(from: container, key: .toolName)
        self.modelName = Self.string(from: container, key: .modelName)
        self.permissionMode = Self.string(from: container, key: .permissionMode)
        self.sessionId = Self.string(from: container, key: .sessionId)
        self.turnId = Self.string(from: container, key: .turnId)
    }

    var kind: WorkflowEventKind? {
        WorkflowEventKind(normalizedName: normalizedName)
    }

    var projectDisplayName: String? {
        guard let directoryPath, !directoryPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: directoryPath).standardizedFileURL
        let lastComponent = url.lastPathComponent
        return lastComponent.isEmpty ? directoryPath : lastComponent
    }

    private var normalizedName: String {
        name
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func string(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        return nil
    }

    private static func date(from string: String) -> Date? {
        DateFormatter.codexLocalTimestamp.date(from: string)
    }

    func jsonLineData() throws -> Data {
        let fields = [
            try WorkflowStatsJSON.field("timestamp", DateFormatter.codexLocalTimestamp.string(from: timestamp)),
            try WorkflowStatsJSON.field("event", name),
            try WorkflowStatsJSON.field("model", modelName),
            try WorkflowStatsJSON.field("permission", permissionMode),
            try WorkflowStatsJSON.field("session", sessionId),
            try WorkflowStatsJSON.field("turn", turnId),
            try WorkflowStatsJSON.field("tool", toolName),
            try WorkflowStatsJSON.field("cwd", directoryPath)
        ]

        return WorkflowStatsJSON.lineData(fields)
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case event
        case cwd
        case toolName = "tool"
        case modelName = "model"
        case permissionMode = "permission"
        case sessionId = "session"
        case turnId = "turn"
    }
}

nonisolated struct WorkflowDailyStats: Equatable, Identifiable {
    let startDate: String
    let sessionCount: Int
    let turnCount: Int
    let toolCallCount: Int
    let permissionRequestCount: Int
    let mostActiveProject: String?
    let contextCompactionCount: Int
    let subagentCount: Int
    let eventCount: Int

    var id: String { startDate }

    static func empty(startDate: String) -> WorkflowDailyStats {
        WorkflowDailyStats(
            startDate: startDate,
            sessionCount: 0,
            turnCount: 0,
            toolCallCount: 0,
            permissionRequestCount: 0,
            mostActiveProject: nil,
            contextCompactionCount: 0,
            subagentCount: 0,
            eventCount: 0
        )
    }
}

nonisolated struct WorkflowStatsSnapshot: Equatable {
    let generatedAt: Date
    let dailyStats: [WorkflowDailyStats]

    static let empty = WorkflowStatsSnapshot(generatedAt: Date(), dailyStats: [])

    init(generatedAt: Date = Date(), dailyStats: [WorkflowDailyStats]) {
        self.generatedAt = generatedAt
        self.dailyStats = dailyStats
    }

    init(dailyAggregates: [WorkflowDailyAggregate], generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        self.dailyStats = dailyAggregates
            .map(\.stats)
            .sorted { $0.startDate < $1.startDate }
    }

    func recentWeekGrid(columnCount: Int, endingDaysAgo: Int = 0, today: Date = Date()) -> [WorkflowDailyStats?] {
        let statsByDate = dailyStats.reduce(into: [String: WorkflowDailyStats]()) { result, stats in
            result[stats.startDate] = stats
        }

        return CodexWeekGrid.dates(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        .map { date in
            date.map {
                let startDate = DateFormatter.codexDay.string(from: $0)
                return statsByDate[startDate] ?? WorkflowDailyStats.empty(startDate: startDate)
            }
        }
    }
}

nonisolated struct WorkflowDailyIdentifierCache {
    var sessionIds: Set<String>
    var turnIds: Set<String>

    init(aggregate: WorkflowDailyAggregate) {
        self.sessionIds = Set(aggregate.sessionIds ?? [])
        self.turnIds = Set(aggregate.turnIds ?? [])
    }
}

nonisolated struct WorkflowDailyAggregate: Codable, Equatable, Identifiable {
    let date: String
    var eventCount: Int
    var sessionStartCount: Int
    var stopCount: Int
    var preToolUseCount: Int
    var postToolUseCount: Int
    var permissionRequestCount: Int
    var preCompactCount: Int
    var postCompactCount: Int
    var subagentStartCount: Int
    var subagentStopCount: Int
    var sessionIds: [String]?
    var turnIds: [String]?
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]

    var id: String { date }

    init(date: String) {
        self.date = date
        self.eventCount = 0
        self.sessionStartCount = 0
        self.stopCount = 0
        self.preToolUseCount = 0
        self.postToolUseCount = 0
        self.permissionRequestCount = 0
        self.preCompactCount = 0
        self.postCompactCount = 0
        self.subagentStartCount = 0
        self.subagentStopCount = 0
        self.sessionIds = []
        self.turnIds = []
        self.sessionCount = nil
        self.turnCount = nil
        self.projectCounts = [:]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(String.self, forKey: .date)
        self.eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        self.sessionStartCount = try container.decodeIfPresent(Int.self, forKey: .sessionStartCount) ?? 0
        self.stopCount = try container.decodeIfPresent(Int.self, forKey: .stopCount) ?? 0
        self.preToolUseCount = try container.decodeIfPresent(Int.self, forKey: .preToolUseCount) ?? 0
        self.postToolUseCount = try container.decodeIfPresent(Int.self, forKey: .postToolUseCount) ?? 0
        self.permissionRequestCount = try container.decodeIfPresent(Int.self, forKey: .permissionRequestCount) ?? 0
        self.preCompactCount = try container.decodeIfPresent(Int.self, forKey: .preCompactCount) ?? 0
        self.postCompactCount = try container.decodeIfPresent(Int.self, forKey: .postCompactCount) ?? 0
        self.subagentStartCount = try container.decodeIfPresent(Int.self, forKey: .subagentStartCount) ?? 0
        self.subagentStopCount = try container.decodeIfPresent(Int.self, forKey: .subagentStopCount) ?? 0
        self.sessionIds = try container.decodeIfPresent([String].self, forKey: .sessionIds)
        self.turnIds = try container.decodeIfPresent([String].self, forKey: .turnIds)
        self.sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount)
        self.turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        self.projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
    }

    mutating func record(
        _ event: WorkflowHookEvent,
        keepsIdentifiers: Bool,
        identifierCache: inout WorkflowDailyIdentifierCache
    ) {
        eventCount += 1

        switch event.kind {
        case .sessionStart: sessionStartCount += 1
        case .stop: stopCount += 1
        case .preToolUse: preToolUseCount += 1
        case .postToolUse: postToolUseCount += 1
        case .permissionRequest: permissionRequestCount += 1
        case .preCompact: preCompactCount += 1
        case .postCompact: postCompactCount += 1
        case .subagentStart: subagentStartCount += 1
        case .subagentStop: subagentStopCount += 1
        case .none: break
        }

        if keepsIdentifiers {
            if let sessionId = event.sessionId {
                Self.append(sessionId, to: &sessionIds, using: &identifierCache.sessionIds)
            }

            if let turnId = event.turnId {
                Self.append(turnId, to: &turnIds, using: &identifierCache.turnIds)
            }
        }

        if let projectDisplayName = event.projectDisplayName {
            projectCounts[projectDisplayName, default: 0] += 1
        }
    }

    mutating func compactIdentifiersIfNeeded(keepsIdentifiers: Bool) {
        guard !keepsIdentifiers else {
            sessionIds = Self.normalizedIdentifiers(sessionIds)
            turnIds = Self.normalizedIdentifiers(turnIds)
            return
        }

        sessionCount = resolvedSessionCount
        turnCount = resolvedTurnCount
        sessionIds = nil
        turnIds = nil
    }

    // 会话/轮次最终值: 优先使用去重/压缩后的数量, 起止事件计数只作为缺失兜底
    private var resolvedSessionCount: Int {
        sessionCount ?? sessionIds?.count ?? sessionStartCount
    }

    private var resolvedTurnCount: Int {
        turnCount ?? turnIds?.count ?? stopCount
    }

    var stats: WorkflowDailyStats {
        let sessionTotal = resolvedSessionCount
        let turnTotal = resolvedTurnCount
        let toolCallCount = max(preToolUseCount, postToolUseCount)
        let contextCompactionCount = max(preCompactCount, postCompactCount)
        let subagentCount = max(subagentStartCount, subagentStopCount)

        return WorkflowDailyStats(
            startDate: date,
            sessionCount: sessionTotal,
            turnCount: turnTotal,
            toolCallCount: toolCallCount,
            permissionRequestCount: permissionRequestCount,
            mostActiveProject: mostActiveProject,
            contextCompactionCount: contextCompactionCount,
            subagentCount: subagentCount,
            eventCount: eventCount
        )
    }

    static func normalized(
        aggregates: [WorkflowDailyAggregate],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [WorkflowDailyAggregate] {
        let retentionCutoffDate = WorkflowStatsStorage.retentionCutoffDate(today: today, calendar: calendar)
        let identifierCutoffDate = WorkflowStatsStorage.identifierRetentionCutoffDate(today: today, calendar: calendar)

        return aggregates.compactMap { aggregate in
            guard let date = Self.date(from: aggregate.date), date >= retentionCutoffDate else {
                return nil
            }

            var mutableAggregate = aggregate
            mutableAggregate.compactIdentifiersIfNeeded(keepsIdentifiers: date >= identifierCutoffDate)
            return mutableAggregate
        }
        .sorted { $0.date < $1.date }
    }

    static func decodeJSONLines(from data: Data) -> [WorkflowDailyAggregate] {
        JSONLines.decode(from: data)
    }

    static func encodeJSONLines(_ aggregates: [WorkflowDailyAggregate]) throws -> Data {
        try aggregates.reduce(into: Data()) { result, aggregate in
            result.append(try aggregate.jsonLineData())
        }
    }

    func jsonLineData() throws -> Data {
        let fields = [
            try WorkflowStatsJSON.field("date", date),
            try WorkflowStatsJSON.field("eventCount", eventCount),
            try WorkflowStatsJSON.field("sessionStartCount", sessionStartCount),
            try WorkflowStatsJSON.field("stopCount", stopCount),
            try WorkflowStatsJSON.field("preToolUseCount", preToolUseCount),
            try WorkflowStatsJSON.field("postToolUseCount", postToolUseCount),
            try WorkflowStatsJSON.field("permissionRequestCount", permissionRequestCount),
            try WorkflowStatsJSON.field("preCompactCount", preCompactCount),
            try WorkflowStatsJSON.field("postCompactCount", postCompactCount),
            try WorkflowStatsJSON.field("subagentStartCount", subagentStartCount),
            try WorkflowStatsJSON.field("subagentStopCount", subagentStopCount),
            try WorkflowStatsJSON.field("sessionIds", sessionIds),
            try WorkflowStatsJSON.field("turnIds", turnIds),
            try WorkflowStatsJSON.field("sessionCount", sessionCount),
            try WorkflowStatsJSON.field("turnCount", turnCount),
            try WorkflowStatsJSON.field("projectCounts", projectCounts)
        ]

        return WorkflowStatsJSON.lineData(fields)
    }

    private static func append(
        _ identifier: String,
        to identifiers: inout [String]?,
        using identifierSet: inout Set<String>
    ) {
        guard identifierSet.insert(identifier).inserted else {
            return
        }

        if identifiers == nil {
            identifiers = []
        }
        identifiers?.append(identifier)
    }

    private static func normalizedIdentifiers(_ identifiers: [String]?) -> [String] {
        Set(identifiers ?? []).sorted()
    }

    private var mostActiveProject: String? {
        projectCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }

                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .first?
            .key
    }

    private static func date(from string: String) -> Date? {
        DateFormatter.codexDay.date(from: string)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case eventCount
        case sessionStartCount
        case stopCount
        case preToolUseCount
        case postToolUseCount
        case permissionRequestCount
        case preCompactCount
        case postCompactCount
        case subagentStartCount
        case subagentStopCount
        case sessionIds
        case turnIds
        case sessionCount
        case turnCount
        case projectCounts
    }
}
