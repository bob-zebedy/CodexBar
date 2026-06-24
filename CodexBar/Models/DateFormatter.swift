import Foundation

extension DateFormatter {
    // yyyy-MM-dd, 作为热力图与按日聚合统一的稳定日期键
    nonisolated static let codexDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // yyyy-MM-dd HH:mm:ss.SSS, Hook 原始事件写入本机时间字符串
    nonisolated static let codexLocalTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}

extension ISO8601DateFormatter {
    // 带小数秒的 ISO8601, 用于读取 Hook payload 中的原始时间戳
    nonisolated static let codexFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
