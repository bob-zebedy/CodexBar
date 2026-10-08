// MARK: - 每日聚合指标

/// 热力图详情面板直接消费的每日统计
nonisolated struct ActivityMetrics: Equatable {
    let startDate: String
    let sessionCount: Int
    let turnCount: Int
    let toolCallCount: Int
    let approvalRequestedCount: Int
    let contextCompactionCount: Int
    let subagentCount: Int
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
        sessionCount: Int,
        turnCount: Int,
        toolCallCount: Int,
        approvalRequestedCount: Int,
        contextCompactionCount: Int,
        subagentCount: Int,
        modelCounts: [String: Int] = [:],
        turnAbortedCount: Int? = nil
    ) {
        self.startDate = startDate
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        self.toolCallCount = toolCallCount
        self.approvalRequestedCount = approvalRequestedCount
        self.contextCompactionCount = contextCompactionCount
        self.subagentCount = subagentCount
        self.modelCounts = modelCounts
        self.turnAbortedCount = turnAbortedCount
    }

    static func empty(startDate: String) -> ActivityMetrics {
        ActivityMetrics(
            startDate: startDate,
            sessionCount: 0,
            turnCount: 0,
            toolCallCount: 0,
            approvalRequestedCount: 0,
            contextCompactionCount: 0,
            subagentCount: 0
        )
    }

    init(
        startDate: String,
        sessionCount: Int,
        turnCount: Int,
        toolStartedCount: Int,
        toolCompletedCount: Int,
        approvalRequestedCount: Int,
        compactionStartedCount: Int,
        compactionCompletedCount: Int,
        subagentStartedCount: Int,
        subagentEndedCount: Int,
        modelCounts: [String: Int],
        turnAbortedCount: Int? = nil
    ) {
        self.startDate = startDate
        self.sessionCount = sessionCount
        self.turnCount = turnCount
        toolCallCount = max(toolStartedCount, toolCompletedCount)
        self.approvalRequestedCount = approvalRequestedCount
        contextCompactionCount = max(compactionStartedCount, compactionCompletedCount)
        subagentCount = max(subagentStartedCount, subagentEndedCount)
        self.modelCounts = modelCounts
        self.turnAbortedCount = turnAbortedCount
    }

    func adding(_ other: ActivityMetrics) -> ActivityMetrics {
        ActivityMetrics(
            startDate: startDate,
            sessionCount: sessionCount + other.sessionCount,
            turnCount: turnCount + other.turnCount,
            toolCallCount: toolCallCount + other.toolCallCount,
            approvalRequestedCount: approvalRequestedCount + other.approvalRequestedCount,
            contextCompactionCount: contextCompactionCount + other.contextCompactionCount,
            subagentCount: subagentCount + other.subagentCount,
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

        let localByDate = Dictionary(uniqueKeysWithValues: localAggregates.map { ($0.date, $0) })
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

        guard remoteRecords.isEmpty || local.generationStartedEmpty || matchingIndex != nil else {
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
