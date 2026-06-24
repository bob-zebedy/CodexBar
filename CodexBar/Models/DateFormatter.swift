import Foundation

extension DateFormatter {
    /// yyyy-MM-dd, 作为热力图与按日聚合统一的稳定日期键
    /// DateFormatter 不是线程安全类型, 这里每次返回新实例以避免跨线程共享
    nonisolated static var codexDay: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// yyyy-MM-dd HH:mm:ss.SSS, Hook 原始事件写入本机时间字符串
    /// DateFormatter 不是线程安全类型, 这里每次返回新实例以避免跨线程共享
    nonisolated static var codexLocalTimestamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }
}

extension ISO8601DateFormatter {
    /// 带小数秒的 ISO8601, 用于读取 Hook payload 中的原始时间戳
    /// ISO8601DateFormatter 不是 Sendable, 这里每次返回新实例以避免跨线程共享
    nonisolated static var codexFractional: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// 不带小数秒的 ISO8601 兜底解析器
    nonisolated static var codexInternetDateTime: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
