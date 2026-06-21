import Foundation

extension DateFormatter {
    // yyyy-MM-dd, 作为热力图与按日聚合统一的稳定日期键
    nonisolated static let codexDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension ISO8601DateFormatter {
    // 带小数秒的 ISO8601, Hook 事件时间戳的统一读写格式
    nonisolated static let codexFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
