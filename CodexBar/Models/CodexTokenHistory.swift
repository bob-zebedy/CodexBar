import CryptoKit
import Foundation

/// 一条线程轮次的累计快照, 身份只保存哈希, 不保存对话正文或原始 ID
nonisolated struct CodexTokenTurn: Codable, Equatable, Identifiable {
    let id: String
    var rootID: String
    var startedAt: Date?
    var updatedAt: Date
    var usage: CodexTokenUsage?
    var rebuiltAt: Date?

    static func identifier(thread: String, turn: String) -> String {
        // 哈希身份域是固定输入, 不随存储 schema 变化, 避免同一轮次生成多个身份
        let data = (try? JSONEncoder().encode(["token-turn-v1", thread, turn])) ?? Data()
        return hexString(SHA256.hash(data: data))
    }

    static func hexString(_ bytes: some Sequence<UInt8>) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return String(bytes: result, encoding: .utf8) ?? ""
    }

    func merging(_ other: Self) -> Self {
        precondition(id == other.id)
        // 显式重建允许修正为更小的用量, 旧缓存不能再以累计值较大为由恢复错误结果
        if rebuiltAt != other.rebuiltAt {
            return (rebuiltAt ?? .distantPast) > (other.rebuiltAt ?? .distantPast) ? self : other
        }
        var result = self
        if rootID == id {
            result.rootID = other.rootID
        }
        if let date = other.startedAt {
            result.startedAt = min(startedAt ?? date, date)
        }
        result.updatedAt = max(updatedAt, other.updatedAt)
        if let candidate = other.usage, candidate.isValid {
            if let current = usage {
                // 同一累计快照的副本和较短扫描都不能重复累加或覆盖更完整的数据
                if Self.usageOrder(candidate).lexicographicallyPrecedes(Self.usageOrder(current)) == false {
                    result.usage = candidate
                }
            } else {
                result.usage = candidate
            }
        }
        return result
    }

    static func merged(_ records: [Self]) -> [String: Self] {
        records.reduce(into: [:]) { result, record in
            result[record.id] = result[record.id]?.merging(record) ?? record
        }
    }

    static func dailyUsage(_ records: [Self], now: Date = Date()) -> [String: CodexTokenUsage] {
        let byID = merged(records)
        let cutoff = WorkflowStorage.retentionCutoffDate(today: now)
        var result: [String: CodexTokenUsage] = [:]
        var invalidDates: Set<String> = []
        for record in byID.values {
            guard let usage = record.usage, usage.isValid,
                  let start = byID[record.rootID]?.startedAt, start >= cutoff, start <= now else { continue }
            let date = CodexDateFormat.dayString(from: start)
            if let current = result[date] {
                if let sum = current.adding(usage) {
                    result[date] = sum
                } else {
                    invalidDates.insert(date)
                }
            } else {
                result[date] = usage
            }
        }
        for date in invalidDates {
            result.removeValue(forKey: date)
        }
        return result
    }

    func pseudonymized(salt: Data) -> Self {
        let key = SymmetricKey(data: salt)
        return pseudonymized { value in
            Self.hexString(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key))
        }
    }

    static func pseudonymized(_ records: [Self], salt: Data) -> [Self] {
        let key = SymmetricKey(data: salt)
        var identities: [String: String] = [:]
        return records.map { record in
            record.pseudonymized { value in
                if let cached = identities[value] {
                    return cached
                }
                let hashed = hexString(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key))
                identities[value] = hashed
                return hashed
            }
        }
    }

    private func pseudonymized(hash: (String) -> String) -> Self {
        let exportedID = hash(id)
        return Self(
            id: exportedID, rootID: rootID == id ? exportedID : hash(rootID),
            startedAt: startedAt, updatedAt: updatedAt, usage: usage, rebuiltAt: rebuiltAt
        )
    }

    static func syncable(_ records: [Self]) -> [Self] {
        let rootIDs = Set(records.filter { $0.usage != nil }.map(\.rootID))
        return records.filter { $0.usage != nil || $0.rebuiltAt != nil || rootIDs.contains($0.id) }
    }

    private static func usageOrder(_ usage: CodexTokenUsage) -> [Int64] {
        [
            usage.totalTokens,
            usage.inputTokens,
            usage.outputTokens,
            usage.cachedInputTokens,
            usage.cacheWriteInputTokens,
            usage.reasoningOutputTokens
        ]
    }
}

/// 云端身份只通过账户 salt 与本地已发现的轮次匹配, 不导入其他设备的轮次
nonisolated struct CodexTokenHistoryBaseline {
    let salt: Data
    private let turns: [String: CodexTokenTurn]
    private let latestRebuiltAt: Date?

    init(salt: Data, turns: [String: CodexTokenTurn]) {
        self.salt = salt
        self.turns = turns.filter { $0.value.rebuiltAt != nil }
        latestRebuiltAt = self.turns.values.compactMap(\.rebuiltAt).max()
    }

    func replacement(for local: CodexTokenTurn) -> CodexTokenTurn? {
        guard let latestRebuiltAt, latestRebuiltAt > (local.rebuiltAt ?? .distantPast) else { return nil }
        let exported = local.pseudonymized(salt: salt)
        guard let remote = turns[exported.id], let rebuiltAt = remote.rebuiltAt,
              rebuiltAt > (local.rebuiltAt ?? .distantPast), remote.rootID == exported.rootID else { return nil }
        return CodexTokenTurn(
            id: local.id, rootID: local.rootID, startedAt: remote.startedAt ?? local.startedAt,
            updatedAt: remote.updatedAt, usage: remote.usage, rebuiltAt: rebuiltAt
        )
    }
}
