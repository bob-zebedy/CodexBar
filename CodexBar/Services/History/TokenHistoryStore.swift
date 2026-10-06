import CryptoKit
import Darwin
import Foundation
import os

/// 仅保存订阅期间取得的轮次累计快照, 不扫描 Codex 会话文件
actor TokenHistoryStore {
    private let directoryURL: URL
    private var recordingLease: Int32?
    private var journal = AppServerEventJournal()
    private var journalFiles: [String: TokenJournalCheckpoint] = [:]
    private var scannedFiles: [String: HistoryFileStat] = [:]

    init(directoryURL: URL = HistoryStorage.directoryURL()) {
        self.directoryURL = directoryURL
    }

    deinit {
        if let recordingLease {
            JSONFileStorage.releaseLock(recordingLease)
        }
    }

    /// 同机多个 App 可以旁观, 但只有一个采集器累计 Token, 避免不同基线覆盖彼此
    func acquireRecordingLease() throws -> Bool {
        if recordingLease != nil {
            return true
        }
        recordingLease = try JSONFileStorage.acquireLock(in: directoryURL.appendingPathComponent("Locks"), name: "tokens.lock", nonblocking: true)
        return recordingLease != nil
    }

    func releaseRecordingLease() {
        if let recordingLease {
            JSONFileStorage.releaseLock(recordingLease)
        }
        recordingLease = nil
    }

    func record(_ turns: [TokenTurn], sources: [String: AppServerEventSource] = [:], now: Date = Date()) throws {
        guard !turns.isEmpty else { return }
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var records = try load(now: now)
            var changed: [TokenTurn] = []
            for turn in turns {
                let merged = records[turn.id]?.merging(turn) ?? turn
                if records[turn.id] != merged {
                    changed.append(merged)
                }
                records[turn.id] = merged
            }
            // 日志先于快照提交, 意外退出后可以从已采集的数据重建
            let roots = Set(changed.map(\.rootID))
            try saveObservedTurns(changed + roots.compactMap { records[$0] }, sources: sources, now: now)
            records = retained(records, now: now)
            try save(records)
        }
    }

    func recordObservations(_ observations: [TokenObservation], now: Date = Date()) throws -> [TokenTurn] {
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var records = try load(now: now)
            for observation in observations {
                let existing = records[observation.turn.id]
                let updated = try observation.applying(to: existing)
                // 原始观测先落盘, 快照失败后按同一检查点重放, 重试不会重复累计
                try journal.append(AppServerEventRecord(observation: observation, recordedAt: now), in: directoryURL)
                records[updated.id] = updated
                Self.ensureRoot(for: observation, in: &records)
            }
            try save(records)
            return Array(records.values)
        }
    }

    private static func ensureRoot(for observation: TokenObservation, in records: inout [String: TokenTurn]) {
        let turn = observation.turn
        if turn.rootID != turn.id, records[turn.rootID] == nil {
            records[turn.rootID] = TokenTurn(
                id: turn.rootID,
                rootID: turn.rootID,
                startedAt: observation.rootStartedAt,
                updatedAt: turn.updatedAt
            )
        }
    }

    func refresh(now: Date = Date(), baseline: TokenHistoryBaseline? = nil) throws -> [TokenTurn] {
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            var records = try load(now: now)
            var replacements: [TokenTurn] = []
            if let baseline {
                for (id, turn) in records {
                    if let replacement = baseline.replacement(for: turn) {
                        records[id] = replacement
                        if replacement != turn {
                            replacements.append(replacement)
                        }
                    }
                }
            }
            let roots = Set(replacements.map(\.rootID))
            try saveObservedTurns(replacements + roots.compactMap { records[$0] }, now: now)
            records = retained(records, now: now)
            try save(records)
            return Array(records.values)
        }
    }

    func currentTurns(now: Date = Date()) throws -> [TokenTurn] {
        try HistoryStorage.withExclusiveLock(in: directoryURL) { try Array(load(now: now).values) }
    }

    func rebuildableDateKeys(now: Date = Date()) throws -> [String] {
        try Array(TokenTurn.dailyUsage(currentTurns(now: now), now: now).keys).sorted()
    }

    func rebuild(for dateKeys: [String], now: Date = Date()) throws -> TokenRebuildResult {
        try HistoryStorage.withExclusiveLock(in: directoryURL) {
            let recorded = try journalTurns(now: now)
            let dates = Set(dateKeys)
            var ledger = try load(now: now)
            var count = 0
            var rebuiltDates = Set<String>()
            var rebuiltTurns: [TokenTurn] = []
            for var turn in recorded.values {
                guard let rootStart = recorded[turn.rootID]?.startedAt else { continue }
                let date = CodexDateFormat.dayString(from: rootStart)
                guard dates.contains(date) else { continue }
                let previous = ledger[turn.id]
                guard turn.covers(previous?.checkpoint ?? [:]) else { throw TokenCacheError.incompleteJournal }
                turn.generationID = previous?.generationID ?? turn.generationID
                turn.ancestorIDs = previous?.ancestorIDs ?? []
                turn.startNewGeneration(at: now)
                ledger[turn.id] = turn
                rebuiltTurns.append(turn)
                rebuiltDates.insert(date)
                count += 1
            }
            try saveObservedTurns(rebuiltTurns, now: now)
            try save(ledger)
            return TokenRebuildResult(dateKeys: rebuiltDates.sorted(), turnCount: count)
        }
    }

    private func saveObservedTurns(_ records: [TokenTurn], sources: [String: AppServerEventSource] = [:], now: Date) throws {
        for record in TokenTurn.merged(records).values.sorted(by: { $0.id < $1.id }) {
            try journal.append(AppServerEventRecord(token: record, source: sources[record.id], recordedAt: now), in: directoryURL)
        }
    }

    private func journalTurns(now: Date) throws -> [String: TokenTurn] {
        let directory = HistoryStorage.eventsDirectoryURL(in: directoryURL)
        let cutoff = CodexDateFormat.dayString(from: HistoryStorage.retentionCutoffDate(today: now))
        var result: [String: TokenTurn] = [:]
        for date in HistoryStorage.eventLogDateKeys(in: directory) where date >= cutoff {
            let url = HistoryStorage.eventLogURL(for: date, in: directory)
            var invalid = false
            try AppServerEventJournal.read(at: url, onInvalidLine: { invalid = true }, consume: { entry in
                if let observation = entry.observation {
                    result[observation.turn.id] = try observation.applying(to: result[observation.turn.id])
                    Self.ensureRoot(for: observation, in: &result)
                }
            })
            if invalid {
                throw TokenCacheError.incompleteJournal
            }
        }
        return result
    }

    private var ledgerURL: URL {
        directoryURL.appendingPathComponent("Aggregates/tokens.json")
    }

    private func load(now: Date) throws -> [String: TokenTurn] {
        let cache: TokenAggregateCache?
        do {
            let data = try Data(contentsOf: ledgerURL)
            // 版本先于完整解码检查, 不把其他版本的数据当成损坏缓存覆盖
            struct Version: Decodable { let version: Int }
            let version = try JSONDecoder().decode(Version.self, from: data).version
            guard version == TokenAggregateCache.currentVersion else { throw TokenCacheError.unsupportedVersion(version) }
            cache = try AppServerEventRecord.decode(TokenAggregateCache.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            cache = nil
        } catch is DecodingError {
            AppLog.history.error("Token 缓存损坏, 从原始事件恢复")
            cache = nil
        }
        if cache == nil {
            journalFiles.removeAll()
            scannedFiles.removeAll()
        }
        var records = cache?.turns ?? [:]
        journalFiles = cache?.files ?? [:]
        let directory = HistoryStorage.eventsDirectoryURL(in: directoryURL)
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        let dates = HistoryStorage.eventLogDateKeys(in: directory).filter { $0 >= cutoff }
        journalFiles = journalFiles.filter { dates.contains($0.key) }
        scannedFiles = scannedFiles.filter { dates.contains($0.key) }
        for date in dates {
            let url = HistoryStorage.eventLogURL(for: date, in: directory)
            guard let stat = HistoryStorage.fileStat(at: url) else { continue }
            let previous = journalFiles[date]
            if previous?.size == stat.size, previous?.identifier == stat.identifier,
               previous?.modificationTime == stat.modificationTime, scannedFiles[date] == stat {
                continue
            }
            let offset = previous.flatMap { $0.identifier == stat.identifier && $0.size < stat.size ? $0.size : nil } ?? 0
            var invalid = false
            try AppServerEventJournal.read(at: url, from: offset, onInvalidLine: { invalid = true }, consume: { entry in
                if let observation = entry.observation {
                    records[observation.turn.id] = try observation.applying(to: records[observation.turn.id])
                    Self.ensureRoot(for: observation, in: &records)
                } else if let turn = entry.token {
                    records[turn.id] = records[turn.id]?.merging(turn) ?? turn
                }
            })
            if invalid, cache == nil {
                throw TokenCacheError.incompleteJournal
            }
            journalFiles[date] = TokenJournalCheckpoint(size: stat.size, identifier: stat.identifier, modificationTime: stat.modificationTime)
            scannedFiles[date] = stat
        }
        return retained(records, now: now)
    }

    private func save(_ records: [String: TokenTurn]) throws {
        // 日志与缓存共用时间编码, 避免 epoch 换算精度差异影响重建标记比较
        let data = try AppServerEventRecord.encode(TokenAggregateCache(turns: records, files: journalFiles))
        guard (try? Data(contentsOf: ledgerURL)) != data else { return }
        try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: ledgerURL, options: .atomic)
    }

    private func retained(_ records: [String: TokenTurn], now: Date) -> [String: TokenTurn] {
        let cutoff = HistoryStorage.retentionCutoffDate(today: now)
        let roots = Set(records.values.filter { $0.updatedAt >= cutoff }.map(\.rootID))
        return records.filter { $0.value.updatedAt >= cutoff || roots.contains($0.key) }
    }
}

