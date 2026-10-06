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
    let ordinaryUsageAllowed: Bool?
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
            $0.limitID.compare("codex", options: [.caseInsensitive]) == .orderedSame
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
    let limitID: String
    let limitName: String?
    let windows: [QuotaWindow]

    var id: String {
        limitID
    }

    func window(ofKind kind: QuotaWindowKind) -> QuotaWindow? {
        windows.first { $0.kind == kind }
    }

    var title: String {
        if let limitName, !limitName.isEmpty {
            return limitName.capitalizingFirstLetter()
        }

        return limitID.capitalizingFirstLetter()
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

        let minutesPerHour = 60
        let minutesPerDay = 24 * minutesPerHour
        let minutesPerWeek = 7 * minutesPerDay
        let minutesPerMonth = 4 * minutesPerWeek

        if minutes.isMultiple(of: minutesPerMonth) {
            let months = minutes / minutesPerMonth
            return months == 1 ? "Monthly" : "\(months) Months"
        }

        if minutes.isMultiple(of: minutesPerWeek) {
            let weeks = minutes / minutesPerWeek
            return weeks == 1 ? "Weekly" : "\(weeks) Weeks"
        }

        if minutes.isMultiple(of: minutesPerDay) {
            let days = minutes / minutesPerDay
            return days == 1 ? "Daily" : "\(days) Days"
        }

        if minutes.isMultiple(of: minutesPerHour) {
            let hours = minutes / minutesPerHour
            return hours == 1 ? "Hourly" : "\(hours) Hours"
        }

        return "\(minutes) Mins"
    }
}

/// app-server account/rateLimits 原始响应模型
nonisolated struct AccountRateLimitsResponse: Decodable {
    let ordinaryUsageAllowed: Bool?
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitID: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?

    private enum CodingKeys: String, CodingKey {
        case ordinaryUsageAllowed
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitResetCredits
    }
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
    case deadlineReached
}

/// app-server 返回的单个 limit, primary/secondary 可能独立缺失
nonisolated struct RateLimitSnapshot: Decodable {
    let limitID: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: RateLimitCreditsSnapshot?

    private enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName, planType, primary, secondary, credits
    }
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
                CodexQuotaLimitSnapshot(limitID: entry.limitID, snapshot: entry.snapshot)
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
            ordinaryUsageAllowed: rateLimitsResponse?.ordinaryUsageAllowed,
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
        let primaryLimitID = response.rateLimits.limitID ?? "codex"
        return response.rateLimitsByLimitID?[primaryLimitID]?.credits ?? response.rateLimits.credits
    }

    // 展示顺序: 顶层 rateLimits 指向的主 limit 置顶, 其余按名称排序
    private static func orderedSnapshots(
        from response: AccountRateLimitsResponse
    ) -> [(limitID: String, snapshot: RateLimitSnapshot)] {
        let primaryLimitID = response.rateLimits.limitID ?? "codex"

        guard let byLimitID = response.rateLimitsByLimitID, !byLimitID.isEmpty else {
            return [(primaryLimitID, response.rateLimits)]
        }

        return byLimitID
            .map { (limitID: $0.key, snapshot: $0.value) }
            .sorted { lhs, rhs in
                if (lhs.limitID == primaryLimitID) != (rhs.limitID == primaryLimitID) {
                    return lhs.limitID == primaryLimitID
                }

                let lhsName = lhs.snapshot.limitName ?? lhs.limitID
                let rhsName = rhs.snapshot.limitName ?? rhs.limitID
                let nameOrder = lhsName.localizedStandardCompare(rhsName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }

                return lhs.limitID.localizedStandardCompare(rhs.limitID) == .orderedAscending
            }
    }
}

nonisolated extension CodexQuotaLimitSnapshot {
    init?(limitID: String, snapshot: RateLimitSnapshot) {
        let windows = [(QuotaWindowKind.primary, snapshot.primary), (.secondary, snapshot.secondary)]
            .compactMap { kind, window in
                window.map { QuotaWindow(kind: kind, window: $0) }
            }

        guard !windows.isEmpty else {
            return nil
        }

        self.init(
            limitID: limitID,
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
