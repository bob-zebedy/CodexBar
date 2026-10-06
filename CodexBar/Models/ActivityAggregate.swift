import Foundation

// MARK: - 每日事件聚合

/// ID 保留期限只决定最终存储形态, 不能影响聚合结果
nonisolated enum ActivityIdentifiers {
    case retained
    case compacted
}

/// 从原始事件生成每日聚合的纯内存累加器
/// 全量和增量路径都收集 ID, 只有 finalize 时才按保留策略决定是否落盘
nonisolated struct ActivityAccumulator {
    private var aggregate: ActivityAggregate
    private var sessionIDs: Set<String> = []
    private var turnIDs: Set<String> = []

    init(
        rebuilding date: String,
        generationID: String?,
        generationStartedEmpty: Bool,
        eventCountAvailability: ActivityCountAvailability
    ) {
        aggregate = ActivityAggregate(
            date: date,
            generationID: generationID,
            generationStartedEmpty: generationStartedEmpty,
            eventCountAvailability: eventCountAvailability
        )
    }

    init(
        appending aggregate: ActivityAggregate,
        generationID: String?,
        generationStartedEmpty: Bool
    ) {
        var aggregate = aggregate
        aggregate.generationID = generationID
        aggregate.generationStartedEmpty = generationStartedEmpty
        self.aggregate = aggregate
        sessionIDs = Set(aggregate.sessionIDs ?? [])
        turnIDs = Set(aggregate.turnIDs ?? [])
    }

    mutating func record(_ event: ActivityRecord) {
        // origin 只控制实时活动过滤, 历史统计按全部业务事件事实保持原口径
        Self.increment(&aggregate.eventCount)

        switch event.eventKind {
        case .sessionStarted: Self.increment(&aggregate.sessionStartedCount)
        case .sessionEnded: Self.increment(&aggregate.sessionEndedCount)
        case .turnStarted: Self.increment(&aggregate.turnStartedCount)
        case .turnCompleted: Self.increment(&aggregate.turnCompletedCount)
        case .turnAborted: Self.increment(&aggregate.turnAbortedCount)
        case .toolStarted: Self.increment(&aggregate.toolStartedCount)
        case .toolCompleted: Self.increment(&aggregate.toolCompletedCount)
        case .approvalRequested: Self.increment(&aggregate.approvalRequestedCount)
        case .compactionStarted: Self.increment(&aggregate.compactionStartedCount)
        case .compactionCompleted: Self.increment(&aggregate.compactionCompletedCount)
        case .subagentStarted: Self.increment(&aggregate.subagentStartedCount)
        case .subagentEnded: Self.increment(&aggregate.subagentEndedCount)
        case .none: break
        }

        // 终态事件不单独构成对应的当日活跃轮次
        if event.eventKind != .sessionEnded, let sessionID = event.sessionID {
            sessionIDs.insert(sessionID)
        }
        if event.eventKind != .turnCompleted, event.eventKind != .turnAborted, let turnID = event.turnID {
            turnIDs.insert(turnID)
        }

        if let projectDisplayName = event.projectDisplayName {
            aggregate.projectCounts[projectDisplayName, default: 0] += 1
        }
        if let model = event.model {
            aggregate.modelCounts[model, default: 0] += 1
        }
    }

    func finalized(identifierStorage: ActivityIdentifiers) -> ActivityAggregate {
        var aggregate = aggregate
        switch identifierStorage {
        case .retained:
            aggregate.sessionCount = nil
            aggregate.turnCount = nil
            aggregate.sessionIDs = Self.normalizedIdentifiers(sessionIDs)
            aggregate.turnIDs = Self.normalizedIdentifiers(turnIDs)
        case .compacted:
            aggregate.sessionCount = sessionIDs.count
            aggregate.turnCount = turnIDs.count
            aggregate.sessionIDs = nil
            aggregate.turnIDs = nil
        }
        return aggregate
    }

    private static func increment(_ count: inout Int?) {
        count = (count ?? 0) + 1
    }

    private static func normalizedIdentifiers(_ identifiers: Set<String>) -> [String] {
        identifiers.sorted()
    }
}

