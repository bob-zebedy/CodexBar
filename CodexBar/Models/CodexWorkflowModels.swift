import Foundation

/// 写入 JSONL 时固定字段顺序, 便于人工排查和 diff
private nonisolated enum WorkflowJSON {
    static func lineData(_ fields: [String]) -> Data {
        let json = "{\(fields.joined(separator: ","))}"
        return Data(json.utf8) + Data([0x0A])
    }

    static func field(_ name: String, _ value: (some Encodable)?) throws -> String {
        try "\"\(name)\":\(Self.value(value))"
    }

    static func value(_ value: (some Encodable)?) throws -> String {
        guard let value else {
            return "null"
        }

        return try Self.value(value)
    }

    static func value(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Encoded workflow JSON was not UTF-8")
            )
        }
        return text
    }
}

/// hooks 进程落盘的最小事件模型, 对历史字段缺失保持宽容
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
        directoryPath = Self.string(from: container, key: .cwd)
        toolName = Self.string(from: container, key: .toolName)
        modelName = Self.string(from: container, key: .modelName)
        permissionMode = Self.string(from: container, key: .permissionMode)
        sessionId = Self.string(from: container, key: .sessionId)
        turnId = Self.string(from: container, key: .turnId)
    }

    var hookEvent: CodexHookEvent? {
        CodexHookEvent(eventName: name)
    }

    var projectDisplayName: String? {
        guard let directoryPath, !directoryPath.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: directoryPath).standardizedFileURL
        let lastComponent = url.lastPathComponent
        return lastComponent.isEmpty ? directoryPath : lastComponent
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
        CodexDateFormat.localTimestampDate(from: string)
    }

    func jsonLineData() throws -> Data {
        let fields = try [
            WorkflowJSON.field("timestamp", CodexDateFormat.localTimestampString(from: timestamp)),
            WorkflowJSON.field("event", name),
            WorkflowJSON.field("model", modelName),
            WorkflowJSON.field("permission", permissionMode),
            WorkflowJSON.field("session", sessionId),
            WorkflowJSON.field("turn", turnId),
            WorkflowJSON.field("tool", toolName),
            WorkflowJSON.field("cwd", directoryPath)
        ]

        return WorkflowJSON.lineData(fields)
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

/// 热力图详情面板直接消费的每日统计
nonisolated struct WorkflowDailyMetrics: Equatable, Identifiable {
    let startDate: String
    let sessionCount: Int
    let turnCount: Int
    let toolCallCount: Int
    let permissionRequestCount: Int
    let contextCompactionCount: Int
    let subagentCount: Int

    var id: String {
        startDate
    }

    init(
        startDate: String,
        sessionCount: Int,
        turnCount: Int,
        toolCallCount: Int,
        permissionRequestCount: Int,
        contextCompactionCount: Int,
        subagentCount: Int
    ) {
        self.startDate = startDate
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.permissionRequestCount = permissionRequestCount
        self.contextCompactionCount = contextCompactionCount
        self.subagentCount = subagentCount
    }

    static func empty(startDate: String) -> WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: startDate,
            sessionCount: 0,
            turnCount: 0,
            toolCallCount: 0,
            permissionRequestCount: 0,
            contextCompactionCount: 0,
            subagentCount: 0
        )
    }

    init(
        startDate: String,
        sessionCount: Int,
        turnCount: Int,
        preToolUseCount: Int,
        postToolUseCount: Int,
        permissionRequestCount: Int,
        preCompactCount: Int,
        postCompactCount: Int,
        subagentStartCount: Int,
        subagentStopCount: Int
    ) {
        self.startDate = startDate
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        toolCallCount = max(preToolUseCount, postToolUseCount)
        self.permissionRequestCount = permissionRequestCount
        contextCompactionCount = max(preCompactCount, postCompactCount)
        subagentCount = max(subagentStartCount, subagentStopCount)
    }

    func adding(_ other: WorkflowDailyMetrics) -> WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: startDate,
            sessionCount: sessionCount + other.sessionCount,
            turnCount: turnCount + other.turnCount,
            toolCallCount: toolCallCount + other.toolCallCount,
            permissionRequestCount: permissionRequestCount + other.permissionRequestCount,
            contextCompactionCount: contextCompactionCount + other.contextCompactionCount,
            subagentCount: subagentCount + other.subagentCount
        )
    }
}

