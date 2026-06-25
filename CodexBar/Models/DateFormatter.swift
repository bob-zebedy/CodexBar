import Foundation

/// 集中管理 CodexBar 数据文件和 app-server 响应里使用的日期格式
nonisolated enum CodexDateFormat {
    /// yyyy-MM-dd, 作为热力图与按日聚合统一的稳定日期键
    static func dayString(from date: Date) -> String {
        let components = localGregorianCalendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }

        return "\(padded(year, toLength: 4))-\(padded(month, toLength: 2))-\(padded(day, toLength: 2))"
    }

    static func dayDate(from string: String) -> Date? {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1 ... 9999).contains(year),
              (1 ... 12).contains(month),
              (1 ... 31).contains(day) else {
            return nil
        }

        var components = DateComponents()
        components.calendar = localGregorianCalendar
        components.timeZone = .autoupdatingCurrent
        components.year = year
        components.month = month
        components.day = day

        guard let date = components.date,
              dayString(from: date) == string else {
            return nil
        }

        return date
    }

    /// yyyy-MM-dd HH: mm: ss.SSS, Hook 原始事件写入本机时间字符串
    static func localTimestampString(from date: Date) -> String {
        localTimestampFormatter().string(from: date)
    }

    static func localTimestampDate(from string: String) -> Date? {
        localTimestampFormatter().date(from: string)
    }

    /// 带小数秒的 ISO8601, 用于读取 Hook payload 中的原始时间戳
    static func iso8601FractionalDate(from string: String) -> Date? {
        iso8601FractionalFormatter().date(from: string)
    }

    /// 不带小数秒的 ISO8601 兜底解析器
    static func iso8601InternetDateTimeDate(from string: String) -> Date? {
        iso8601InternetDateTimeFormatter().date(from: string)
    }

    private static var localGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private static func localTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }

    private static func iso8601FractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func iso8601InternetDateTimeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func padded(_ value: Int, toLength length: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, length - text.count)) + text
    }
}
