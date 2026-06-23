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
            return "\(minutes / 1_440)D"
        }
        
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)H"
        }
        
        return "\(minutes)M"
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