/// WorkflowService 发布给 UI 的近端快照
nonisolated struct WorkflowSnapshot: Equatable {
    let generatedAt: Date
    let dailyMetrics: [WorkflowDailyMetrics]

    static let empty = WorkflowSnapshot(generatedAt: Date(), dailyMetrics: [])

    init(generatedAt: Date = Date(), dailyMetrics: [WorkflowDailyMetrics]) {
        self.generatedAt = generatedAt
        self.dailyMetrics = dailyMetrics
    }

    init(dailyAggregates: [WorkflowDailyAggregate], generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        dailyMetrics = dailyAggregates
            .map(\.metrics)
            .sorted { $0.startDate < $1.startDate }
    }

    init(
        localAggregates: [WorkflowDailyAggregate],
        syncedRecords: [WorkflowSyncedDailyRecord],
        currentDeviceId: String?,
        generatedAt: Date = Date()
    ) {
        self.generatedAt = generatedAt

        var metricsByDate = [String: WorkflowDailyMetrics]()
        localAggregates
            .map(\.metrics)
            .forEach { Self.merge($0, into: &metricsByDate) }

        syncedRecords
            .filter { $0.deviceId != currentDeviceId }
            .map(\.daily.metrics)
            .forEach { Self.merge($0, into: &metricsByDate) }

        dailyMetrics = metricsByDate.values.sorted { $0.startDate < $1.startDate }
    }

    func recentWeekGrid(columnCount: Int, endingDaysAgo: Int = 0, today: Date = Date()) -> [WorkflowDailyMetrics?] {
        let metricsByDate = dailyMetrics.reduce(into: [String: WorkflowDailyMetrics]()) { result, metrics in
            result[metrics.startDate] = metrics
        }

        return CodexWeekGrid.dates(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        .map { date in
            date.map {
                let startDate = CodexDateFormat.dayString(from: $0)
                return metricsByDate[startDate] ?? WorkflowDailyMetrics.empty(startDate: startDate)
            }
        }
    }

    private static func merge(
        _ metrics: WorkflowDailyMetrics,
        into metricsByDate: inout [String: WorkflowDailyMetrics]
    ) {
        if let existing = metricsByDate[metrics.startDate] {
            metricsByDate[metrics.startDate] = existing.adding(metrics)
        } else {
            metricsByDate[metrics.startDate] = metrics
        }
    }
}

/// 聚合时保留 Set 缓存, 避免同一会话或轮次重复计数
nonisolated struct WorkflowDailyIdentifierCache {
    var sessionIds: Set<String>
    var turnIds: Set<String>

    init(aggregate: WorkflowDailyAggregate) {
        sessionIds = Set(aggregate.sessionIds ?? [])
        turnIds = Set(aggregate.turnIds ?? [])
    }
}

/// daily.jsonl 中的持久化聚合行, 同时兼容保留 ID 和只保留计数两种形态
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
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var sessionIds: [String]?
    var turnIds: [String]?

    var id: String {
        date
    }

    init(date: String) {
        self.date = date
        eventCount = 0
        sessionStartCount = 0
        stopCount = 0
        preToolUseCount = 0
        postToolUseCount = 0
        permissionRequestCount = 0
        preCompactCount = 0
        postCompactCount = 0
        subagentStartCount = 0
        subagentStopCount = 0
        sessionCount = nil
        turnCount = nil
        projectCounts = [:]
        sessionIds = []
        turnIds = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount) ?? 0
        sessionStartCount = try container.decodeIfPresent(Int.self, forKey: .sessionStartCount) ?? 0
        stopCount = try container.decodeIfPresent(Int.self, forKey: .stopCount) ?? 0
        preToolUseCount = try container.decodeIfPresent(Int.self, forKey: .preToolUseCount) ?? 0
        postToolUseCount = try container.decodeIfPresent(Int.self, forKey: .postToolUseCount) ?? 0
        permissionRequestCount = try container.decodeIfPresent(Int.self, forKey: .permissionRequestCount) ?? 0
        preCompactCount = try container.decodeIfPresent(Int.self, forKey: .preCompactCount) ?? 0
        postCompactCount = try container.decodeIfPresent(Int.self, forKey: .postCompactCount) ?? 0
        subagentStartCount = try container.decodeIfPresent(Int.self, forKey: .subagentStartCount) ?? 0
        subagentStopCount = try container.decodeIfPresent(Int.self, forKey: .subagentStopCount) ?? 0
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        sessionIds = try container.decodeIfPresent([String].self, forKey: .sessionIds)
        turnIds = try container.decodeIfPresent([String].self, forKey: .turnIds)
    }

    mutating func record(
        _ event: WorkflowHookEvent,
        keepsIdentifiers: Bool,
        identifierCache: inout WorkflowDailyIdentifierCache
    ) {
        eventCount += 1

        switch event.hookEvent {
        case .sessionStart: sessionStartCount += 1
        case .stop: stopCount += 1
        case .preToolUse: preToolUseCount += 1
        case .postToolUse: postToolUseCount += 1
        case .permissionRequest: permissionRequestCount += 1
        case .preCompact: preCompactCount += 1
        case .postCompact: postCompactCount += 1
        case .subagentStart: subagentStartCount += 1
        case .subagentStop: subagentStopCount += 1
        case .userPromptSubmit:
            break
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

    // 会话/轮次最终值: 优先使用去重/压缩后的数量
    // 起止事件计数只作为缺失兜底
    private var resolvedSessionCount: Int {
        sessionCount ?? sessionIds?.count ?? sessionStartCount
    }

    private var resolvedTurnCount: Int {
        turnCount ?? turnIds?.count ?? stopCount
    }

    var metrics: WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: date,
            sessionCount: resolvedSessionCount,
            turnCount: resolvedTurnCount,
            preToolUseCount: preToolUseCount,
            postToolUseCount: postToolUseCount,
            permissionRequestCount: permissionRequestCount,
            preCompactCount: preCompactCount,
            postCompactCount: postCompactCount,
            subagentStartCount: subagentStartCount,
            subagentStopCount: subagentStopCount
        )
    }

    static func normalized(
        aggregates: [WorkflowDailyAggregate],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [WorkflowDailyAggregate] {
        let retentionCutoffDate = WorkflowStorage.retentionCutoffDate(today: today, calendar: calendar)
        let identifierCutoffDate = WorkflowStorage.identifierRetentionCutoffDate(today: today, calendar: calendar)

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
            try result.append(aggregate.jsonLineData())
        }
    }

    func jsonLineData() throws -> Data {
        let fields = try [
            WorkflowJSON.field("date", date),
            WorkflowJSON.field("eventCount", eventCount),
            WorkflowJSON.field("sessionStartCount", sessionStartCount),
            WorkflowJSON.field("stopCount", stopCount),
            WorkflowJSON.field("preToolUseCount", preToolUseCount),
            WorkflowJSON.field("postToolUseCount", postToolUseCount),
            WorkflowJSON.field("permissionRequestCount", permissionRequestCount),
            WorkflowJSON.field("preCompactCount", preCompactCount),
            WorkflowJSON.field("postCompactCount", postCompactCount),
            WorkflowJSON.field("subagentStartCount", subagentStartCount),
            WorkflowJSON.field("subagentStopCount", subagentStopCount),
            WorkflowJSON.field("sessionCount", sessionCount),
            WorkflowJSON.field("turnCount", turnCount),
            WorkflowJSON.field("projectCounts", projectCounts),
            WorkflowJSON.field("sessionIds", sessionIds),
            WorkflowJSON.field("turnIds", turnIds)
        ]

        return WorkflowJSON.lineData(fields)
    }

    var syncedAggregate: WorkflowSyncedDailyAggregate {
        WorkflowSyncedDailyAggregate(
            date: date,
            eventCount: eventCount,
            sessionStartCount: sessionStartCount,
            stopCount: stopCount,
            preToolUseCount: preToolUseCount,
            postToolUseCount: postToolUseCount,
            permissionRequestCount: permissionRequestCount,
            preCompactCount: preCompactCount,
            postCompactCount: postCompactCount,
            subagentStartCount: subagentStartCount,
            subagentStopCount: subagentStopCount,
            sessionCount: syncedSessionCount,
            turnCount: syncedTurnCount,
            projectCounts: projectCounts
        )
    }

    private var syncedSessionCount: Int? {
        sessionCount ?? Self.nonEmptyIdentifierCount(sessionIds)
    }

    private var syncedTurnCount: Int? {
        turnCount ?? Self.nonEmptyIdentifierCount(turnIds)
    }

    private static func nonEmptyIdentifierCount(_ identifiers: [String]?) -> Int? {
        guard let identifiers, !identifiers.isEmpty else {
            return nil
        }

        return Set(identifiers).count
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

    private static func date(from string: String) -> Date? {
        CodexDateFormat.dayDate(from: string)
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
        case sessionCount
        case turnCount
        case projectCounts
        case sessionIds
        case turnIds
    }
}

