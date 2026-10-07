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
            var ledger = try load(now: now)
            let replay = try journalTurns(now: now, baseline: ledger)
            let dates = Set(dateKeys)
            let roots = try replay.selectedRoots(in: dates)
            var rebuiltDates = Set<String>()
            var failedDates = Set<String>()
            var rebuiltTurns: [TokenTurn] = []
            let existingByRoot = Dictionary(grouping: ledger.values, by: \.rootID)
            let recordedByRoot = Dictionary(grouping: replay.records.values, by: \.rootID)
            for (root, date) in roots.sorted(by: { $0.key < $1.key }) {
                let candidates = recordedByRoot[root] ?? []
                let coversExisting = (existingByRoot[root] ?? []).allSatisfy { previous in
                    guard let candidate = replay.records[previous.id] else { return false }
                    return candidate.covers(previous.checkpoint)
                        && (previous.usage == nil || candidate.usage != nil)
                }
                guard !replay.failedRoots.contains(root), !candidates.isEmpty, coversExisting else {
                    failedDates.insert(date)
                    continue
                }
                // 同一根轮次的全部成员先通过检查, 再生成修正记录
                for var turn in candidates {
                    let previous = ledger[turn.id]
                    turn.generationID = previous?.generationID ?? turn.generationID
                    turn.ancestorIDs = previous?.ancestorIDs ?? []
                    turn.startNewGeneration(at: now)
                    ledger[turn.id] = turn
                    rebuiltTurns.append(turn)
                }
                rebuiltDates.insert(date)
            }
            try saveObservedTurns(rebuiltTurns, now: now)
            try save(ledger)
            return TokenRebuildResult(
                dateKeys: rebuiltDates.sorted(), turnCount: rebuiltTurns.count,
                failedDateKeys: failedDates.sorted(), turns: Array(ledger.values)
            )
        }
    }

    private func saveObservedTurns(_ records: [TokenTurn], now: Date) throws {
        for record in TokenTurn.merged(records).values.sorted(by: { $0.id < $1.id }) {
            try journal.append(AppServerEventRecord(token: record, recordedAt: now), in: directoryURL)
        }
    }

    private func journalTurns(now: Date, baseline: [String: TokenTurn]) throws -> TokenJournalReplay {
        var replay = try TokenJournalReplay(baseline: baseline, replayingFromEmpty: true)
        for date in journalDates(now: now) {
            let url = HistoryStorage.eventLogURL(for: date, in: HistoryStorage.eventsDirectoryURL(in: directoryURL))
            var invalid = false
            try AppServerEventJournal.read(at: url, onInvalidLine: { invalid = true }, consume: { entry in
                try replay.consume(entry, includesSnapshots: false)
            })
            if invalid {
                throw TokenCacheError.incompleteJournal
            }
        }
        return replay
    }

    private func journalDates(now: Date) -> [String] {
        let directory = HistoryStorage.eventsDirectoryURL(in: directoryURL)
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        return HistoryStorage.eventLogDateKeys(in: directory).filter { $0 >= cutoff }
    }

    private var ledgerURL: URL {
        directoryURL.appendingPathComponent("Aggregates/tokens.json")
    }

    private func readCache() throws -> TokenAggregateCache? {
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
        return cache
    }

    private func load(now: Date) throws -> [String: TokenTurn] {
        let cache = try readCache()
        if cache == nil {
            journalFiles.removeAll()
            scannedFiles.removeAll()
        }
        let baseline = cache?.turns ?? [:]
        var replay = try TokenJournalReplay(baseline: baseline)
        journalFiles = cache?.files ?? [:]
        let directory = HistoryStorage.eventsDirectoryURL(in: directoryURL)
        let dates = journalDates(now: now)
        let previousFiles = journalFiles
        var rootsByFile: [String: Set<String>] = [:]
        journalFiles = journalFiles.filter { dates.contains($0.key) }
        scannedFiles = scannedFiles.filter { dates.contains($0.key) }
        for date in dates {
            let url = HistoryStorage.eventLogURL(for: date, in: directory)
            guard let stat = HistoryStorage.fileStat(at: url) else { throw TokenCacheError.incompleteJournal }
            let previous = journalFiles[date]
            if previous?.size == stat.size, previous?.identifier == stat.identifier,
               previous?.modificationTime == stat.modificationTime, scannedFiles[date] == stat {
                continue
            }
            let offset = previous.flatMap { $0.identifier == stat.identifier && $0.size < stat.size ? $0.size : nil } ?? 0
            var invalid = false
            try AppServerEventJournal.read(at: url, from: offset, onInvalidLine: { invalid = true }, consume: { entry in
                if let root = entry.observation?.turn.rootID ?? entry.token?.rootID {
                    rootsByFile[date, default: []].insert(root)
                }
                try replay.consume(entry, includesSnapshots: true)
            })
            if invalid {
                guard cache != nil else { throw TokenCacheError.incompleteJournal }
                // 日常恢复可沿用已有缓存处理完整记录, 显式重建仍要求原始日志完整
                scannedFiles.removeValue(forKey: date)
                continue
            }
            journalFiles[date] = TokenJournalCheckpoint(size: stat.size, identifier: stat.identifier, modificationTime: stat.modificationTime)
            scannedFiles[date] = stat
        }
        // 回滚失败根轮次在本轮的所有改动, 涉及的文件保留原游标以便下次重试
        for (date, roots) in rootsByFile where !roots.isDisjoint(with: replay.failedRoots) {
            journalFiles[date] = previousFiles[date]
            scannedFiles.removeValue(forKey: date)
        }
        var records = replay.records.filter { !replay.failedRoots.contains($0.value.rootID) }
        for (id, turn) in baseline where replay.failedRoots.contains(turn.rootID) {
            records[id] = turn
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

/// 重放错误以根轮次为边界, 归属不明时不能证明错误与选区无关
private nonisolated struct TokenJournalReplay {
    var records: [String: TokenTurn]
    var failedRoots = Set<String>()
    private var rootByTurn: [String: String] = [:]
    private var startsByRoot: [String: Date] = [:]

    init(baseline: [String: TokenTurn], replayingFromEmpty: Bool = false) throws {
        records = replayingFromEmpty ? [:] : baseline
        for turn in baseline.values {
            try register(turn, rootStartedAt: baseline[turn.rootID]?.startedAt)
        }
    }

    mutating func consume(_ entry: AppServerEventRecord, includesSnapshots: Bool) throws {
        if let observation = entry.observation {
            let turn = observation.turn
            try register(turn, rootStartedAt: observation.rootStartedAt)
            guard !failedRoots.contains(turn.rootID) else { return }
            do {
                records[turn.id] = try observation.applying(to: records[turn.id])
                if turn.id != turn.rootID, records[turn.rootID] == nil {
                    records[turn.rootID] = TokenTurn(
                        id: turn.rootID, rootID: turn.rootID,
                        startedAt: startsByRoot[turn.rootID], updatedAt: turn.updatedAt
                    )
                }
                if records[turn.rootID]?.startedAt == nil {
                    records[turn.rootID]?.startedAt = startsByRoot[turn.rootID]
                }
            } catch {
                failedRoots.insert(turn.rootID)
            }
        } else if let turn = entry.token {
            try register(turn, rootStartedAt: nil)
            if includesSnapshots, !failedRoots.contains(turn.rootID) {
                records[turn.id] = records[turn.id]?.merging(turn) ?? turn
            }
        }
    }

    func selectedRoots(in dates: Set<String>) throws -> [String: String] {
        var result: [String: String] = [:]
        for root in Set(rootByTurn.values) {
            guard let start = startsByRoot[root] else { throw TokenCacheError.incompleteJournal }
            let date = HistoryStorage.dateKey(for: start)
            if dates.contains(date) {
                result[root] = date
            }
        }
        return result
    }

    private mutating func register(_ turn: TokenTurn, rootStartedAt: Date?) throws {
        if let previous = rootByTurn[turn.id], previous != turn.rootID {
            throw TokenCacheError.incompleteJournal
        }
        rootByTurn[turn.id] = turn.rootID
        let start = rootStartedAt ?? (turn.id == turn.rootID ? turn.startedAt : nil)
        if let start {
            if let previous = startsByRoot[turn.rootID],
               HistoryStorage.dateKey(for: previous) != HistoryStorage.dateKey(for: start) {
                throw TokenCacheError.incompleteJournal
            }
            startsByRoot[turn.rootID] = start
        }
    }
}

private nonisolated struct TokenAggregateCache: Codable {
    static let currentVersion = 1
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
    var failedDateKeys: [String] = []
    var turns: [TokenTurn]?
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
