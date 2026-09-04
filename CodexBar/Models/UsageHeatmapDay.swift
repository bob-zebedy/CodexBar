import Foundation

nonisolated enum UsageHeatmapTokenState: Equatable {
    case available(Int)
    case pending
    case unavailable

    var count: Int? {
        guard case let .available(count) = self else {
            return nil
        }

        return count
    }
}

/// 热力图单元格模型, 合并 app-server token 数据和本地 Hook 工作流统计
nonisolated struct UsageHeatmapDay: Equatable, Identifiable {
    let startDate: String
    let tokenState: UsageHeatmapTokenState
    let workflow: WorkflowDailyMetrics

    var id: String {
        startDate
    }

    var tokenCount: Int? {
        tokenState.count
    }

    var tokensForHeatmap: Int {
        tokenCount ?? 0
    }

    static func grid(
        usage: CodexUsageSnapshot?,
        workflow: WorkflowSnapshot,
        showsWorkflow: Bool,
        columnCount: Int,
        today: Date
    ) -> [UsageHeatmapDay?] {
        let todayTokenCount = usage?.tokenCount(on: today)
        let hasDailyUsageBuckets = usage?.hasDailyUsageBuckets == true
        // Hook 开启时当天工作流统计可见
        // Hook 关闭时只在 token bucket 已返回时展示今天
        let endingDaysAgo = showsWorkflow || todayTokenCount != nil ? 0 : 1
        let workflowByDate = workflow.dailyMetrics.reduce(into: [String: WorkflowDailyMetrics]()) { result, metrics in
            result[metrics.startDate] = metrics
        }
        let todayString = CodexDateFormat.dayString(from: today)

        return CodexWeekGrid.dates(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        .map { date -> UsageHeatmapDay? in
            guard let date else {
                return nil
            }

            let startDate = CodexDateFormat.dayString(from: date)
            let tokenState: UsageHeatmapTokenState = if !hasDailyUsageBuckets {
                .unavailable
            } else if startDate == todayString, let todayTokenCount {
                .available(todayTokenCount)
            } else if startDate == todayString {
                .pending
            } else {
                .available(usage?.tokenCount(on: date) ?? 0)
            }
            return UsageHeatmapDay(
                startDate: startDate,
                tokenState: tokenState,
                workflow: workflowByDate[startDate] ?? .empty(startDate: startDate)
            )
        }
    }
}
