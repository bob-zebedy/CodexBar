//
//  RateLimitModels.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Foundation

nonisolated struct CodexQuotaSnapshot: Equatable {
    let account: CodexAccount
    let planType: String?
    let generatedAt: Date
    let limits: [CodexQuotaLimitSnapshot]
    let usage: CodexUsageSnapshot?
    
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
    let usedPercent: Int
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
    let lifetimeTokens: Int
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
    
    func recentDays(count: Int, endingDaysAgo: Int) -> [DailyUsageBucket] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tokensByDate = dailyBuckets.reduce(into: [String: Int]()) { result, bucket in
            result[bucket.startDate, default: 0] += bucket.tokens
        }
        
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -(offset + endingDaysAgo), to: today) else {
                return nil
            }
            
            let startDate = Self.dayFormatter.string(from: date)
            return DailyUsageBucket(startDate: startDate, tokens: tokensByDate[startDate] ?? 0)
        }
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
        rateLimitsResponse: AccountRateLimitsResponse,
        usageResponse: AccountUsageResponse? = nil,
        generatedAt: Date = Date()
    ) throws {
        guard let account = accountResponse.account else {
            throw CodexRateLimitError.notLoggedIn
        }
        
        let limits = Self.orderedSnapshots(from: rateLimitsResponse).compactMap { entry in
            CodexQuotaLimitSnapshot(limitId: entry.limitId, snapshot: entry.snapshot)
        }
        
        guard !limits.isEmpty else {
            throw CodexRateLimitError.missingRateLimitWindow
        }
        
        self.init(
            account: account,
            planType: rateLimitsResponse.rateLimits.planType,
            generatedAt: generatedAt,
            limits: limits,
            usage: usageResponse.map {
                CodexUsageSnapshot(summary: $0.summary, dailyBuckets: $0.dailyUsageBuckets)
            }
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

nonisolated enum CodexRateLimitError: LocalizedError {
    case executableNotFound
    case serverStartFailed(String)
    case serverTimeout(String)
    case serverError(String)
    case missingRateLimitWindow
    case notLoggedIn
    case authenticationRequired
    
    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 Codex CLI 或 Codex App"
        case .serverStartFailed(let message):
            return "Codex app-server 启动失败: \(message)"
        case .serverTimeout(let step):
            return "Codex app-server 响应超时: \(step)"
        case .serverError(let message):
            return "Codex app-server 返回错误: \(message)"
        case .missingRateLimitWindow:
            return "查询不到数据"
        case .notLoggedIn:
            return "Codex 未登录"
        case .authenticationRequired:
            return "Codex 需要身份验证"
        }
    }
    
    var isAuthenticationRequired: Bool {
        switch self {
        case .serverError(let message):
            return message.localizedCaseInsensitiveContains("authentication required")
        case .authenticationRequired:
            return true
        default:
            return false
        }
    }
    
    /// 凭证已失效或未登录, 需要用户在 Codex 中重新登录才能恢复
    var requiresLogin: Bool {
        switch self {
        case .notLoggedIn:
            return true
        default:
            return isAuthenticationRequired
        }
    }
}
