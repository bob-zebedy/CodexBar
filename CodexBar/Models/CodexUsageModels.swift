import Foundation

nonisolated struct AccountUsageResponse: Decodable {
    let summary: UsageSummary
    let dailyUsageBuckets: [DailyUsageBucket]
}

nonisolated struct UsageSummary: Decodable, Equatable {
    let currentStreakDays: Int?
    let lifetimeTokens: Int
    let longestRunningTurnSec: Int?
    let longestStreakDays: Int?
    let peakDailyTokens: Int
}

nonisolated struct DailyUsageBucket: Decodable, Equatable, Identifiable {
    let startDate: String
    let tokens: Int

    var id: String {
        startDate
    }
}

nonisolated struct CodexUsageSnapshot: Equatable {
    let summary: UsageSummary
    let dailyBuckets: [DailyUsageBucket]

    func tokenCount(on date: Date) -> Int? {
        let startDate = CodexDateFormat.dayString(from: date)
        return tokensByDate[startDate]
    }

    /// 给热力图生成按周排列的最近日期网格, 每列从周日开始
    func recentWeekGrid(columnCount: Int, endingDaysAgo: Int = 0, today: Date = Date()) -> [DailyUsageBucket?] {
        let tokenCountsByDate = tokensByDate
        return CodexWeekGrid.dates(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        .map { date in
            date.map {
                let startDate = CodexDateFormat.dayString(from: $0)
                return DailyUsageBucket(
                    startDate: startDate,
                    tokens: tokenCountsByDate[startDate] ?? 0
                )
            }
        }
    }

    private var tokensByDate: [String: Int] {
        dailyBuckets.reduce(into: [String: Int]()) { result, bucket in
            result[bucket.startDate, default: 0] += bucket.tokens
        }
    }
}