/// 全量重放时保留每个活动计数字段原有的可用性
nonisolated struct ActivityCountAvailability {
    static let all = ActivityCountAvailability(
        includesEventCount: true,
        events: Set(ActivityEventKind.allCases)
    )

    static let legacy = ActivityCountAvailability(
        includesEventCount: true,
        events: Set(ActivityEventKind.allCases.filter { $0 != .turnAborted })
    )

    private let includesEventCount: Bool
    private let events: Set<ActivityEventKind>

    init(aggregate: ActivityAggregate) {
        includesEventCount = aggregate.eventCount != nil
        events = Set(ActivityEventKind.allCases.filter { aggregate.eventCount(for: $0) != nil })
    }

    private init(includesEventCount: Bool, events: Set<ActivityEventKind>) {
        self.includesEventCount = includesEventCount
        self.events = events
    }

    var initialEventCount: Int? {
        includesEventCount ? 0 : nil
    }

    func initialCount(for event: ActivityEventKind) -> Int? {
        events.contains(event) ? 0 : nil
    }
}

/// Aggregates/activity.jsonl 中的持久化聚合行, 同时兼容保留 ID 和只保留计数两种形态
nonisolated struct ActivityAggregate: Codable, Equatable {
    let date: String
    var generationID: String?
    var generationStartedEmpty: Bool
    var eventCount: Int?
    var sessionStartedCount: Int?
    var sessionEndedCount: Int?
    var turnStartedCount: Int?
    var turnCompletedCount: Int?
    var turnAbortedCount: Int?
    var toolStartedCount: Int?
    var toolCompletedCount: Int?
    var approvalRequestedCount: Int?
    var compactionStartedCount: Int?
    var compactionCompletedCount: Int?
    var subagentStartedCount: Int?
    var subagentEndedCount: Int?
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var modelCounts: [String: Int]
    var sessionIDs: [String]?
    var turnIDs: [String]?

    /// 增量路径只有在完整 ID 集合仍然存在时才能继续安全去重
    var supportsIncrementalAggregation: Bool {
        sessionCount == nil && turnCount == nil
    }

    init(
        date: String,
        generationID: String? = nil,
        generationStartedEmpty: Bool = false,
        eventCountAvailability: ActivityCountAvailability = .all
    ) {
        self.date = date
        self.generationID = generationID
        self.generationStartedEmpty = generationStartedEmpty
        eventCount = eventCountAvailability.initialEventCount
        sessionStartedCount = eventCountAvailability.initialCount(for: .sessionStarted)
        sessionEndedCount = eventCountAvailability.initialCount(for: .sessionEnded)
        turnStartedCount = eventCountAvailability.initialCount(for: .turnStarted)
        turnCompletedCount = eventCountAvailability.initialCount(for: .turnCompleted)
        turnAbortedCount = eventCountAvailability.initialCount(for: .turnAborted)
        toolStartedCount = eventCountAvailability.initialCount(for: .toolStarted)
        toolCompletedCount = eventCountAvailability.initialCount(for: .toolCompleted)
        approvalRequestedCount = eventCountAvailability.initialCount(for: .approvalRequested)
        compactionStartedCount = eventCountAvailability.initialCount(for: .compactionStarted)
        compactionCompletedCount = eventCountAvailability.initialCount(for: .compactionCompleted)
        subagentStartedCount = eventCountAvailability.initialCount(for: .subagentStarted)
        subagentEndedCount = eventCountAvailability.initialCount(for: .subagentEnded)
        sessionCount = nil
        turnCount = nil
        projectCounts = [:]
        modelCounts = [:]
        sessionIDs = []
        turnIDs = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        generationID = try container.decodeIfPresent(String.self, forKey: .generationID)
        generationStartedEmpty = try container.decodeIfPresent(Bool.self, forKey: .generationStartedEmpty) ?? false
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
        sessionStartedCount = try container.decodeIfPresent(Int.self, forKey: .sessionStartedCount)
        sessionEndedCount = try container.decodeIfPresent(Int.self, forKey: .sessionEndedCount)
        turnStartedCount = try container.decodeIfPresent(Int.self, forKey: .turnStartedCount)
        turnCompletedCount = try container.decodeIfPresent(Int.self, forKey: .turnCompletedCount)
        turnAbortedCount = try container.decodeIfPresent(Int.self, forKey: .turnAbortedCount)
        toolStartedCount = try container.decodeIfPresent(Int.self, forKey: .toolStartedCount)
        toolCompletedCount = try container.decodeIfPresent(Int.self, forKey: .toolCompletedCount)
        approvalRequestedCount = try container.decodeIfPresent(Int.self, forKey: .approvalRequestedCount)
        compactionStartedCount = try container.decodeIfPresent(Int.self, forKey: .compactionStartedCount)
        compactionCompletedCount = try container.decodeIfPresent(Int.self, forKey: .compactionCompletedCount)
        subagentStartedCount = try container.decodeIfPresent(Int.self, forKey: .subagentStartedCount)
        subagentEndedCount = try container.decodeIfPresent(Int.self, forKey: .subagentEndedCount)
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
        sessionIDs = try container.decodeIfPresent([String].self, forKey: .sessionIDs)
        turnIDs = try container.decodeIfPresent([String].self, forKey: .turnIDs)
    }

    mutating func normalizeIdentifierStorage(retainsIdentifiers: Bool) {
        guard !retainsIdentifiers else {
            sessionIDs = Self.normalizedIdentifiers(sessionIDs)
            turnIDs = Self.normalizedIdentifiers(turnIDs)
            return
        }

        sessionCount = CountResolution.preferredCount(
            compactedCount: sessionCount,
            identifiers: sessionIDs
        ) ?? sessionStartedCount
        turnCount = CountResolution.preferredCount(
            compactedCount: turnCount,
            identifiers: turnIDs
        ) ?? turnCompletedCount
        sessionIDs = nil
        turnIDs = nil
    }

    var metrics: ActivityMetrics {
        syncedAggregate.metrics
    }

    static func normalized(
        aggregates: [ActivityAggregate],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [ActivityAggregate] {
        let retentionCutoffDate = HistoryStorage.retentionCutoffDate(today: today, calendar: calendar)
        let identifierCutoffDate = HistoryStorage.identifierRetentionCutoffDate(today: today, calendar: calendar)

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

    static func encodeJSONLines(_ aggregates: [ActivityAggregate]) throws -> Data {
        try aggregates.reduce(into: Data()) { result, aggregate in
            try result.append(aggregate.jsonLineData())
        }
    }

    func jsonLineData() throws -> Data {
        var fields = try [
            OrderedJSON.field(CodingKeys.date.rawValue, date),
            OrderedJSON.field(CodingKeys.generationID.rawValue, generationID),
            OrderedJSON.field(CodingKeys.generationStartedEmpty.rawValue, generationStartedEmpty)
        ]
        try fields.append(contentsOf: OrderedJSON.presentCountFields(eventCountFields))
        try fields.append(contentsOf: [
            OrderedJSON.field(CodingKeys.sessionCount.rawValue, sessionCount),
            OrderedJSON.field(CodingKeys.turnCount.rawValue, turnCount),
            OrderedJSON.field(CodingKeys.projectCounts.rawValue, projectCounts),
            OrderedJSON.field(CodingKeys.modelCounts.rawValue, modelCounts),
            OrderedJSON.field(CodingKeys.sessionIDs.rawValue, sessionIDs),
            OrderedJSON.field(CodingKeys.turnIDs.rawValue, turnIDs)
        ])

        return OrderedJSON.lineData(fields)
    }

    var eventCountAvailability: ActivityCountAvailability {
        ActivityCountAvailability(aggregate: self)
    }

    func eventCount(for event: ActivityEventKind) -> Int? {
        switch event {
        case .sessionStarted: sessionStartedCount
        case .sessionEnded: sessionEndedCount
        case .turnStarted: turnStartedCount
        case .turnCompleted: turnCompletedCount
        case .turnAborted: turnAbortedCount
        case .toolStarted: toolStartedCount
        case .toolCompleted: toolCompletedCount
        case .approvalRequested: approvalRequestedCount
        case .compactionStarted: compactionStartedCount
        case .compactionCompleted: compactionCompletedCount
        case .subagentStarted: subagentStartedCount
        case .subagentEnded: subagentEndedCount
        }
    }

    var syncedAggregate: SyncedActivity {
        SyncedActivity(
            date: date,
            generationID: generationID,
            eventCount: eventCount,
            sessionStartedCount: sessionStartedCount,
            sessionEndedCount: sessionEndedCount,
            turnStartedCount: turnStartedCount,
            turnCompletedCount: turnCompletedCount,
            turnAbortedCount: turnAbortedCount,
            toolStartedCount: toolStartedCount,
            toolCompletedCount: toolCompletedCount,
            approvalRequestedCount: approvalRequestedCount,
            compactionStartedCount: compactionStartedCount,
            compactionCompletedCount: compactionCompletedCount,
            subagentStartedCount: subagentStartedCount,
            subagentEndedCount: subagentEndedCount,
            sessionCount: syncedSessionCount,
            turnCount: syncedTurnCount,
            projectCounts: projectCounts,
            modelCounts: modelCounts
        )
    }

    private var syncedSessionCount: Int? {
        CountResolution.preferredCount(
            compactedCount: sessionCount,
            identifiers: sessionIDs
        )
    }

    private var syncedTurnCount: Int? {
        CountResolution.preferredCount(
            compactedCount: turnCount,
            identifiers: turnIDs
        )
    }

    private var eventCountFields: [(String, Int?)] {
        [
            (CodingKeys.eventCount.rawValue, eventCount),
            (CodingKeys.sessionStartedCount.rawValue, sessionStartedCount),
            (CodingKeys.sessionEndedCount.rawValue, sessionEndedCount),
            (CodingKeys.turnStartedCount.rawValue, turnStartedCount),
            (CodingKeys.turnCompletedCount.rawValue, turnCompletedCount),
            (CodingKeys.turnAbortedCount.rawValue, turnAbortedCount),
            (CodingKeys.toolStartedCount.rawValue, toolStartedCount),
            (CodingKeys.toolCompletedCount.rawValue, toolCompletedCount),
            (CodingKeys.approvalRequestedCount.rawValue, approvalRequestedCount),
            (CodingKeys.compactionStartedCount.rawValue, compactionStartedCount),
            (CodingKeys.compactionCompletedCount.rawValue, compactionCompletedCount),
            (CodingKeys.subagentStartedCount.rawValue, subagentStartedCount),
            (CodingKeys.subagentEndedCount.rawValue, subagentEndedCount)
        ]
    }

    private static func normalizedIdentifiers(_ identifiers: [String]?) -> [String]? {
        identifiers.map { Set($0).sorted() }
    }

    private static func date(from string: String) -> Date? {
        CodexDateFormat.dayDate(from: string)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case generationID
        case generationStartedEmpty
        case eventCount
        case sessionStartedCount
        case sessionEndedCount
        case turnStartedCount
        case turnCompletedCount
        case turnAbortedCount
        case toolStartedCount
        case toolCompletedCount
        case approvalRequestedCount
        case compactionStartedCount
        case compactionCompletedCount
        case subagentStartedCount
        case subagentEndedCount
        case sessionCount
        case turnCount
        case projectCounts
        case modelCounts
        case sessionIDs
        case turnIDs
    }
}

// 同步用的每日聚合行, 保留 Aggregates/activity.jsonl 中的计数, 不包含 sessionIds 和 turnIds
