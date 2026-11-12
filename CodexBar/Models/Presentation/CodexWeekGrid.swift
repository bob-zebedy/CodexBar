import Foundation

/// 共享的周历网格生成器, 固定按列为周, 行从周日开始排列
nonisolated enum CodexWeekGrid {
    static let rowCount = 7

    static func dates(
        columnCount: Int,
        endingDaysAgo: Int = 0,
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [Date?] {
        guard columnCount > 0 else {
            return []
        }

        let todayStart = calendar.startOfDay(for: today)
        let lastVisibleDate = calendar.date(
            byAdding: .day,
            value: -max(endingDaysAgo, 0),
            to: todayStart
        ) ?? todayStart
        let currentWeekStart = sundayStartOfWeek(containing: lastVisibleDate, calendar: calendar)
        guard let firstWeekStart = calendar.date(
            byAdding: .weekOfYear,
            value: -(columnCount - 1),
            to: currentWeekStart
        ) else {
            return []
        }

        return (0 ..< columnCount).flatMap { column -> [Date?] in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: column, to: firstWeekStart) else {
                return Array(repeating: nil, count: rowCount)
            }

            return (0 ..< rowCount).map { weekdayOffset -> Date? in
                guard let date = calendar.date(byAdding: .day, value: weekdayOffset, to: weekStart),
                      date <= lastVisibleDate else {
                    return nil
                }

                return date
            }
        }
    }

    private static func sundayStartOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: date)
        let daysSinceSunday = weekday - 1
        return calendar.date(byAdding: .day, value: -daysSinceSunday, to: date) ?? date
    }
}