/// 同步存储中保存的脱敏每日聚合行: 对应 daily.jsonl 但不包含 sessionIds / turnIds
nonisolated struct WorkflowSyncedDailyAggregate: Codable, Equatable, Identifiable {
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
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]

    var id: String {
        date
    }

    var metrics: WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: date,
            sessionCount: sessionCount ?? sessionStartCount,
            turnCount: turnCount ?? stopCount,
            preToolUseCount: preToolUseCount,
            postToolUseCount: postToolUseCount,
            permissionRequestCount: permissionRequestCount,
            preCompactCount: preCompactCount,
            postCompactCount: postCompactCount,
            subagentStartCount: subagentStartCount,
            subagentStopCount: subagentStopCount
        )
    }

    func jsonLineData() throws -> Data {
        let fields = try [
            WorkflowJSON.field("date", date),
            WorkflowJSON.field("eventCount", eventCount),
            WorkflowJSON.field("sessionStartCount", sessionStartCount),
            WorkflowJSON.field("stopCount", stopCount),
            WorkflowJSON.field("preToolUseCount", preToolUseCount),
            WorkflowJSON.field("postToolUseCount", postToolUseCount),
            WorkflowJSON.field("permissionRequestCount", permissionRequestCount),
            WorkflowJSON.field("preCompactCount", preCompactCount),
            WorkflowJSON.field("postCompactCount", postCompactCount),
            WorkflowJSON.field("subagentStartCount", subagentStartCount),
            WorkflowJSON.field("subagentStopCount", subagentStopCount),
            WorkflowJSON.field("sessionCount", sessionCount),
            WorkflowJSON.field("turnCount", turnCount),
            WorkflowJSON.field("projectCounts", projectCounts)
        ]

        return WorkflowJSON.lineData(fields)
    }
}

nonisolated struct WorkflowSyncedDailyRecord: Codable, Equatable, Identifiable {
    let deviceId: String
    let daily: WorkflowSyncedDailyAggregate
    var updatedAt: Date?

    var id: String {
        Self.id(deviceId: deviceId, date: daily.date)
    }

    var date: String {
        daily.date
    }

    static func id(deviceId: String, date: String) -> String {
        "\(deviceId)|\(date)"
    }
}
