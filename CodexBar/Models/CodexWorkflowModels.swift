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
        let data = try JSONLines.stableEncoder.encode(value)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Encoded workflow JSON was not UTF-8")
            )
        }
        return text
    }
}

private nonisolated enum WorkflowCountResolution {
    static func preferredCount(
        compactedCount: Int?,
        identifiers: [String]? = nil
    ) -> Int? {
        if let compactedCount, compactedCount > 0 {
            return compactedCount
        }

        guard let identifiers, !identifiers.isEmpty else {
            return nil
        }

        return Set(identifiers).count
    }

    static func resolvedCount(
        compactedCount: Int?,
        identifiers: [String]? = nil,
        fallback: Int
    ) -> Int {
        preferredCount(compactedCount: compactedCount, identifiers: identifiers) ?? fallback
    }
}

/// hooks 进程落盘的最小事件模型, 对历史字段缺失保持宽容
nonisolated struct WorkflowHookEvent: Decodable, Equatable {
    let timestamp: Date
    let name: String
    let directoryPath: String?
    let toolName: String?
    let modelName: String?
    let effort: String?
    let permissionMode: String?
    let approvalReviewer: CodexApprovalReviewer?
    let sessionId: String?
    let turnId: String?
    let agentId: String?

    init(
        timestamp: Date,
        name: String,
        directoryPath: String?,
        toolName: String?,
        modelName: String?,
        effort: String?,
        permissionMode: String?,
        approvalReviewer: CodexApprovalReviewer?,
        sessionId: String?,
        turnId: String?,
        agentId: String?
    ) {
        self.timestamp = timestamp
        self.name = name
        self.directoryPath = directoryPath
        self.toolName = toolName
        self.modelName = modelName
        self.effort = effort
        self.permissionMode = permissionMode
        self.approvalReviewer = approvalReviewer
        self.sessionId = sessionId
        self.turnId = turnId
        self.agentId = agentId
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
        effort = Self.string(from: container, key: .effort)
        permissionMode = Self.string(from: container, key: .permissionMode)
        approvalReviewer = try? container.decode(
            CodexApprovalReviewer.self,
            forKey: .approvalReviewer
        )
        sessionId = Self.string(from: container, key: .sessionId)
        turnId = Self.string(from: container, key: .turnId)
        agentId = Self.string(from: container, key: .agentId)
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
        guard let value = try? container.decode(String.self, forKey: key) else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    private static func date(from string: String) -> Date? {
        CodexDateFormat.localTimestampDate(from: string)
    }

    func jsonLineData() throws -> Data {
        let fields = try [
            WorkflowJSON.field("timestamp", CodexDateFormat.localTimestampString(from: timestamp)),
            WorkflowJSON.field("event", name),
            WorkflowJSON.field("model", modelName),
            WorkflowJSON.field("effort", effort),
            WorkflowJSON.field("permission", permissionMode),
            WorkflowJSON.field("approval", approvalReviewer),
            WorkflowJSON.field("session", sessionId),
            WorkflowJSON.field("turn", turnId),
            WorkflowJSON.field("agent", agentId),
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
        case effort
        case permissionMode = "permission"
        case approvalReviewer = "approval"
        case sessionId = "session"
        case turnId = "turn"
        case agentId = "agent"
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
    let modelCounts: [String: Int]

    var id: String {
        startDate
    }

    var mostUsedModel: String? {
        modelCounts
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            .first?.key
    }

    init(
        startDate: String,
        sessionCount: Int,
        turnCount: Int,
        toolCallCount: Int,
        permissionRequestCount: Int,
        contextCompactionCount: Int,
        subagentCount: Int,
        modelCounts: [String: Int] = [:]
    ) {
        self.startDate = startDate
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.permissionRequestCount = permissionRequestCount
        self.contextCompactionCount = contextCompactionCount
        self.subagentCount = subagentCount
        self.modelCounts = modelCounts
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
        subagentStopCount: Int,
        modelCounts: [String: Int]
    ) {
        self.startDate = startDate
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        toolCallCount = max(preToolUseCount, postToolUseCount)
        self.permissionRequestCount = permissionRequestCount
        contextCompactionCount = max(preCompactCount, postCompactCount)
        subagentCount = max(subagentStartCount, subagentStopCount)
        self.modelCounts = modelCounts
    }

    func adding(_ other: WorkflowDailyMetrics) -> WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: startDate,
            sessionCount: sessionCount + other.sessionCount,
            turnCount: turnCount + other.turnCount,
            toolCallCount: toolCallCount + other.toolCallCount,
            permissionRequestCount: permissionRequestCount + other.permissionRequestCount,
            contextCompactionCount: contextCompactionCount + other.contextCompactionCount,
            subagentCount: subagentCount + other.subagentCount,
            modelCounts: Self.mergedCounts(modelCounts, other.modelCounts)
        )
    }

    private static func mergedCounts(
        _ lhs: [String: Int],
        _ rhs: [String: Int]
    ) -> [String: Int] {
        rhs.reduce(into: lhs) { result, item in
            result[item.key, default: 0] += item.value
        }
    }
}

/// WorkflowService 发布给 UI 的近端快照
nonisolated struct WorkflowSnapshot: Equatable {
    let dailyMetrics: [WorkflowDailyMetrics]

    static let empty = WorkflowSnapshot(dailyMetrics: [])

    init(dailyMetrics: [WorkflowDailyMetrics]) {
        self.dailyMetrics = dailyMetrics
    }

    /// syncedRecords 由 WorkflowSyncService 保证不含本机设备的记录
    init(
        localAggregates: [WorkflowDailyAggregate],
        syncedRecords: [WorkflowSyncedDailyRecord]
    ) {
        var metricsByDate = [String: WorkflowDailyMetrics]()
        for aggregate in localAggregates {
            Self.merge(aggregate.metrics, into: &metricsByDate)
        }

        for record in syncedRecords {
            Self.merge(record.daily.metrics, into: &metricsByDate)
        }

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
    var modelCounts: [String: Int]
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
        modelCounts = [:]
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
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
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

        if let modelName = event.modelName {
            modelCounts[modelName, default: 0] += 1
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

    /// 只有正数压缩计数或非空 ID 集合是有效去重结果, 否则使用起止事件计数兜底
    private var resolvedSessionCount: Int {
        WorkflowCountResolution.resolvedCount(
            compactedCount: sessionCount,
            identifiers: sessionIds,
            fallback: sessionStartCount
        )
    }

    private var resolvedTurnCount: Int {
        WorkflowCountResolution.resolvedCount(
            compactedCount: turnCount,
            identifiers: turnIds,
            fallback: stopCount
        )
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
            subagentStopCount: subagentStopCount,
            modelCounts: modelCounts
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
            WorkflowJSON.field("modelCounts", modelCounts),
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
            projectCounts: projectCounts,
            modelCounts: modelCounts
        )
    }

    private var syncedSessionCount: Int? {
        WorkflowCountResolution.preferredCount(
            compactedCount: sessionCount,
            identifiers: sessionIds
        )
    }

    private var syncedTurnCount: Int? {
        WorkflowCountResolution.preferredCount(
            compactedCount: turnCount,
            identifiers: turnIds
        )
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

    private static func normalizedIdentifiers(_ identifiers: [String]?) -> [String]? {
        let normalized = Set(identifiers ?? []).sorted()
        return normalized.isEmpty ? nil : normalized
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
        case modelCounts
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
    var modelCounts: [String: Int]?

    var id: String {
        date
    }

    var metrics: WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: date,
            sessionCount: WorkflowCountResolution.resolvedCount(
                compactedCount: sessionCount,
                fallback: sessionStartCount
            ),
            turnCount: WorkflowCountResolution.resolvedCount(
                compactedCount: turnCount,
                fallback: stopCount
            ),
            preToolUseCount: preToolUseCount,
            postToolUseCount: postToolUseCount,
            permissionRequestCount: permissionRequestCount,
            preCompactCount: preCompactCount,
            postCompactCount: postCompactCount,
            subagentStartCount: subagentStartCount,
            subagentStopCount: subagentStopCount,
            modelCounts: modelCounts ?? [:]
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
            WorkflowJSON.field("projectCounts", projectCounts),
            WorkflowJSON.field("modelCounts", modelCounts)
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
