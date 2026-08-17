import Foundation

nonisolated enum CodexPercentageFormat {
    static func string(from percent: Int) -> String {
        percent.formatted(
            .percent
                .scale(1)
                .precision(.fractionLength(0))
                .locale(.autoupdatingCurrent)
        )
    }
}

/// 由 account/rateLimits/usage 三路 app-server 响应合成的菜单面板快照
nonisolated struct CodexQuotaSnapshot: Equatable {
    let account: CodexAccount
    let planType: String?
    let credits: RateLimitCreditsSnapshot?
    let resetCreditsAvailableCount: Int?
    let resetCreditExpirationDates: [Date]?
    let autoResetCandidates: [AutoResetCandidate]?
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

    var codexLimit: CodexQuotaLimitSnapshot? {
        limits.first {
            $0.limitId.compare("codex", options: [.caseInsensitive]) == .orderedSame
        }
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

    func window(ofKind kind: QuotaWindowKind) -> QuotaWindow? {
        windows.first { $0.kind == kind }
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

/// primary/secondary 窗口的稳定标识; 这组词汇由模型层拥有
/// 菜单栏额度指示偏好 (MenuBarQuotaSelection) 与窗口查找都经它互转
nonisolated enum QuotaWindowKind: String, Equatable {
    case primary
    case secondary
}

/// primary/secondary 窗口的 UI 友好表示, 统一计算剩余额度百分比
nonisolated struct QuotaWindow: Equatable, Identifiable {
    let kind: QuotaWindowKind
    let windowDurationMins: Int?
    let usedPercent: Int?
    let resetsAt: Date?

    var id: String {
        kind.rawValue
    }

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
            return String(localized: "quota.window.fallback")
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

/// app-server 返回的可用额度重置次数和明细
nonisolated struct RateLimitResetCreditsSummary: Decodable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?

    func availableExpirationDates(now: Date) -> [Date]? {
        guard availableCount > 0, let credits else {
            return nil
        }

        return credits.compactMap { credit in
            guard credit.status == "available", let expirationDate = credit.expirationDate,
                  expirationDate > now else {
                return nil
            }

            return expirationDate
        }
        .sorted()
    }

    /// 自动重置只接受 app-server 明确返回的可用 Codex 额度重置凭证
    var autoResetCandidates: [AutoResetCandidate]? {
        guard let credits else {
            return nil
        }

        return credits.compactMap { credit in
            guard credit.status == "available",
                  credit.resetType == "codexRateLimits",
                  let expirationDate = credit.expirationDate else {
                return nil
            }

            return AutoResetCandidate(
                id: credit.id,
                expirationDate: expirationDate
            )
        }
    }
}

/// app-server 返回的单个额度重置凭证
nonisolated struct RateLimitResetCredit: Decodable {
    let id: String
    let status: String
    let resetType: String
    let expiresAt: Int64?

    var expirationDate: Date? {
        expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// 自动重置链路需要的最小凭证快照
nonisolated struct AutoResetCandidate: Equatable, Sendable {
    let id: String
    let expirationDate: Date
}

/// 自动重置前强制读取的账号和重置凭证明细
nonisolated struct AutoResetRead: Sendable {
    let accountIdentity: String
    let availableCount: Int?
    let candidates: [AutoResetCandidate]?
}

/// app-server 消费重置凭证的稳定结果集合
nonisolated enum ResetCreditConsumeOutcome: String, Decodable, Sendable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

nonisolated struct ResetCreditConsumeResponse: Decodable, Sendable {
    let outcome: ResetCreditConsumeOutcome
}

nonisolated struct ResetCreditConsumeResult: Sendable {
    let outcome: ResetCreditConsumeOutcome
    let refreshedRead: AutoResetRead?
}

nonisolated enum AutoResetServiceError: Error, Sendable {
    case accountChanged
}

/// app-server 返回的单个 limit, primary/secondary 可能独立缺失
nonisolated struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: RateLimitCreditsSnapshot?
}

/// app-server 返回的 Credits 余额状态
nonisolated struct RateLimitCreditsSnapshot: Decodable, Equatable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
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
        let resetCreditExpirationDates = rateLimitsResponse?
            .rateLimitResetCredits?
            .availableExpirationDates(now: generatedAt)
        let autoResetCandidates = rateLimitsResponse?
            .rateLimitResetCredits?
            .autoResetCandidates

        // rateLimits/usage 可同时为空
        // 账户有效时仍生成快照给 UI 展示 `暂无数据`

        self.init(
            account: account,
            planType: rateLimitsResponse?.rateLimits.planType,
            credits: rateLimitsResponse.flatMap { Self.primaryCredits(from: $0) },
            resetCreditsAvailableCount: rateLimitsResponse?.rateLimitResetCredits?.availableCount,
            resetCreditExpirationDates: resetCreditExpirationDates,
            autoResetCandidates: autoResetCandidates,
            generatedAt: generatedAt,
            limits: limits,
            usage: usage,
            isRateLimitsStale: isRateLimitsStale,
            isUsageStale: isUsageStale
        )
    }

    private static func primaryCredits(from response: AccountRateLimitsResponse) -> RateLimitCreditsSnapshot? {
        let primaryLimitId = response.rateLimits.limitId ?? "codex"
        return response.rateLimitsByLimitId?[primaryLimitId]?.credits ?? response.rateLimits.credits
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
        let windows = [(QuotaWindowKind.primary, snapshot.primary), (.secondary, snapshot.secondary)]
            .compactMap { kind, window in
                window.map { QuotaWindow(kind: kind, window: $0) }
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
    init(kind: QuotaWindowKind, window: RateLimitWindow) {
        self.init(
            kind: kind,
            windowDurationMins: window.windowDurationMins,
            usedPercent: window.usedPercent,
            resetsAt: window.resetDate
        )
    }
}
