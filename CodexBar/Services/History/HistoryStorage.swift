import Foundation

/// 历史数据的位置与保留期, SQLite 负责跨进程事务
nonisolated enum HistoryStorage {
    private static let retentionDayCount = 210
    private static let identifierRetentionDayCount = 3

    static func directoryURL() -> URL {
        AppStorage.directoryURL()
    }

    static func syncDirectoryURL(in root: URL = directoryURL()) -> URL {
        root.appendingPathComponent("Sync", isDirectory: true)
    }

    static func rebuildableEventDateKeys(in directoryURL: URL = directoryURL()) async -> [String] {
        let cutoff = dateKey(for: retentionCutoffDate())
        let dates = try? await HistoryDatabaseStore.shared(in: directoryURL).access { try $0.dates() }
        return (dates ?? []).filter { $0 >= cutoff }
    }

    static func retentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: retentionDayCount, today: today, calendar: calendar)
    }

    static func identifierRetentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: identifierRetentionDayCount, today: today, calendar: calendar)
    }

    private static func cutoffDate(dayCount: Int, today: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: today)
        return calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: todayStart
        ) ?? todayStart
    }

    static func dateKey(for date: Date) -> String {
        CodexDateFormat.dayString(from: date)
    }

    static func isValidDateKey(_ dateKey: String) -> Bool {
        CodexDateFormat.dayDate(from: dateKey) != nil
    }
}
