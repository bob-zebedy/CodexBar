import Foundation

nonisolated struct CodexQuotaSnapshot: Equatable {
    let account: CodexAccount
    let planType: String?
    let generatedAt: Date
    let limits: [CodexQuotaLimitSnapshot]
    let usage: CodexUsageSnapshot?
    let isRateLimitsStale: Bool
    let isUsageStale: Bool
    
    var accountLabel: String {
        account.displayName
    }
    
    var planLabel: String? {
        account.planType ?? planType
    }
}

nonisolated struct CodexQuotaLimitSnapshot: Equatable, Identifiable {
    let limitId: String
    let limitName: String?
    let windows: [QuotaWindow]
    
    var id: String { limitId }
    
    var title: String {
        if let limitName, !limitName.isEmpty {
            return limitName.capitalizingFirstLetter()
        }
        
        return limitId.capitalizingFirstLetter()
    }
}

nonisolated private extension String {
    func capitalizingFirstLetter() -> String {
        guard let first else {
            return self
        }
        
        return first.uppercased() + dropFirst()
    }
}

nonisolated struct CodexAccount: Decodable, Equatable {
    let type: String
    let email: String?
    let planType: String?
    
    var hasEmail: Bool {
        email?.isEmpty == false
    }
    
    var displayName: String {
        if let email, hasEmail {
            return email
        }
        
        switch type {
        case "apiKey":
            return "API Key"
        case "chatgpt":
            return "ChatGPT"
        case "amazonBedrock":
            return "Amazon Bedrock"
        default:
            return type
        }
    }
}

nonisolated struct AccountReadResponse: Decodable {
    let account: CodexAccount?
}

nonisolated struct QuotaWindow: Equatable, Identifiable {
    let id: String
    let windowDurationMins: Int?
    let usedPercent: Int?
    let resetsAt: Date?
    
    var label: String {
        Self.windowLabel(for: windowDurationMins)
    }
    
    var remainingPercent: Int {
        guard let usedPercent else {
            return 0
        }
        
        return max(0, min(100, 100 - usedPercent))
    }
    
    var hasData: Bool {
        usedPercent != nil
    }
    
    private static func windowLabel(for minutes: Int?) -> String {
        guard let minutes, minutes > 0 else {
            return "额度"
        }
        
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440) 天"
        }
        
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60) 小时"
        }
        
        return "\(minutes) 分钟"
    }
}

nonisolated struct AccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

nonisolated struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

nonisolated struct RateLimitWindow: Decodable {
    let usedPercent: Int?
    let resetsAt: Int?
    let windowDurationMins: Int?
    
    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }
}

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
    
    /// 给热力图生成按周排列的最近日期网格, 每列从周日开始
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

nonisolated extension CodexQuotaSnapshot {
    init(
        accountResponse: AccountReadResponse,
        rateLimitsResponse: AccountRateLimitsResponse?,
        usageResponse: AccountUsageResponse? = nil,
        isRateLimitsStale: Bool = false,
        isUsageStale: Bool = false,
        generatedAt: Date = Date()
    ) throws {
        guard let account = accountResponse.account else {
            throw CodexStatusError.notLoggedIn
        }
        
        let limits = rateLimitsResponse.map { response in
            Self.orderedSnapshots(from: response).compactMap { entry in
                CodexQuotaLimitSnapshot(limitId: entry.limitId, snapshot: entry.snapshot)
            }
        } ?? []
        
        let usage = usageResponse.map {
            CodexUsageSnapshot(summary: $0.summary, dailyBuckets: $0.dailyUsageBuckets)
        }
        
        // rateLimits/usage 可同时为空, 账户有效时仍生成快照给 UI 展示"暂无数据"
        self.init(
            account: account,
            planType: rateLimitsResponse?.rateLimits.planType,
            generatedAt: generatedAt,
            limits: limits,
            usage: usage,
            isRateLimitsStale: isRateLimitsStale,
            isUsageStale: isUsageStale
        )
    }
    
    /// 展示顺序: 顶层 rateLimits 指向的主 limit 置顶, 其余按名称排序
    private static func orderedSnapshots(
        from response: AccountRateLimitsResponse
    ) -> [(limitId: String, snapshot: RateLimitSnapshot)] {
        let primaryLimitId = response.rateLimits.limitId ?? "codex"
        
        guard let byLimitId = response.rateLimitsByLimitId, !byLimitId.isEmpty else {
            return [(primaryLimitId, response.rateLimits)]
        }
        
        return byLimitId
            .map { (limitId: $0.key, snapshot: $0.value) }
            .sorted { lhs, rhs in
                if (lhs.limitId == primaryLimitId) != (rhs.limitId == primaryLimitId) {
                    return lhs.limitId == primaryLimitId
                }
                
                let lhsName = lhs.snapshot.limitName ?? lhs.limitId
                let rhsName = rhs.snapshot.limitName ?? rhs.limitId
                let nameOrder = lhsName.localizedStandardCompare(rhsName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                
                return lhs.limitId.localizedStandardCompare(rhs.limitId) == .orderedAscending
            }
    }
}

nonisolated extension CodexQuotaLimitSnapshot {
    init?(limitId: String, snapshot: RateLimitSnapshot) {
        let windows = [("primary", snapshot.primary), ("secondary", snapshot.secondary)]
            .compactMap { id, window in
                window.map { QuotaWindow(id: id, window: $0) }
            }
        
        guard !windows.isEmpty else {
            return nil
        }
        
        self.init(
            limitId: limitId,
            limitName: snapshot.limitName,
            windows: windows
        )
    }
}

nonisolated extension QuotaWindow {
    init(id: String, window: RateLimitWindow) {
        self.init(
            id: id,
            windowDurationMins: window.windowDurationMins,
            usedPercent: window.usedPercent,
            resetsAt: window.resetDate
        )
    }
}

nonisolated enum CodexStatusError: LocalizedError {
    case executableNotFound
    case serverTimeout
    case serverConnectionClosed
    case invalidServerResponse
    case serverError(String)
    case unsupportedMethod
    case notLoggedIn
    
    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 Codex CLI 或 Codex APP"
        default:
            return nil
        }
    }
    
    /// codex app-server 未登录
    var isAuthenticationRequired: Bool {
        serverErrorMessageContains("codex account authentication required")
    }
    
    /// codex app-server 不支持的方法
    var isUnsupportedMethod: Bool {
        switch self {
        case .unsupportedMethod:
            return true
        default:
            return serverErrorMessageContains("Invalid request: unknown variant")
        }
    }
    
    var isRetriableServerError: Bool {
        guard case .serverError = self else {
            return false
        }
        
        return !isAuthenticationRequired && !isUnsupportedMethod
    }
    
    /// 连接断开、超时、无法解析都需要重建 app-server 会话
    var isTransportFailure: Bool {
        switch self {
        case .serverConnectionClosed, .serverTimeout, .invalidServerResponse:
            return true
        default:
            return false
        }
    }
    
    private func serverErrorMessageContains(_ keyword: String) -> Bool {
        guard case .serverError(let message) = self else {
            return false
        }
        
        return message.range(of: keyword, options: .caseInsensitive) != nil
    }
}
