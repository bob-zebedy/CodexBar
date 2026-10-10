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
    private var threadIDs: Set<String> = []
    private var turnIDs: Set<String> = []
    private var baseThreadCount = 0
    private var baseTurnCount = 0
    private var restoresCompactedIdentity = false

    init(
        rebuilding date: String,
        generationID: String?,
        eventCountAvailability: ActivityCountAvailability
    ) {
        aggregate = ActivityAggregate(
            date: date,
            generationID: generationID,
            eventCountAvailability: eventCountAvailability
        )
    }

    init(
        appending aggregate: ActivityAggregate,
        generationID: String?
    ) {
        var aggregate = aggregate
        aggregate.generationID = generationID
        self.aggregate = aggregate
        threadIDs = Set(aggregate.threadIDs ?? [])
        turnIDs = Set(aggregate.turnIDs ?? [])
        baseThreadCount = aggregate.threadCount ?? 0
        baseTurnCount = aggregate.turnCount ?? 0
        restoresCompactedIdentity = !aggregate.supportsIncrementalAggregation
    }

    mutating func record(_ event: ActivityRecord) {
        Self.increment(&aggregate.eventCount)

        switch event.eventKind {
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
        if let threadID = event.threadID, threadIDs.insert(threadID).inserted, restoresCompactedIdentity {
            baseThreadCount += 1
        }
        if event.eventKind != .turnCompleted, event.eventKind != .turnAborted,
           let turnID = event.turnID, turnIDs.insert(turnID).inserted, restoresCompactedIdentity {
            baseTurnCount += 1
        }

        if let projectDisplayName = event.projectDisplayName {
            aggregate.projectCounts[projectDisplayName, default: 0] += 1
        }
        if let model = event.model {
            aggregate.modelCounts[model, default: 0] += 1
        }
    }

    mutating func restoreIdentity(from event: ActivityRecord) {
        if let threadID = event.threadID {
            threadIDs.insert(threadID)
        }
        if event.eventKind != .turnCompleted, event.eventKind != .turnAborted, let turnID = event.turnID {
            turnIDs.insert(turnID)
        }
    }

    func finalized(identifierStorage: ActivityIdentifiers) -> ActivityAggregate {
        var aggregate = aggregate
        switch identifierStorage {
        case .retained:
            aggregate.threadCount = nil
            aggregate.turnCount = nil
            aggregate.threadIDs = Self.normalizedIdentifiers(threadIDs)
            aggregate.turnIDs = Self.normalizedIdentifiers(turnIDs)
        case .compacted:
            aggregate.threadCount = restoresCompactedIdentity ? baseThreadCount : threadIDs.count
            aggregate.turnCount = restoresCompactedIdentity ? baseTurnCount : turnIDs.count
            aggregate.threadIDs = nil
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
    static let currentVersion = 1
    var version = Self.currentVersion
    var aggregationVersion = AggregationVersion.activity
    var sourceCheckpoint: ActivitySourceCheckpoint?

    let date: String
    var generationID: String?
    var eventCount: Int?
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
    var threadCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var modelCounts: [String: Int]
    var threadIDs: [String]?
    var turnIDs: [String]?

    /// 增量路径只有在完整 ID 集合仍然存在时才能继续安全去重
    var supportsIncrementalAggregation: Bool {
        threadCount == nil && turnCount == nil
    }

    init(
        date: String,
        generationID: String? = nil,
        eventCountAvailability: ActivityCountAvailability = .all
    ) {
        self.date = date
        self.generationID = generationID
        eventCount = eventCountAvailability.initialEventCount
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
        threadCount = nil
        turnCount = nil
        projectCounts = [:]
        modelCounts = [:]
        threadIDs = []
        turnIDs = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        try StorageVersion.require(version, current: Self.currentVersion, name: "ActivityAggregate")
        sourceCheckpoint = try container.decodeIfPresent(ActivitySourceCheckpoint.self, forKey: .sourceCheckpoint)
        aggregationVersion = try container.decode(Int.self, forKey: .aggregationVersion)
        try AggregationVersion.require(aggregationVersion, current: AggregationVersion.activity, name: "Activity")
        date = try container.decode(String.self, forKey: .date)
        generationID = try container.decodeIfPresent(String.self, forKey: .generationID)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
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
        threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
        threadIDs = try container.decodeIfPresent([String].self, forKey: .threadIDs)
        turnIDs = try container.decodeIfPresent([String].self, forKey: .turnIDs)
    }

    mutating func normalizeIdentifierStorage(retainsIdentifiers: Bool) {
        guard !retainsIdentifiers else {
            threadIDs = Self.normalizedIdentifiers(threadIDs)
            turnIDs = Self.normalizedIdentifiers(turnIDs)
            return
        }

        threadCount = CountResolution.preferredCount(
            compactedCount: threadCount,
            identifiers: threadIDs
        )
        turnCount = CountResolution.preferredCount(
            compactedCount: turnCount,
            identifiers: turnIDs
        )
        threadIDs = nil
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
        try JSONLines.stableEncoder.encode(self) + Data([JSONLines.newlineByte])
    }

    var eventCountAvailability: ActivityCountAvailability {
        ActivityCountAvailability(aggregate: self)
    }

    func eventCount(for event: ActivityEventKind) -> Int? {
        switch event {
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
            aggregationVersion: aggregationVersion,
            sourceCheckpoint: sourceCheckpoint,
            date: date,
            generationID: generationID,
            eventCount: eventCount,
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
            threadCount: syncedThreadCount,
            turnCount: syncedTurnCount,
            projectCounts: projectCounts,
            modelCounts: modelCounts
        )
    }

    private var syncedThreadCount: Int? {
        CountResolution.preferredCount(
            compactedCount: threadCount,
            identifiers: threadIDs
        )
    }

    private var syncedTurnCount: Int? {
        CountResolution.preferredCount(
            compactedCount: turnCount,
            identifiers: turnIDs
        )
    }

    private static func normalizedIdentifiers(_ identifiers: [String]?) -> [String]? {
        identifiers.map { Set($0).sorted() }
    }

    private static func date(from string: String) -> Date? {
        CodexDateFormat.dayDate(from: string)
    }

    private enum CodingKeys: String, CodingKey {
        case version, aggregationVersion, sourceCheckpoint
        case date
        case generationID
        case eventCount
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
        case threadCount
        case turnCount
        case projectCounts
        case modelCounts
        case threadIDs
        case turnIDs
    }
}
