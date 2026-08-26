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

    static func presentCountFields(_ values: [(String, Int?)]) throws -> [String] {
        try values.compactMap { name, value in
            guard let value else {
                return nil
            }
            return try field(name, value)
        }
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

        if let identifiers, !identifiers.isEmpty {
            return Set(identifiers).count
        }

        return compactedCount == 0 ? 0 : nil
    }

    static func resolvedCount(
        compactedCount: Int?,
        identifiers: [String]? = nil,
        fallback: Int
    ) -> Int {
        preferredCount(compactedCount: compactedCount, identifiers: identifiers) ?? fallback
    }
}

// MARK: - Hook 原始事件

/// Hook 事件来源的本地归一化分类, 不保留 rollout 中的原始 source 内容
nonisolated enum WorkflowEventOrigin: String, Codable, Sendable {
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

/// hooks 进程落盘和读取的最小事件模型, 在边界归一化来源并对历史字段缺失保持宽容
nonisolated struct WorkflowHookEvent: Decodable, Equatable {
    let timestamp: Date
    let name: String
    let origin: WorkflowEventOrigin
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
        origin: WorkflowEventOrigin,
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
        self.origin = Self.resolvedOrigin(origin, modelName: modelName)
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

        let decodedOrigin = (try? container.decode(WorkflowEventOrigin.self, forKey: .origin)) ?? .unknown
        let decodedModelName = Self.string(from: container, key: .modelName)

        self.timestamp = timestamp
        self.name = name
        origin = Self.resolvedOrigin(decodedOrigin, modelName: decodedModelName)
        directoryPath = Self.string(from: container, key: .cwd)
        toolName = Self.string(from: container, key: .toolName)
        modelName = decodedModelName
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

    /// Ephemeral Guardian 没有 rollout path, canonical model 是来源判定的可靠后备
    private static func resolvedOrigin(
        _ origin: WorkflowEventOrigin,
        modelName: String?
    ) -> WorkflowEventOrigin {
        guard origin == .unknown,
              modelName == autoReviewModelName else {
            return origin
        }
        return .autoReview
    }

    func jsonLineData() throws -> Data {
        let fields = try [
            WorkflowJSON.field("timestamp", CodexDateFormat.localTimestampString(from: timestamp)),
            WorkflowJSON.field("event", name),
            WorkflowJSON.field("origin", origin),
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
        case origin
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

    private static let autoReviewModelName = "codex-auto-review"
}

// MARK: - 每日聚合指标

/// 热力图详情面板直接消费的每日统计
nonisolated struct WorkflowDailyMetrics: Equatable {
    let startDate: String
    let sessionCount: Int
    let turnCount: Int
    let toolCallCount: Int
    let permissionRequestCount: Int
    let contextCompactionCount: Int
    let subagentCount: Int
    let modelCounts: [String: Int]

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

// MARK: - 面板快照

/// WorkflowService 发布给 UI 的近端快照
nonisolated struct WorkflowSnapshot: Equatable {
    let dailyMetrics: [WorkflowDailyMetrics]

    static let empty = WorkflowSnapshot(dailyMetrics: [])

    init(dailyMetrics: [WorkflowDailyMetrics]) {
        self.dailyMetrics = dailyMetrics
    }

    /// 同 generation 只采用一份数据; 确认独立的新 generation 与历史贡献累加
    init(
        localAggregates: [WorkflowDailyAggregate],
        syncedRecords: [WorkflowSyncedDailyRecord],
        currentDeviceId: String?
    ) {
        var metricsByDate = [String: WorkflowDailyMetrics]()

        let localByDate = Dictionary(uniqueKeysWithValues: localAggregates.map { ($0.date, $0) })
        let currentDeviceRecords = syncedRecords.filter { $0.deviceId == currentDeviceId }
        let otherDeviceRecords = syncedRecords.filter { $0.deviceId != currentDeviceId }

        Self.merge(otherDeviceRecords, into: &metricsByDate)

        let remoteByDate = Dictionary(grouping: currentDeviceRecords, by: \.date)
        let currentDeviceDates = Set(localByDate.keys).union(remoteByDate.keys)
        for date in currentDeviceDates {
            Self.mergeCurrentDeviceDate(
                local: localByDate[date],
                remoteRecords: remoteByDate[date] ?? [],
                into: &metricsByDate
            )
        }

        dailyMetrics = metricsByDate.values.sorted { $0.startDate < $1.startDate }
    }

    private static func mergeCurrentDeviceDate(
        local: WorkflowDailyAggregate?,
        remoteRecords: [WorkflowSyncedDailyRecord],
        into metricsByDate: inout [String: WorkflowDailyMetrics]
    ) {
        guard let local else {
            merge(remoteRecords, into: &metricsByDate)
            return
        }

        let matchingIndex = remoteRecords.firstIndex {
            local.syncedAggregate.matchesRemoteSource($0.daily)
        }

        guard remoteRecords.isEmpty || local.sourceIsFresh || matchingIndex != nil else {
            merge(remoteRecords, into: &metricsByDate)
            return
        }

        for (index, record) in remoteRecords.enumerated() where index != matchingIndex {
            merge(record.daily.metrics, into: &metricsByDate)
        }

        if let matchingIndex,
           (remoteRecords[matchingIndex].daily.eventCount ?? 0) > (local.eventCount ?? 0) {
            merge(remoteRecords[matchingIndex].daily.metrics, into: &metricsByDate)
        } else {
            merge(local.metrics, into: &metricsByDate)
        }
    }

    private static func merge(
        _ records: [WorkflowSyncedDailyRecord],
        into metricsByDate: inout [String: WorkflowDailyMetrics]
    ) {
        for record in records {
            merge(record.daily.metrics, into: &metricsByDate)
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

// MARK: - 每日事件聚合

/// ID 保留期限只决定最终存储形态, 不能影响聚合结果
nonisolated enum WorkflowIdentifierStorage {
    case retained
    case compacted
}

/// 从原始事件生成每日聚合的纯内存累加器
/// 全量和增量路径都收集 ID, 只有 finalize 时才按保留策略决定是否落盘
nonisolated struct WorkflowDailyAccumulator {
    private var aggregate: WorkflowDailyAggregate
    private var sessionIds: Set<String> = []
    private var turnIds: Set<String> = []

    init(
        rebuilding date: String,
        sourceGeneration: String?,
        sourceIsFresh: Bool,
        hookCountAvailability: WorkflowHookCountAvailability
    ) {
        aggregate = WorkflowDailyAggregate(
            date: date,
            sourceGeneration: sourceGeneration,
            sourceIsFresh: sourceIsFresh,
            hookCountAvailability: hookCountAvailability
        )
    }

    init(
        appending aggregate: WorkflowDailyAggregate,
        sourceGeneration: String?,
        sourceIsFresh: Bool
    ) {
        var aggregate = aggregate
        aggregate.sourceGeneration = sourceGeneration
        aggregate.sourceIsFresh = sourceIsFresh
        self.aggregate = aggregate
        sessionIds = Set(aggregate.sessionIds ?? [])
        turnIds = Set(aggregate.turnIds ?? [])
    }

    mutating func record(_ event: WorkflowHookEvent) {
        // origin 只控制实时活动过滤, 历史统计按全部 Hook 事实保持原口径
        Self.increment(&aggregate.eventCount)

        switch event.hookEvent {
        case .sessionStart: Self.increment(&aggregate.sessionStartCount)
        case .sessionEnd: Self.increment(&aggregate.sessionEndCount)
        case .userPromptSubmit: Self.increment(&aggregate.userPromptSubmitCount)
        case .stop: Self.increment(&aggregate.stopCount)
        case .preToolUse: Self.increment(&aggregate.preToolUseCount)
        case .postToolUse: Self.increment(&aggregate.postToolUseCount)
        case .permissionRequest: Self.increment(&aggregate.permissionRequestCount)
        case .preCompact: Self.increment(&aggregate.preCompactCount)
        case .postCompact: Self.increment(&aggregate.postCompactCount)
        case .subagentStart: Self.increment(&aggregate.subagentStartCount)
        case .subagentStop: Self.increment(&aggregate.subagentStopCount)
        case .none: break
        }

        if let sessionId = event.sessionId {
            sessionIds.insert(sessionId)
        }
        if let turnId = event.turnId {
            turnIds.insert(turnId)
        }

        if let projectDisplayName = event.projectDisplayName {
            aggregate.projectCounts[projectDisplayName, default: 0] += 1
        }
        if let modelName = event.modelName {
            aggregate.modelCounts[modelName, default: 0] += 1
        }
    }

    func finalized(identifierStorage: WorkflowIdentifierStorage) -> WorkflowDailyAggregate {
        var aggregate = aggregate
        switch identifierStorage {
        case .retained:
            aggregate.sessionCount = nil
            aggregate.turnCount = nil
            aggregate.sessionIds = Self.normalizedIdentifiers(sessionIds)
            aggregate.turnIds = Self.normalizedIdentifiers(turnIds)
        case .compacted:
            aggregate.sessionCount = sessionIds.isEmpty
                ? aggregate.sessionStartCount
                : sessionIds.count
            aggregate.turnCount = turnIds.isEmpty
                ? aggregate.stopCount
                : turnIds.count
            aggregate.sessionIds = nil
            aggregate.turnIds = nil
        }
        return aggregate
    }

    private static func increment(_ count: inout Int?) {
        count = (count ?? 0) + 1
    }

    private static func normalizedIdentifiers(_ identifiers: Set<String>) -> [String]? {
        let normalized = identifiers.sorted()
        return normalized.isEmpty ? nil : normalized
    }
}

/// 全量重放时保留每个 Hook 计数字段原有的可用性
nonisolated struct WorkflowHookCountAvailability {
    static let all = WorkflowHookCountAvailability(
        includesEventCount: true,
        events: Set(CodexHookEvent.allCases)
    )

    private let includesEventCount: Bool
    private let events: Set<CodexHookEvent>

    init(aggregate: WorkflowDailyAggregate) {
        includesEventCount = aggregate.eventCount != nil
        events = Set(CodexHookEvent.allCases.filter { aggregate.hookCount(for: $0) != nil })
    }

    private init(includesEventCount: Bool, events: Set<CodexHookEvent>) {
        self.includesEventCount = includesEventCount
        self.events = events
    }

    var initialEventCount: Int? {
        includesEventCount ? 0 : nil
    }

    func initialCount(for event: CodexHookEvent) -> Int? {
        events.contains(event) ? 0 : nil
    }
}

/// daily.jsonl 中的持久化聚合行, 同时兼容保留 ID 和只保留计数两种形态
nonisolated struct WorkflowDailyAggregate: Codable, Equatable {
    let date: String
    var sourceGeneration: String?
    var sourceIsFresh: Bool
    var eventCount: Int?
    var sessionStartCount: Int?
    var sessionEndCount: Int?
    var userPromptSubmitCount: Int?
    var stopCount: Int?
    var preToolUseCount: Int?
    var postToolUseCount: Int?
    var permissionRequestCount: Int?
    var preCompactCount: Int?
    var postCompactCount: Int?
    var subagentStartCount: Int?
    var subagentStopCount: Int?
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var modelCounts: [String: Int]
    var sessionIds: [String]?
    var turnIds: [String]?

    /// 增量路径只有在完整 ID 集合仍然存在时才能继续安全去重
    var supportsIncrementalAggregation: Bool {
        sessionCount == nil && turnCount == nil
    }

    init(
        date: String,
        sourceGeneration: String? = nil,
        sourceIsFresh: Bool = false,
        hookCountAvailability: WorkflowHookCountAvailability = .all
    ) {
        self.date = date
        self.sourceGeneration = sourceGeneration
        self.sourceIsFresh = sourceIsFresh
        eventCount = hookCountAvailability.initialEventCount
        sessionStartCount = hookCountAvailability.initialCount(for: .sessionStart)
        sessionEndCount = hookCountAvailability.initialCount(for: .sessionEnd)
        userPromptSubmitCount = hookCountAvailability.initialCount(for: .userPromptSubmit)
        stopCount = hookCountAvailability.initialCount(for: .stop)
        preToolUseCount = hookCountAvailability.initialCount(for: .preToolUse)
        postToolUseCount = hookCountAvailability.initialCount(for: .postToolUse)
        permissionRequestCount = hookCountAvailability.initialCount(for: .permissionRequest)
        preCompactCount = hookCountAvailability.initialCount(for: .preCompact)
        postCompactCount = hookCountAvailability.initialCount(for: .postCompact)
        subagentStartCount = hookCountAvailability.initialCount(for: .subagentStart)
        subagentStopCount = hookCountAvailability.initialCount(for: .subagentStop)
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
        sourceGeneration = try container.decodeIfPresent(String.self, forKey: .sourceGeneration)
        sourceIsFresh = try container.decodeIfPresent(Bool.self, forKey: .sourceIsFresh) ?? false
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
        sessionStartCount = try container.decodeIfPresent(Int.self, forKey: .sessionStartCount)
        sessionEndCount = try container.decodeIfPresent(Int.self, forKey: .sessionEndCount)
        userPromptSubmitCount = try container.decodeIfPresent(Int.self, forKey: .userPromptSubmitCount)
        stopCount = try container.decodeIfPresent(Int.self, forKey: .stopCount)
        preToolUseCount = try container.decodeIfPresent(Int.self, forKey: .preToolUseCount)
        postToolUseCount = try container.decodeIfPresent(Int.self, forKey: .postToolUseCount)
        permissionRequestCount = try container.decodeIfPresent(Int.self, forKey: .permissionRequestCount)
        preCompactCount = try container.decodeIfPresent(Int.self, forKey: .preCompactCount)
        postCompactCount = try container.decodeIfPresent(Int.self, forKey: .postCompactCount)
        subagentStartCount = try container.decodeIfPresent(Int.self, forKey: .subagentStartCount)
        subagentStopCount = try container.decodeIfPresent(Int.self, forKey: .subagentStopCount)
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
        sessionIds = try container.decodeIfPresent([String].self, forKey: .sessionIds)
        turnIds = try container.decodeIfPresent([String].self, forKey: .turnIds)
    }

    mutating func normalizeIdentifierStorage(retainsIdentifiers: Bool) {
        guard !retainsIdentifiers else {
            sessionIds = Self.normalizedIdentifiers(sessionIds)
            turnIds = Self.normalizedIdentifiers(turnIds)
            return
        }

        sessionCount = WorkflowCountResolution.preferredCount(
            compactedCount: sessionCount,
            identifiers: sessionIds
        ) ?? sessionStartCount
        turnCount = WorkflowCountResolution.preferredCount(
            compactedCount: turnCount,
            identifiers: turnIds
        ) ?? stopCount
        sessionIds = nil
        turnIds = nil
    }

    /// 正数压缩计数和非空 ID 集合优先, 明确的 0 在没有 ID 时同样有效
    private var resolvedSessionCount: Int {
        WorkflowCountResolution.resolvedCount(
            compactedCount: sessionCount,
            identifiers: sessionIds,
            fallback: sessionStartCount ?? 0
        )
    }

    private var resolvedTurnCount: Int {
        WorkflowCountResolution.resolvedCount(
            compactedCount: turnCount,
            identifiers: turnIds,
            fallback: stopCount ?? 0
        )
    }

    var metrics: WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: date,
            sessionCount: resolvedSessionCount,
            turnCount: resolvedTurnCount,
            preToolUseCount: preToolUseCount ?? 0,
            postToolUseCount: postToolUseCount ?? 0,
            permissionRequestCount: permissionRequestCount ?? 0,
            preCompactCount: preCompactCount ?? 0,
            postCompactCount: postCompactCount ?? 0,
            subagentStartCount: subagentStartCount ?? 0,
            subagentStopCount: subagentStopCount ?? 0,
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
            mutableAggregate.normalizeIdentifierStorage(
                retainsIdentifiers: date >= identifierCutoffDate
            )
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
        var fields = try [
            WorkflowJSON.field("date", date),
            WorkflowJSON.field("sourceGeneration", sourceGeneration),
            WorkflowJSON.field("sourceIsFresh", sourceIsFresh)
        ]
        try fields.append(contentsOf: WorkflowJSON.presentCountFields(hookCountFields))
        try fields.append(contentsOf: [
            WorkflowJSON.field("sessionCount", sessionCount),
            WorkflowJSON.field("turnCount", turnCount),
            WorkflowJSON.field("projectCounts", projectCounts),
            WorkflowJSON.field("modelCounts", modelCounts),
            WorkflowJSON.field("sessionIds", sessionIds),
            WorkflowJSON.field("turnIds", turnIds)
        ])

        return WorkflowJSON.lineData(fields)
    }

    var hookCountAvailability: WorkflowHookCountAvailability {
        WorkflowHookCountAvailability(aggregate: self)
    }

    func hookCount(for event: CodexHookEvent) -> Int? {
        switch event {
        case .sessionStart: sessionStartCount
        case .sessionEnd: sessionEndCount
        case .userPromptSubmit: userPromptSubmitCount
        case .stop: stopCount
        case .preToolUse: preToolUseCount
        case .postToolUse: postToolUseCount
        case .permissionRequest: permissionRequestCount
        case .preCompact: preCompactCount
        case .postCompact: postCompactCount
        case .subagentStart: subagentStartCount
        case .subagentStop: subagentStopCount
        }
    }

    var syncedAggregate: WorkflowSyncedDailyAggregate {
        WorkflowSyncedDailyAggregate(
            date: date,
            sourceGeneration: sourceGeneration,
            eventCount: eventCount,
            sessionStartCount: sessionStartCount,
            sessionEndCount: sessionEndCount,
            userPromptSubmitCount: userPromptSubmitCount,
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

    private var hookCountFields: [(String, Int?)] {
        [
            ("eventCount", eventCount),
            ("sessionStartCount", sessionStartCount),
            ("sessionEndCount", sessionEndCount),
            ("userPromptSubmitCount", userPromptSubmitCount),
            ("stopCount", stopCount),
            ("preToolUseCount", preToolUseCount),
            ("postToolUseCount", postToolUseCount),
            ("permissionRequestCount", permissionRequestCount),
            ("preCompactCount", preCompactCount),
            ("postCompactCount", postCompactCount),
            ("subagentStartCount", subagentStartCount),
            ("subagentStopCount", subagentStopCount)
        ]
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
        case sourceGeneration
        case sourceIsFresh
        case eventCount
        case sessionStartCount
        case sessionEndCount
        case userPromptSubmitCount
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
nonisolated struct WorkflowSyncedDailyAggregate: Codable, Equatable {
    let date: String
    var sourceGeneration: String?
    var eventCount: Int?
    var sessionStartCount: Int?
    var sessionEndCount: Int?
    var userPromptSubmitCount: Int?
    var stopCount: Int?
    var preToolUseCount: Int?
    var postToolUseCount: Int?
    var permissionRequestCount: Int?
    var preCompactCount: Int?
    var postCompactCount: Int?
    var subagentStartCount: Int?
    var subagentStopCount: Int?
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var modelCounts: [String: Int]

    var metrics: WorkflowDailyMetrics {
        WorkflowDailyMetrics(
            startDate: date,
            sessionCount: WorkflowCountResolution.resolvedCount(
                compactedCount: sessionCount,
                fallback: sessionStartCount ?? 0
            ),
            turnCount: WorkflowCountResolution.resolvedCount(
                compactedCount: turnCount,
                fallback: stopCount ?? 0
            ),
            preToolUseCount: preToolUseCount ?? 0,
            postToolUseCount: postToolUseCount ?? 0,
            permissionRequestCount: permissionRequestCount ?? 0,
            preCompactCount: preCompactCount ?? 0,
            postCompactCount: postCompactCount ?? 0,
            subagentStartCount: subagentStartCount ?? 0,
            subagentStopCount: subagentStopCount ?? 0,
            modelCounts: modelCounts
        )
    }

    func jsonLineData() throws -> Data {
        var fields = try [
            WorkflowJSON.field("date", date),
            WorkflowJSON.field("sourceGeneration", sourceGeneration)
        ]
        try fields.append(contentsOf: WorkflowJSON.presentCountFields(hookCountFields))
        try fields.append(contentsOf: [
            WorkflowJSON.field("sessionCount", sessionCount),
            WorkflowJSON.field("turnCount", turnCount),
            WorkflowJSON.field("projectCounts", projectCounts),
            WorkflowJSON.field("modelCounts", modelCounts)
        ])

        return WorkflowJSON.lineData(fields)
    }

    private var hookCountFields: [(String, Int?)] {
        [
            ("eventCount", eventCount),
            ("sessionStartCount", sessionStartCount),
            ("sessionEndCount", sessionEndCount),
            ("userPromptSubmitCount", userPromptSubmitCount),
            ("stopCount", stopCount),
            ("preToolUseCount", preToolUseCount),
            ("postToolUseCount", postToolUseCount),
            ("permissionRequestCount", permissionRequestCount),
            ("preCompactCount", preCompactCount),
            ("postCompactCount", postCompactCount),
            ("subagentStartCount", subagentStartCount),
            ("subagentStopCount", subagentStopCount)
        ]
    }

    func hasSameContent(as other: WorkflowSyncedDailyAggregate) -> Bool {
        var lhs = self
        var rhs = other
        lhs.sourceGeneration = nil
        rhs.sourceGeneration = nil
        return lhs == rhs
    }

    func matchesRemoteSource(_ remote: WorkflowSyncedDailyAggregate) -> Bool {
        if let sourceGeneration,
           remote.sourceGeneration == sourceGeneration {
            return true
        }
        return remote.sourceGeneration == nil && hasSameContent(as: remote)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case sourceGeneration
        case eventCount
        case sessionStartCount
        case sessionEndCount
        case userPromptSubmitCount
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
    }
}

extension WorkflowSyncedDailyAggregate {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        sourceGeneration = try container.decodeIfPresent(String.self, forKey: .sourceGeneration)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
        sessionStartCount = try container.decodeIfPresent(Int.self, forKey: .sessionStartCount)
        sessionEndCount = try container.decodeIfPresent(Int.self, forKey: .sessionEndCount)
        userPromptSubmitCount = try container.decodeIfPresent(Int.self, forKey: .userPromptSubmitCount)
        stopCount = try container.decodeIfPresent(Int.self, forKey: .stopCount)
        preToolUseCount = try container.decodeIfPresent(Int.self, forKey: .preToolUseCount)
        postToolUseCount = try container.decodeIfPresent(Int.self, forKey: .postToolUseCount)
        permissionRequestCount = try container.decodeIfPresent(Int.self, forKey: .permissionRequestCount)
        preCompactCount = try container.decodeIfPresent(Int.self, forKey: .preCompactCount)
        postCompactCount = try container.decodeIfPresent(Int.self, forKey: .postCompactCount)
        subagentStartCount = try container.decodeIfPresent(Int.self, forKey: .subagentStartCount)
        subagentStopCount = try container.decodeIfPresent(Int.self, forKey: .subagentStopCount)
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
    }
}

nonisolated struct WorkflowSyncedDailyRecord: Codable, Equatable, Identifiable {
    let deviceId: String
    let daily: WorkflowSyncedDailyAggregate
    var updatedAt: Date?
    var recordName: String?

    var id: String {
        recordName ?? Self.legacyRecordName(deviceId: deviceId, date: daily.date)
    }

    var date: String {
        daily.date
    }

    static func legacyRecordName(deviceId: String, date: String) -> String {
        "\(deviceId)_\(date)"
    }
}
