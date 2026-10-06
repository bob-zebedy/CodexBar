import CryptoKit
import Foundation

/// 一条线程轮次的累计快照, 身份只保存哈希, 不保存对话正文或原始 ID
nonisolated struct TokenTurn: Codable, Equatable, Identifiable {
    let id: String
    var rootID: String
    var startedAt: Date?
    var updatedAt: Date
    var usage: TokenUsage?
    var rebuiltAt: Date?
    var generationID: String
    var ancestorIDs: Set<String>
    var checkpoint: [String: TokenObservationCheckpoint]
    var hasConflict: Bool

    init(
        id: String,
        rootID: String,
        startedAt: Date? = nil,
        updatedAt: Date,
        usage: TokenUsage? = nil,
        rebuiltAt: Date? = nil,
        generationID: String = "initial",
        ancestorIDs: Set<String> = [],
        checkpoint: [String: TokenObservationCheckpoint] = [:],
        hasConflict: Bool = false
    ) {
        self.id = id
        self.rootID = rootID
        self.startedAt = startedAt.map(JSONLines.storageDate)
        self.updatedAt = JSONLines.storageDate(updatedAt)
        self.usage = usage
        self.rebuiltAt = rebuiltAt.map(JSONLines.storageDate)
        self.generationID = generationID
        self.ancestorIDs = ancestorIDs
        self.checkpoint = checkpoint
        self.hasConflict = hasConflict
    }

    private enum CodingKeys: String, CodingKey {
        case id, rootID, startedAt, updatedAt, usage, rebuiltAt
        case generationID, ancestorIDs, checkpoint, hasConflict
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(rootID, forKey: .rootID)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(rebuiltAt, forKey: .rebuiltAt)
        try container.encode(generationID, forKey: .generationID)
        try container.encode(ancestorIDs.sorted(), forKey: .ancestorIDs)
        try container.encode(checkpoint, forKey: .checkpoint)
        try container.encode(hasConflict, forKey: .hasConflict)
    }

    static func identifier(thread: String, turn: String) -> String {
        // 哈希身份域是固定输入, 不随存储 version 变化, 避免同一轮次生成多个身份
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
        if generationID != other.generationID {
            if ancestorIDs.contains(other.generationID) {
                return incorporatingUncoveredObservations(from: other)
            }
            if other.ancestorIDs.contains(generationID) {
                return other.incorporatingUncoveredObservations(from: self)
            }
            return conflicting(with: other)
        }
        if hasConflict || other.hasConflict {
            return conflicting(with: other)
        }
        if !checkpoint.isEmpty || !other.checkpoint.isEmpty {
            let coversOther = covers(other.checkpoint)
            let otherCovers = other.covers(checkpoint)
            if coversOther && !otherCovers {
                return self
            }
            if otherCovers && !coversOther {
                return other
            }
            if !coversOther || usage != other.usage {
                return conflicting(with: other)
            }
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

    func covers(_ boundary: [String: TokenObservationCheckpoint]) -> Bool {
        boundary.allSatisfy { id, value in
            guard let current = checkpoint[id], current.sequence >= value.sequence else { return false }
            return current.sequence != value.sequence || current.usage == value.usage
        }
    }

    mutating func startNewGeneration(at date: Date) {
        ancestorIDs.insert(generationID)
        generationID = UUID().uuidString.lowercased()
        rebuiltAt = JSONLines.storageDate(date)
    }

    private func incorporatingUncoveredObservations(from old: Self) -> Self {
        var result = self
        guard !hasConflict else { return conflicting(with: old) }
        for (stream, incoming) in old.checkpoint {
            guard let covered = checkpoint[stream] else { return conflicting(with: old) }
            if incoming.sequence == covered.sequence, incoming.usage != covered.usage {
                return conflicting(with: old)
            }
            guard incoming.sequence > covered.sequence else { continue }
            guard let delta = incoming.usage.subtracting(covered.usage),
                  let usage = result.usage?.adding(delta), usage.isValid else { return conflicting(with: old) }
            result.usage = usage
            result.checkpoint[stream] = incoming
            result.updatedAt = max(result.updatedAt, old.updatedAt)
        }
        return result
    }

    private func conflicting(with other: Self) -> Self {
        var result = self
        // 冲突保留可恢复的边界, 不把任意分支的用量当成权威结果
        let generations = ancestorIDs.union(other.ancestorIDs)
            .union([generationID, other.generationID])
        if generationID != other.generationID {
            if ancestorIDs.contains(other.generationID) {
                result.generationID = generationID
            } else if other.ancestorIDs.contains(generationID) {
                result.generationID = other.generationID
            } else {
                let origins = generations.filter { !$0.hasPrefix("conflict-") }.sorted()
                result.generationID = "conflict-" + Self.hexString(SHA256.hash(data: Data(origins.joined(separator: ":").utf8)))
            }
        }
        result.ancestorIDs = generations.subtracting([result.generationID])
        result.hasConflict = true
        result.usage = nil
        result.rebuiltAt = [rebuiltAt, other.rebuiltAt].compactMap(\.self).max()
        result.updatedAt = max(updatedAt, other.updatedAt)
        result.startedAt = [startedAt, other.startedAt].compactMap(\.self).min()
        for (stream, incoming) in other.checkpoint {
            let current = result.checkpoint[stream]
            if incoming.sequence > (current?.sequence ?? 0)
                || (incoming.sequence == current?.sequence && Self.usageOrder(current?.usage ?? .zero).lexicographicallyPrecedes(Self.usageOrder(incoming.usage))) {
                result.checkpoint[stream] = incoming
            }
        }
        return result
    }

    static func merged(_ records: [Self]) -> [String: Self] {
        records.reduce(into: [:]) { result, record in
            result[record.id] = result[record.id]?.merging(record) ?? record
        }
    }

    static func dailyUsage(_ records: [Self], now: Date = Date()) -> [String: TokenUsage] {
        let byID = merged(records)
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        var result: [String: TokenUsage] = [:]
        var invalidDates: Set<String> = []
        for record in byID.values {
            if record.hasConflict, let start = byID[record.rootID]?.startedAt {
                invalidDates.insert(CodexDateFormat.dayString(from: start))
            }
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
            startedAt: startedAt, updatedAt: updatedAt, usage: usage, rebuiltAt: rebuiltAt,
            generationID: generationID, ancestorIDs: ancestorIDs,
            checkpoint: checkpoint, hasConflict: hasConflict
        )
    }

    static func syncable(_ records: [Self]) -> [Self] {
        let rootIDs = Set(records.filter { $0.usage != nil }.map(\.rootID))
        return records.filter { $0.usage != nil || $0.generationID != "initial" || $0.hasConflict || rootIDs.contains($0.id) }
    }

    private static func usageOrder(_ usage: TokenUsage) -> [Int64] {
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
nonisolated struct TokenHistoryBaseline {
    let salt: Data
    private let turns: [String: TokenTurn]
    init(salt: Data, turns: [String: TokenTurn]) {
        self.salt = salt
        self.turns = turns
    }

    func replacement(for local: TokenTurn) -> TokenTurn? {
        let exported = local.pseudonymized(salt: salt)
        guard var remote = turns[exported.id], remote.rootID == exported.rootID else { return nil }
        remote = exported.merging(remote)
        guard remote != exported else { return nil }
        return TokenTurn(
            id: local.id, rootID: local.rootID, startedAt: remote.startedAt ?? local.startedAt,
            updatedAt: remote.updatedAt, usage: remote.usage, rebuiltAt: remote.rebuiltAt,
            generationID: remote.generationID, ancestorIDs: remote.ancestorIDs,
            checkpoint: remote.checkpoint, hasConflict: remote.hasConflict
        )
    }
}

nonisolated struct TokenObservationCheckpoint: Codable, Equatable {
    var sequence: Int64
    var usage: TokenUsage
}

/// streamID 是每次采集连续区间生成的随机身份, 不包含设备或原始线程信息
nonisolated struct TokenObservation: Codable, Equatable {
    let turn: TokenTurn
    let rootStartedAt: Date?
    let streamID: String
    let sequence: Int64
    let previous: TokenUsage
    let current: TokenUsage

    func applying(to existing: TokenTurn?) throws -> TokenTurn {
        var result = existing ?? turn
        let boundary = result.checkpoint[streamID]
        if let boundary, boundary.sequence >= sequence {
            return result
        }
        guard sequence == (boundary?.sequence ?? 0) + 1,
              let delta = current.subtracting(previous),
              let observed = (boundary?.usage ?? .zero).adding(delta), observed.isValid else {
            throw TokenCacheError.incompleteJournal
        }
        if !result.hasConflict {
            guard let usage = (result.usage ?? .zero).adding(delta), usage.isValid else {
                throw TokenCacheError.incompleteJournal
            }
            result.usage = usage
        }
        result.checkpoint[streamID] = TokenObservationCheckpoint(sequence: sequence, usage: observed)
        result.updatedAt = max(result.updatedAt, turn.updatedAt)
        return result
    }
}
