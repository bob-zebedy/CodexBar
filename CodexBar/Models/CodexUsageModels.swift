import Foundation

/// app-server account/usage 的原始响应, summary 和按日 bucket 分开使用
nonisolated struct AccountUsageResponse: Decodable {
    let summary: UsageSummary
    let dailyUsageBuckets: [DailyUsageBucket]
}

/// token 区域展示的汇总指标
nonisolated struct UsageSummary: Decodable, Equatable {
    let currentStreakDays: Int?
    let lifetimeTokens: Int
    let longestRunningTurnSec: Int?
    let longestStreakDays: Int?
    let peakDailyTokens: Int
}

/// 单日 token bucket, startDate 使用 yyyy-MM-dd 作为稳定键
nonisolated struct DailyUsageBucket: Decodable, Equatable {
    let startDate: String
    let tokens: Int
}

/// token 热力图使用的只读快照, 负责按日期聚合重复 bucket
nonisolated struct CodexUsageSnapshot: Equatable {
    let summary: UsageSummary
    let dailyBuckets: [DailyUsageBucket]
    /// 构造时聚合一次; 该快照在菜单面板每次渲染中被反复查询
    private let tokensByDate: [String: Int]

    init(summary: UsageSummary, dailyBuckets: [DailyUsageBucket]) {
        self.summary = summary
        self.dailyBuckets = dailyBuckets
        tokensByDate = dailyBuckets.reduce(into: [String: Int]()) { result, bucket in
            result[bucket.startDate, default: 0] += bucket.tokens
        }
    }

    static func == (lhs: CodexUsageSnapshot, rhs: CodexUsageSnapshot) -> Bool {
        lhs.summary == rhs.summary && lhs.dailyBuckets == rhs.dailyBuckets
    }

    func tokenCount(on date: Date) -> Int? {
        let startDate = CodexDateFormat.dayString(from: date)
        return tokensByDate[startDate]
    }
}
