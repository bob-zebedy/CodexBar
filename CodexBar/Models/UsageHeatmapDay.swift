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

/// 热力图单元格模型, 合并 app-server token 数据和本地 活动统计
nonisolated struct UsageHeatmapDay: Equatable, Identifiable {
    let startDate: String
    let tokenState: UsageHeatmapTokenState
    let history: ActivityMetrics
    var tokenUsage: TokenUsage?

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
        history: HistorySnapshot,
        showsActivity: Bool,
        columnCount: Int,
        today: Date
    ) -> [UsageHeatmapDay?] {
        let todayTokenCount = usage?.tokenCount(on: today)
        let hasDailyUsageBuckets = usage?.hasDailyUsageBuckets == true
        // 活动统计可见时包含今天, 仅展示 Token 时等待当天 bucket 返回
        let endingDaysAgo = showsActivity || todayTokenCount != nil ? 0 : 1
        let historyByDate = history.dailyMetrics.reduce(into: [String: ActivityMetrics]()) { result, metrics in
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
                history: historyByDate[startDate] ?? .empty(startDate: startDate),
                tokenUsage: history.tokenUsageByDate[startDate]
            )
        }
    }
}
