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

/// 热力图单元格模型, 合并 app-server token 数据和本地活动统计
nonisolated struct UsageHeatmapDay: Equatable, Identifiable {
    let startDate: String
    let tokenState: UsageHeatmapTokenState
    let activityData: ActivityDataMetrics
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
        columnCount: Int,
        today: Date
    ) -> [UsageHeatmapDay?] {
        let todayTokenCount = usage?.tokenCount(on: today)
        let hasDailyUsageBuckets = usage?.hasDailyUsageBuckets == true
        let historyByDate = history.activityData.reduce(into: [String: ActivityDataMetrics]()) { result, metrics in
            result[metrics.startDate] = metrics
        }
        let todayString = CodexDateFormat.dayString(from: today)

        return CodexWeekGrid.dates(
            columnCount: columnCount,
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
                activityData: history.unavailableActivityDataDates.contains(startDate) ? .unavailable(startDate: startDate)
                    : historyByDate[startDate] ?? (history.isActivityDataComplete ? .empty(startDate: startDate) : .unavailable(startDate: startDate)),
                tokenUsage: history.tokenUsageByDate[startDate]
            )
        }
    }
}

nonisolated enum UsageHeatmapMode: String {
    case daily
    case weekly
}

/// 展示期间的汇总, 周视图只合并已有日期, 区间仍覆盖完整的一周
nonisolated struct UsageHeatmapPeriod: Equatable {
    let startDate: String
    let endDate: String
    let tokenState: UsageHeatmapTokenState
    let activityData: ActivityDataMetrics
    let tokenUsage: TokenUsage?

    var tokensForHeatmap: Int {
        tokenState.count ?? 0
    }

    init?(days: [UsageHeatmapDay], endDate: String? = nil) {
        guard let first = days.first, let last = days.last else { return nil }
        startDate = first.startDate
        self.endDate = endDate ?? last.startDate
        tokenState = Self.totalTokenState(days)
        // 每日快照不含会话标识, 周计数沿用每日统计之和
        activityData = days.dropFirst().reduce(first.activityData) { $0.adding($1.activityData) }
        let usages = days.compactMap(\.tokenUsage)
        tokenUsage = usages.dropFirst().reduce(usages.first) { total, usage in
            total?.adding(usage)
        }
    }

    func filledRowCount(peakTokens: Int) -> Int {
        guard tokensForHeatmap > 0, peakTokens > 0 else { return 0 }
        let fraction = min(Double(tokensForHeatmap) / Double(peakTokens), 1)
        return max(1, Int(ceil(fraction * Double(CodexWeekGrid.rowCount))))
    }

    static func weeks(in days: [UsageHeatmapDay?]) -> [UsageHeatmapPeriod?] {
        stride(from: 0, to: days.count, by: CodexWeekGrid.rowCount).map { start in
            let weekDays = days[start ..< min(start + CodexWeekGrid.rowCount, days.count)].compactMap(\.self)
            guard let first = weekDays.first,
                  let startDate = CodexDateFormat.dayDate(from: first.startDate),
                  let endDate = CodexDateFormat.localGregorianCalendar.date(byAdding: .day, value: CodexWeekGrid.rowCount - 1, to: startDate) else {
                return nil
            }
            return UsageHeatmapPeriod(days: weekDays, endDate: CodexDateFormat.dayString(from: endDate))
        }
    }

    private static func totalTokenState(_ days: [UsageHeatmapDay]) -> UsageHeatmapTokenState {
        var total = 0
        var hasAvailableDay = false
        for day in days {
            switch day.tokenState {
            case let .available(count):
                let sum = total.addingReportingOverflow(count)
                guard !sum.overflow else { return .unavailable }
                total = sum.partialValue
                hasAvailableDay = true
            case .pending:
                continue
            case .unavailable:
                return .unavailable
            }
        }
        return hasAvailableDay ? .available(total) : .pending
    }
}
