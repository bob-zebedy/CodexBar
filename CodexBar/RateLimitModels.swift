//
//  RateLimitModels.swift
//  CodexBar
//
//  Created by Bob on 2026-06-10.
//

import Foundation

nonisolated struct CodexQuotaSnapshot: Equatable {
    let account: CodexAccount?
    let planType: String?
    let limitName: String?
    let generatedAt: Date
    let fiveHour: QuotaWindow
    let weekly: QuotaWindow
    
    var title: String {
        if let limitName, !limitName.isEmpty {
            return limitName
        }
        
        return "Codex"
    }
    
    var accountLabel: String {
        account?.displayName ?? "未登录"
    }
    
    var planLabel: String? {
        account?.planType ?? planType
    }
}

nonisolated struct CodexAccount: Decodable, Equatable {
    let type: String
    let email: String?
    let planType: String?
    
    var displayName: String {
        if let email, !email.isEmpty {
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
    let requiresOpenaiAuth: Bool
}

nonisolated struct QuotaWindow: Equatable, Identifiable {
    enum Kind: String {
        case fiveHour
        case weekly
    }
    
    let kind: Kind
    let label: String
    let usedPercent: Int?
    let resetsAt: Date?
    
    var id: String { kind.rawValue }
    
    var remainingPercent: Int {
        guard let usedPercent else {
            return 0
        }
        
        return max(0, min(100, 100 - usedPercent))
    }
    
    var hasData: Bool {
        usedPercent != nil
    }
}

nonisolated struct AccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    
    var codexSnapshot: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }
}

nonisolated struct RateLimitSnapshot: Decodable {
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

nonisolated extension CodexQuotaSnapshot {
    init(
        accountResponse: AccountReadResponse,
        rateLimitsResponse: AccountRateLimitsResponse,
        generatedAt: Date = Date()
    ) throws {
        guard let account = accountResponse.account else {
            throw CodexRateLimitError.notLoggedIn
        }
        
        let snapshot = rateLimitsResponse.codexSnapshot
        
        try self.init(
            account: account,
            snapshot: snapshot,
            generatedAt: generatedAt
        )
    }
    
    private init(
        account: CodexAccount?,
        snapshot: RateLimitSnapshot,
        generatedAt: Date
    ) throws {
        guard let primary = snapshot.primary else {
            throw CodexRateLimitError.missingRateLimitWindow("5 小时额度")
        }
        
        self.init(
            account: account,
            planType: snapshot.planType,
            limitName: snapshot.limitName,
            generatedAt: generatedAt,
            fiveHour: QuotaWindow(
                kind: .fiveHour,
                label: Self.windowLabel(for: primary.windowDurationMins, fallback: "5 小时"),
                usedPercent: primary.usedPercent,
                resetsAt: primary.resetDate
            ),
            weekly: QuotaWindow(
                kind: .weekly,
                label: Self.windowLabel(for: snapshot.secondary?.windowDurationMins, fallback: "7 天"),
                usedPercent: snapshot.secondary?.usedPercent,
                resetsAt: snapshot.secondary?.resetDate
            )
        )
    }
    
    private static func windowLabel(for minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else {
            return fallback
        }
        
        if minutes < 60 {
            return "\(minutes) 分钟"
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

nonisolated enum CodexRateLimitError: LocalizedError {
    case executableNotFound
    case serverStartFailed(String)
    case serverTimeout(String)
    case serverError(String)
    case missingRateLimitWindow(String)
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
        case .missingRateLimitWindow(let name):
            return "查询不到 \(name)"
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
}
