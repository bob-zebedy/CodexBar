import Foundation

/// 由 account/rateLimits/usage 三路 app-server 响应合成的菜单面板快照
nonisolated struct CodexQuotaSnapshot: Equatable {
    let account: CodexAccount
    let planType: String?
    let resetCreditsAvailableCount: Int?
    let resetCreditExpirationDates: [Date]?
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

    var hasTrustedData: Bool {
        hasTrustedRateLimitsData || hasTrustedUsageData
    }

    private var hasTrustedRateLimitsData: Bool {
        !limits.isEmpty && !isRateLimitsStale
    }

    private var hasTrustedUsageData: Bool {
        usage != nil && !isUsageStale
    }
}

/// 单个额度类型的展示快照, 例如 codex 或其他 limit id
nonisolated struct CodexQuotaLimitSnapshot: Equatable, Identifiable {
    let limitId: String
    let limitName: String?
    let windows: [QuotaWindow]

    var id: String {
        limitId
    }

    var title: String {
        if let limitName, !limitName.isEmpty {
            return limitName.capitalizingFirstLetter()
        }

        return limitId.capitalizingFirstLetter()
    }
}

private nonisolated extension String {
    func capitalizingFirstLetter() -> String {
        guard let first else {
            return self
        }

        return first.uppercased() + dropFirst()
    }
}

/// primary/secondary 窗口的 UI 友好表示, 统一计算剩余额度百分比
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

        if minutes.isMultiple(of: 1440) {
            return "\(minutes / 1440)d"
        }

        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)h"
        }

        return "\(minutes)m"
    }
}

/// app-server account/rateLimits 原始响应模型
nonisolated struct AccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
}

/// app-server 返回的可用额度重置次数
nonisolated struct RateLimitResetCreditsSummary: Decodable {
    let availableCount: Int
}

/// app-server 返回的单个 limit, primary/secondary 可能独立缺失
nonisolated struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

/// resetsAt 是 Unix 时间戳, 在模型层先转成 Date 方便 UI 格式化
nonisolated struct RateLimitWindow: Decodable {
    let usedPercent: Int?
    let resetsAt: Int?
    let windowDurationMins: Int?

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }
}

nonisolated extension CodexQuotaSnapshot {
    init(
        accountResponse: AccountReadResponse,
        rateLimitsResponse: AccountRateLimitsResponse?,
        resetCreditExpirationDates: [Date]? = nil,
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

        // rateLimits/usage 可同时为空
        // 账户有效时仍生成快照给 UI 展示 `暂无数据`

        self.init(
            account: account,
            planType: rateLimitsResponse?.rateLimits.planType,
            resetCreditsAvailableCount: rateLimitsResponse?.rateLimitResetCredits?.availableCount,
            resetCreditExpirationDates: resetCreditExpirationDates,
            generatedAt: generatedAt,
            limits: limits,
            usage: usage,
            isRateLimitsStale: isRateLimitsStale,
            isUsageStale: isUsageStale
        )
    }

    // 展示顺序: 顶层 rateLimits 指向的主 limit 置顶, 其余按名称排序
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
