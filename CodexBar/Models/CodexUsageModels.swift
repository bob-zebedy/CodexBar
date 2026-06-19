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
    
    var id: String { startDate }
}

nonisolated struct CodexUsageSnapshot: Equatable {
    let summary: UsageSummary
    let dailyBuckets: [DailyUsageBucket]
    
    // 给热力图生成按周排列的最近日期网格, 每列从周日开始
    func recentWeekGrid(columnCount: Int, endingDaysAgo: Int = 0, today: Date = Date()) -> [DailyUsageBucket?] {
        guard columnCount > 0 else {
            return []
        }
        
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: today)
        let lastVisibleDate = calendar.date(
            byAdding: .day,
            value: -max(endingDaysAgo, 0),
            to: todayStart
        ) ?? todayStart
        let currentWeekStart = Self.sundayStartOfWeek(containing: lastVisibleDate, calendar: calendar)
        guard let firstWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -(columnCount - 1),
            to: currentWeekStart
        ) else {
            return []
        }
        
        let tokensByDate = dailyBuckets.reduce(into: [String: Int]()) { result, bucket in
            result[bucket.startDate, default: 0] += bucket.tokens
        }
        
        return (0..<columnCount).flatMap { column -> [DailyUsageBucket?] in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: column, to: firstWeekStart) else {
                return Array(repeating: nil, count: 7)
            }
            
            return (0..<7).map { weekdayOffset -> DailyUsageBucket? in
                guard let date = calendar.date(byAdding: .day, value: weekdayOffset, to: weekStart) else {
                    return nil
                }
                
                guard date <= lastVisibleDate else {
                    return nil
                }
                
                let startDate = Self.dayFormatter.string(from: date)
                return DailyUsageBucket(startDate: startDate, tokens: tokensByDate[startDate] ?? 0)
            }
        }
    }
    
    private static func sundayStartOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let daysSinceSunday = weekday - 1
        return calendar.date(byAdding: .day, value: -daysSinceSunday, to: date) ?? date
    }
    
    private nonisolated static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