private nonisolated struct TokenAggregateCache: Codable {
    static let currentVersion = 2
    var version = Self.currentVersion
    var turns: [String: TokenTurn]
    var files: [String: TokenJournalCheckpoint]
}

private nonisolated struct TokenJournalCheckpoint: Codable {
    let size: UInt64
    let identifier: UInt64
    let modificationTime: Int64
}

nonisolated struct TokenRebuildResult {
    let dateKeys: [String]
    let turnCount: Int
    static let empty = Self(dateKeys: [], turnCount: 0)
}

nonisolated struct TokenFileCache<Value: Codable & Equatable> {
    let url: URL
    private var data: Data?
    private var value: Value?

    init(url: URL) {
        self.url = url
    }

    mutating func load(validate: (Data) throws -> Void = { _ in }) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            data = nil
            value = nil
            return nil
        }
        let current = try Data(contentsOf: url)
        if current == data {
            return value
        }
        try validate(current)
        let decoded = try JSONLines.decoder.decode(Value.self, from: current)
        data = current
        value = decoded
        return decoded
    }

    mutating func save(_ updated: Value) throws {
        let current = try? Data(contentsOf: url)
        if let current, current == data, updated == value {
            return
        }
        let encoded = try JSONLines.stableEncoder.encode(updated)
        if current != encoded {
            try encoded.write(to: url, options: .atomic)
        }
        data = encoded
        value = updated
    }
}

nonisolated enum TokenCacheError: Error { case unsupportedVersion(Int), incompleteJournal }
