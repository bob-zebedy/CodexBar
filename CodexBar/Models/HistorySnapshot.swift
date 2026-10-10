// MARK: - 每日聚合指标

/// 热力图详情面板直接消费的每日统计
nonisolated struct ActivityMetrics: Equatable {
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

    static func unavailable(startDate: String) -> ActivityMetrics {
        ActivityMetrics(
            startDate: startDate,
            threadCount: nil,
            turnCount: nil,
            toolCallCount: nil,
            approvalRequestedCount: nil,
            contextCompactionCount: nil,
            subagentCount: nil
        )
    }

    static func empty(startDate: String) -> ActivityMetrics {
        ActivityMetrics(
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

    func adding(_ other: ActivityMetrics) -> ActivityMetrics {
        ActivityMetrics(
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
    let dailyMetrics: [ActivityMetrics]
    var tokenUsageByDate: [String: TokenUsage] = [:]
    var unavailableActivityDates = Set<String>()
    var isActivityComplete = true

    static let empty = HistorySnapshot(dailyMetrics: [])

    init(dailyMetrics: [ActivityMetrics]) {
        self.dailyMetrics = dailyMetrics
    }

    /// 同 generation 只采用一份数据; 确认独立的新 generation 与历史贡献累加
    init(
        localAggregates: [ActivityAggregate],
        syncedRecords: [ActivitySyncRecord],
        currentDeviceID: String?
    ) {
        var metricsByDate = [String: ActivityMetrics]()

        let localByDate = Dictionary(localAggregates.map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
        unavailableActivityDates = Set(Dictionary(grouping: localAggregates, by: \.date).filter { $0.value.count > 1 }.keys)
        let currentDeviceRecords = syncedRecords.filter { $0.deviceID == currentDeviceID }
        let otherDeviceRecords = syncedRecords.filter { $0.deviceID != currentDeviceID }

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
        local: ActivityAggregate?,
        remoteRecords: [ActivitySyncRecord],
        into metricsByDate: inout [String: ActivityMetrics]
    ) {
        guard let local else {
            merge(remoteRecords, into: &metricsByDate)
            return
        }

        let matchingIndex = remoteRecords.firstIndex {
            local.syncedAggregate.matchesRemoteSource($0.daily)
        }

        for (index, record) in remoteRecords.enumerated() where index != matchingIndex {
            merge(record.daily.metrics, into: &metricsByDate)
        }

        if let matchingIndex,
           remoteRecords[matchingIndex].daily.aggregationVersion > local.aggregationVersion
           || (remoteRecords[matchingIndex].daily.sourceCheckpoint?.byteCount ?? 0) > (local.sourceCheckpoint?.byteCount ?? 0) {
            merge(remoteRecords[matchingIndex].daily.metrics, into: &metricsByDate)
        } else {
            merge(local.metrics, into: &metricsByDate)
        }
    }

    private static func merge(
        _ records: [ActivitySyncRecord],
        into metricsByDate: inout [String: ActivityMetrics]
    ) {
        for record in records {
            merge(record.daily.metrics, into: &metricsByDate)
        }
    }

    private static func merge(
        _ metrics: ActivityMetrics,
        into metricsByDate: inout [String: ActivityMetrics]
    ) {
        if let existing = metricsByDate[metrics.startDate] {
            metricsByDate[metrics.startDate] = existing.adding(metrics)
        } else {
            metricsByDate[metrics.startDate] = metrics
        }
    }
}
