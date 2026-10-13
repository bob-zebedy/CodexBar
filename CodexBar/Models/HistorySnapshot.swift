// MARK: - 每日聚合指标

/// 热力图详情面板直接消费的每日统计
nonisolated struct ActivityDataMetrics: Equatable {
    let startDate: String
    let threadCount: Int?
    let turnCount: Int?
    let toolCallCount: Int?
    let approvalRequestedCount: Int?
    let contextCompactionCount: Int?
    let subagentCount: Int?
    let modelCounts: [String: Int]
    let turnAbortedCount: Int?

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
        threadCount: Int?,
        turnCount: Int?,
        toolCallCount: Int?,
        approvalRequestedCount: Int?,
        contextCompactionCount: Int?,
        subagentCount: Int?,
        modelCounts: [String: Int] = [:],
        turnAbortedCount: Int? = nil
    ) {
        self.startDate = startDate
        self.threadCount = threadCount
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.approvalRequestedCount = approvalRequestedCount
        self.contextCompactionCount = contextCompactionCount
        self.subagentCount = subagentCount
        self.modelCounts = modelCounts
        self.turnAbortedCount = turnAbortedCount
    }

    static func unavailable(startDate: String) -> ActivityDataMetrics {
        ActivityDataMetrics(
            startDate: startDate,
            threadCount: nil,
            turnCount: nil,
            toolCallCount: nil,
            approvalRequestedCount: nil,
            contextCompactionCount: nil,
            subagentCount: nil
        )
    }

    static func empty(startDate: String) -> ActivityDataMetrics {
        ActivityDataMetrics(
            startDate: startDate,
            threadCount: 0,
            turnCount: 0,
            toolCallCount: 0,
            approvalRequestedCount: 0,
            contextCompactionCount: 0,
            subagentCount: 0
        )
    }

    init(
        startDate: String,
        threadCount: Int?,
        turnCount: Int?,
        toolStartedCount: Int?,
        toolCompletedCount: Int?,
        approvalRequestedCount: Int?,
        compactionStartedCount: Int?,
        compactionCompletedCount: Int?,
        subagentStartedCount: Int?,
        subagentEndedCount: Int?,
        modelCounts: [String: Int],
        turnAbortedCount: Int? = nil
    ) {
        self.startDate = startDate
        self.threadCount = threadCount
        self.turnCount = turnCount
        toolCallCount = toolStartedCount.flatMap { lhs in toolCompletedCount.map { max(lhs, $0) } }
        self.approvalRequestedCount = approvalRequestedCount
        contextCompactionCount = compactionStartedCount.flatMap { lhs in compactionCompletedCount.map { max(lhs, $0) } }
        subagentCount = subagentStartedCount.flatMap { lhs in subagentEndedCount.map { max(lhs, $0) } }
        self.modelCounts = modelCounts
        self.turnAbortedCount = turnAbortedCount
    }

    func adding(_ other: ActivityDataMetrics) -> ActivityDataMetrics {
        ActivityDataMetrics(
            startDate: startDate,
            threadCount: threadCount.flatMap { lhs in other.threadCount.map { lhs + $0 } },
            turnCount: turnCount.flatMap { lhs in other.turnCount.map { lhs + $0 } },
            toolCallCount: toolCallCount.flatMap { lhs in other.toolCallCount.map { lhs + $0 } },
            approvalRequestedCount: approvalRequestedCount.flatMap { lhs in other.approvalRequestedCount.map { lhs + $0 } },
            contextCompactionCount: contextCompactionCount.flatMap { lhs in other.contextCompactionCount.map { lhs + $0 } },
            subagentCount: subagentCount.flatMap { lhs in other.subagentCount.map { lhs + $0 } },
            modelCounts: Self.mergedCounts(modelCounts, other.modelCounts),
            turnAbortedCount: turnAbortedCount.flatMap { lhs in other.turnAbortedCount.map { lhs + $0 } }
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

/// HistoryService 发布给 UI 的近端快照
nonisolated struct HistorySnapshot: Equatable {
    let activityData: [ActivityDataMetrics]
    var tokenUsageByDate: [String: TokenUsage] = [:]
    var unavailableActivityDataDates = Set<String>()
    var isActivityDataComplete = true

    static let empty = HistorySnapshot(activityData: [])

    init(activityData: [ActivityDataMetrics]) {
        self.activityData = activityData
    }

    /// 本机日期使用本地汇总, 其他设备的同日数量相加
    init(
        localActivityDataAggregates: [ActivityDataAggregate],
        syncedActivityDataRecords: [ActivityDataSyncRecord],
        currentDeviceID: String?
    ) {
        var metricsByDate = [String: ActivityDataMetrics]()

        let localByDate = Dictionary(localActivityDataAggregates.map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
        unavailableActivityDataDates = Set(Dictionary(grouping: localActivityDataAggregates, by: \.date).filter { $0.value.count > 1 }.keys)
        let remoteByID = Dictionary(syncedActivityDataRecords.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        for record in remoteByID.values where record.deviceID != currentDeviceID || localByDate[record.date] == nil {
            Self.merge(record.activityData.metrics, into: &metricsByDate)
        }
        for local in localByDate.values {
            Self.merge(local.metrics, into: &metricsByDate)
        }

        activityData = metricsByDate.values.sorted { $0.startDate < $1.startDate }
    }

    private static func merge(
        _ metrics: ActivityDataMetrics,
        into metricsByDate: inout [String: ActivityDataMetrics]
    ) {
        if let existing = metricsByDate[metrics.startDate] {
            metricsByDate[metrics.startDate] = existing.adding(metrics)
        } else {
            metricsByDate[metrics.startDate] = metrics
        }
    }
}
