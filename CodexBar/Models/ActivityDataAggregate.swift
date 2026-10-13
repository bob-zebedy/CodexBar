import Foundation

// MARK: - 每日事件聚合

/// ID 保留期限只决定最终存储形态, 不能影响聚合结果
nonisolated enum ActivityDataIdentifiers {
    case retained
    case compacted
}

/// 从原始事件生成每日聚合的纯内存累加器
/// 全量和增量路径都收集 ID, 只有 finalize 时才按保留策略决定是否落盘
nonisolated struct ActivityDataAccumulator {
    private var aggregate: ActivityDataAggregate
    private var threadIDs: Set<String> = []
    private var turnIDs: Set<String> = []
    private var baseThreadCount = 0
    private var baseTurnCount = 0
    private var restoresCompactedIdentity = false

    init(rebuilding date: String) {
        aggregate = ActivityDataAggregate(date: date)
    }

    init(appending aggregate: ActivityDataAggregate) {
        self.aggregate = aggregate
        threadIDs = Set(aggregate.threadIDs ?? [])
        turnIDs = Set(aggregate.turnIDs ?? [])
        baseThreadCount = aggregate.threadCount ?? 0
        baseTurnCount = aggregate.turnCount ?? 0
        restoresCompactedIdentity = !aggregate.supportsIncrementalAggregation
    }

    mutating func record(_ event: ActivityDataRecord) {
        Self.increment(&aggregate.eventCount)
        // 一个命令 item 可包含多个动作, 重复类型仍表示独立操作
        let toolCallCount = max(1, event.commandActionTypes?.count ?? 0)

        switch event.eventKind {
        case .turnStarted: Self.increment(&aggregate.turnStartedCount)
        case .turnCompleted: Self.increment(&aggregate.turnCompletedCount)
        case .turnAborted: Self.increment(&aggregate.turnAbortedCount)
        case .toolStarted: Self.increment(&aggregate.toolStartedCount, by: toolCallCount)
        case .toolCompleted: Self.increment(&aggregate.toolCompletedCount, by: toolCallCount)
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

    mutating func restoreIdentity(from event: ActivityDataRecord) {
        if let threadID = event.threadID {
            threadIDs.insert(threadID)
        }
        if event.eventKind != .turnCompleted, event.eventKind != .turnAborted, let turnID = event.turnID {
            turnIDs.insert(turnID)
        }
    }

    func finalized(identifierStorage: ActivityDataIdentifiers) -> ActivityDataAggregate {
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

    private static func increment(_ count: inout Int?, by amount: Int = 1) {
        count = (count ?? 0) + amount
    }

    private static func normalizedIdentifiers(_ identifiers: Set<String>) -> [String] {
        identifiers.sorted()
    }
}

/// 每日聚合按保留期压缩去重身份, 不改变计数含义
nonisolated struct ActivityDataAggregate: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var aggregationVersion = AggregationVersion.activityData
    var position: Int64 = 0

    let date: String
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

    init(date: String) {
        self.date = date
        eventCount = 0
        turnStartedCount = 0
        turnCompletedCount = 0
        turnAbortedCount = 0
        toolStartedCount = 0
        toolCompletedCount = 0
        approvalRequestedCount = 0
        compactionStartedCount = 0
        compactionCompletedCount = 0
        subagentStartedCount = 0
        subagentEndedCount = 0
        threadCount = nil
        turnCount = nil
        projectCounts = [:]
        modelCounts = [:]
        threadIDs = []
        turnIDs = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        try StorageVersion.require(schemaVersion, current: Self.schemaVersion, name: "ActivityDataAggregate")
        aggregationVersion = try container.decode(Int.self, forKey: .aggregationVersion)
        try AggregationVersion.require(aggregationVersion, current: AggregationVersion.activityData, name: "activityData")
        position = try container.decode(Int64.self, forKey: .position)
        guard position >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .position, in: container, debugDescription: "Invalid aggregate position")
        }
        date = try container.decode(String.self, forKey: .date)
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

    var metrics: ActivityDataMetrics {
        syncedAggregate.metrics
    }

    static func normalized(
        aggregates: [ActivityDataAggregate],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [ActivityDataAggregate] {
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

    var syncedAggregate: SyncedActivityData {
        SyncedActivityData(
            aggregationVersion: aggregationVersion,
            date: date,
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
        case schemaVersion, aggregationVersion, position
        case date
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
