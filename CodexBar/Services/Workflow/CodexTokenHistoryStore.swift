import CryptoKit
import Darwin
import Foundation
import os

/// 历史采集独立于实时任务, 全量补读后按文件游标增量消费
actor CodexTokenHistoryStore {
    private let codexHomeURL: URL
    private let directoryURL: URL
    private let byteBudget: Int
    private let reportProgress: @Sendable (CodexTokenReplayProgress) -> Void
    private var lastReportedProgress: CodexTokenReplayProgress?

    init(
        codexHomeURL: URL = CodexCLIResolver.codexHomeDirectory(),
        directoryURL: URL = WorkflowStorage.directoryURL().appendingPathComponent("Tokens"),
        byteBudget: Int = 64 * 1024 * 1024,
        reportProgress: @escaping @Sendable (CodexTokenReplayProgress) -> Void = { $0.writeLog() }
    ) {
        self.codexHomeURL = codexHomeURL
        self.directoryURL = directoryURL
        self.byteBudget = byteBudget
        self.reportProgress = reportProgress
    }

    func refresh(now: Date = Date(), baseline: CodexTokenHistoryBaseline? = nil) throws -> [CodexTokenTurn] {
        let duration = LogDuration()
        return try CodexTokenFileStorage.withLock(in: directoryURL) {
            let url = directoryURL.appendingPathComponent("ledger.json")
            var ledger = try CodexTokenFileStorage.load(TokenHistoryLedger.self, from: url) ?? TokenHistoryLedger()
            guard ledger.schema == TokenHistoryLedger.currentSchema else { throw CocoaError(.fileReadCorruptFile) }
            var restored = false
            for turn in ledger.turns.values {
                guard let replacement = baseline?.replacement(for: turn) else { continue }
                ledger.restore(replacement)
                restored = true
            }
            // 已扫描的累计值可能混有重建前的旧记录, 重新按记录时间消费而不是给旧值换上新标记
            if restored {
                ledger.files.removeAll()
            }
            let cutoff = WorkflowStorage.retentionCutoffDate(today: now)
            let files = rolloutFiles(since: cutoff).map { (url: $0, key: fileKey($0)) }
            var remaining = byteBudget
            // 每轮先处理上次尚未扫描的文件, 防止大型活跃文件让历史补读饥饿
            let ordered = files.map { file in
                (
                    file: file,
                    lastReadAt: ledger.files[file.key]?.lastReadAt ?? .distantPast,
                    modifiedAt: (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                )
            }.sorted { lhs, rhs in
                if lhs.lastReadAt != rhs.lastReadAt {
                    return lhs.lastReadAt < rhs.lastReadAt
                }
                // 同批未读文件优先补近期数据, 不依赖文件系统枚举顺序
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.file.url.path < rhs.file.url.path
            }.map(\.file)
            var results: [String: TokenHistoryScanResult] = [:]
            for file in ordered where remaining > 0 {
                try Task.checkCancellation()
                results[file.key] = try scan(file.url, key: file.key, ledger: &ledger, remaining: &remaining, now: now, baseline: baseline)
            }
            let roots = Set(ledger.turns.values.filter { $0.updatedAt >= cutoff }.map(\.rootID))
            ledger.turns = ledger.turns.filter { $0.value.updatedAt >= cutoff || roots.contains($0.key) }
            ledger.recoveryCutoffs = ledger.recoveryCutoffs?.filter { ledger.turns[$0.key] != nil }
            let fileKeys = Set(files.map(\.key))
            ledger.files = ledger.files.filter { fileKeys.contains($0.key) }
            try CodexTokenFileStorage.save(ledger, to: url)
            let progress = replayProgress(files: files, ledger: ledger, results: results, batchBytes: byteBudget - remaining, duration: duration)
            publishProgress(progress, restored: restored)
            return Array(ledger.turns.values)
        }
    }

    private func replayProgress(
        files: [(url: URL, key: String)], ledger: TokenHistoryLedger, results: [String: TokenHistoryScanResult], batchBytes: Int, duration: LogDuration
    ) -> CodexTokenReplayProgress {
        var progress = CodexTokenReplayProgress(totalFiles: files.count, batchBytes: batchBytes, elapsed: duration.elapsed)
        for (url, key) in files {
            guard let stat = WorkflowStorage.fileStat(at: url) else {
                progress.unavailableFiles += 1
                continue
            }
            progress.totalBytes += stat.size
            let cursor = ledger.files[key]
            let hasValidCursor = cursor?.inode == stat.identifier && (cursor?.offset ?? 0) <= stat.size
            let offset = hasValidCursor ? cursor?.offset ?? 0 : 0
            progress.processedBytes += offset
            if results[key] == .unavailable {
                progress.unavailableFiles += 1
            } else if results[key] == .waitingForLine || cursor?.droppingLongLine == true && offset == stat.size {
                progress.waitingFiles += 1
            } else if hasValidCursor, offset == stat.size {
                progress.completedFiles += 1
            }
        }
        return progress
    }

    private func publishProgress(_ progress: CodexTokenReplayProgress, restored: Bool) {
        guard progress.totalFiles > 0 || lastReportedProgress != nil else { return }
        if let previous = lastReportedProgress, !restored {
            // 追平后的普通追加不重复记录完成, 停在同一个半行或不可读文件时也不刷屏
            guard !(previous.isComplete && progress.isComplete), !progress.hasSamePosition(as: previous) else { return }
        }
        lastReportedProgress = progress
        reportProgress(progress)
    }

    private func rolloutFiles(since cutoff: Date) -> [URL] {
        var result: [URL] = []
        for name in ["sessions", "archived_sessions"] {
            let root = codexHomeURL.appendingPathComponent(name)
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true, (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                result.append(url)
            }
        }
        return result
    }

    @discardableResult
    private func scan(
        _ url: URL, key: String? = nil, ledger: inout TokenHistoryLedger, remaining: inout Int, now: Date,
        snapshot: WorkflowFileStat? = nil, baseline: CodexTokenHistoryBaseline? = nil
    ) throws -> TokenHistoryScanResult {
        guard let source = try openSource(url, snapshot: snapshot) else { return .unavailable }
        let handle = source.handle
        defer { try? handle.close() }
        let size = snapshot?.size ?? source.stat.size
        let inode = source.stat.identifier
        let key = key ?? fileKey(url)
        var cursor = ledger.files[key] ?? TokenHistoryCursor(inode: inode)
        if cursor.inode != inode || cursor.offset > size {
            cursor = TokenHistoryCursor(inode: inode)
        }
        if let hash = cursor.boundaryHash, try boundaryHash(handle, at: cursor.offset) != hash {
            if snapshot != nil {
                throw CodexTokenRebuildError.sourceChanged
            }
            cursor = TokenHistoryCursor(inode: inode)
        }
        cursor.lastReadAt = now
        guard cursor.offset < size else {
            ledger.files[key] = cursor
            return TokenHistoryScanResult(reachedEnd: true, hasPartialLine: cursor.droppingLongLine)
        }
        try handle.seek(toOffset: cursor.offset)
        var line = Data()
        var dropping = cursor.droppingLongLine
        reading: while cursor.offset < size, remaining > 0 || !line.isEmpty {
            try Task.checkCancellation()
            let count = remaining > 0 ? min(64 * 1024, remaining) : 64 * 1024
            let data = try handle.read(upToCount: min(count, Int(clamping: size - cursor.offset))) ?? Data()
            if data.isEmpty {
                if snapshot != nil {
                    throw CodexTokenRebuildError.sourceChanged
                }
                break
            }
            remaining -= data.count
            var offset = data.startIndex
            while offset < data.endIndex {
                let newline = data[offset...].firstIndex(of: JSONLines.newlineByte)
                let end = newline ?? data.endIndex
                let fragment = data[offset ..< end]
                cursor.offset += UInt64(fragment.count + (newline == nil ? 0 : 1))
                if !dropping {
                    if line.count + fragment.count > 1024 * 1024 {
                        line.removeAll(keepingCapacity: false)
                        dropping = true
                    } else {
                        line.append(contentsOf: fragment)
                    }
                }
                if newline != nil {
                    if !dropping {
                        consume(line, thread: source.thread, session: source.session, ledger: &ledger, baseline: baseline)
                    }
                    line.removeAll(keepingCapacity: true)
                    dropping = false
                    cursor.committedOffset = cursor.offset
                    if remaining <= 0 {
                        break reading
                    }
                    offset = end + 1
                } else {
                    break
                }
            }
        }
        // 半行不提交, 超长正文则跨轮继续跳过, 不将正文写入缓存
        let reachedEnd = cursor.offset >= size
        cursor.droppingLongLine = dropping
        if !dropping {
            cursor.offset = cursor.committedOffset
        }
        cursor.boundaryHash = try boundaryHash(handle, at: cursor.offset)
        ledger.files[key] = cursor
        return TokenHistoryScanResult(reachedEnd: reachedEnd, hasPartialLine: dropping || cursor.offset < size)
    }

    private func openSource(
        _ url: URL, snapshot: WorkflowFileStat?
    ) throws -> TokenHistoryReadSource? {
        guard let stat = WorkflowStorage.fileStat(at: url) else {
            if snapshot != nil {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return nil
        }
        if let snapshot, snapshot.identifier != stat.identifier || stat.size < snapshot.size {
            throw CodexTokenRebuildError.sourceChanged
        }
        guard let metadata = WorkflowRolloutMetadataReader.metadata(transcriptPath: url.path), let thread = metadata.id,
              let handle = try? FileHandle(forReadingFrom: url) else {
            if snapshot != nil {
                throw CocoaError(.fileReadCorruptFile)
            }
            return nil
        }
        return TokenHistoryReadSource(stat: stat, thread: thread, session: metadata.sessionID ?? thread, handle: handle)
    }

    private func boundaryHash(_ handle: FileHandle, at offset: UInt64) throws -> String {
        let count = min(offset, 512)
        try handle.seek(toOffset: offset - count)
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        return CodexTokenTurn.hexString(SHA256.hash(data: data))
    }

    private func consume(
        _ line: Data, thread: String, session: String, ledger: inout TokenHistoryLedger,
        baseline: CodexTokenHistoryBaseline?
    ) {
        guard let envelope = try? JSONDecoder().decode(TokenHistoryLine.self, from: line) else { return }
        if envelope.type == "token_usage_record" {
            guard let payload = try? JSONDecoder().decode(CodexRolloutTokenUsageRecord.self, from: line).payload,
                  payload.threadID == thread, payload.sessionID == session,
                  !payload.turnID.isEmpty, !payload.rootTurnID.isEmpty, !payload.responseID.isEmpty,
                  payload.turnTokenUsage.isValid, let timestamp = envelope.date else { return }
            let id = CodexTokenTurn.identifier(thread: thread, turn: payload.turnID)
            var value = CodexTokenTurn(
                id: id, rootID: CodexTokenTurn.identifier(thread: session, turn: payload.rootTurnID),
                startedAt: ledger.turns[id]?.startedAt, updatedAt: timestamp,
                usage: payload.turnTokenUsage, rebuiltAt: ledger.turns[id]?.rebuiltAt
            )
            if let replacement = baseline?.replacement(for: value) {
                ledger.restore(replacement)
                value.rebuiltAt = replacement.rebuiltAt
            }
            // 恢复后重放旧文件和归档副本时, 不能恢复云端已经修正的旧累计值
            guard timestamp > (ledger.recoveryCutoffs?[id] ?? .distantPast) else { return }
            ledger.turns[id] = ledger.turns[id]?.merging(value) ?? value
        } else if envelope.type == "event_msg", ["task_started", "turn_started"].contains(envelope.payload?.type ?? ""),
                  let turn = envelope.payload?.turnID, !turn.isEmpty,
                  let timestamp = envelope.payload?.startedAt.flatMap(TokenHistoryLine.eventDate) ?? envelope.date {
            let id = CodexTokenTurn.identifier(thread: thread, turn: turn)
            let value = CodexTokenTurn(
                id: id, rootID: id, startedAt: timestamp, updatedAt: timestamp, usage: nil, rebuiltAt: ledger.turns[id]?.rebuiltAt
            )
            if let replacement = baseline?.replacement(for: value) {
                ledger.restore(replacement)
            } else {
                ledger.turns[id] = ledger.turns[id]?.merging(value) ?? value
            }
        }
    }

    private func fileKey(_ url: URL) -> String {
        CodexTokenTurn.hexString(SHA256.hash(data: Data(url.path.utf8)))
    }
}

extension CodexTokenHistoryStore {
    func currentTurns() throws -> [CodexTokenTurn] {
        try CodexTokenFileStorage.withLock(in: directoryURL) {
            try Array(loadLedger().turns.values)
        }
    }

    func rebuildableDateKeys(now: Date = Date()) throws -> [String] {
        try CodexTokenFileStorage.withLock(in: directoryURL) {
            let ledger = try loadLedger()
            let cutoff = WorkflowStorage.retentionCutoffDate(today: now)
            return Set(ledger.turns.values.compactMap { turn -> String? in
                guard let start = ledger.turns[turn.rootID]?.startedAt, start >= cutoff, start <= now else { return nil }
                return CodexDateFormat.dayString(from: start)
            }).sorted()
        }
    }

    /// 只在完整扫描成功后提交, 扫描期间不持有共享账本锁, 旧统计仍可读取
    func rebuild(for dateKeys: [String], now: Date = Date()) async throws -> CodexTokenRebuildResult {
        guard let lock = try CodexTokenFileStorage.acquireLock(in: directoryURL, name: "rebuild.lock", nonblocking: true) else {
            throw CodexTokenRebuildError.alreadyRunning
        }
        defer { CodexTokenFileStorage.releaseLock(lock) }
        let dates = Set(dateKeys.filter {
            WorkflowStorage.isValidDateKey($0) && $0 >= WorkflowStorage.dateKey(for: WorkflowStorage.retentionCutoffDate(today: now))
                && $0 <= WorkflowStorage.dateKey(for: now)
        })
        guard !dates.isEmpty else { return .empty }
        let files = try rolloutFiles(since: WorkflowStorage.retentionCutoffDate(today: now)).map { url in
            guard let stat = WorkflowStorage.fileStat(at: url) else { throw CocoaError(.fileReadNoSuchFile) }
            return (url, stat)
        }
        var rebuilt = TokenHistoryLedger()
        for (url, stat) in files {
            var finished = false
            while !finished {
                try Task.checkCancellation()
                var remaining = max(1, byteBudget)
                finished = try scan(url, ledger: &rebuilt, remaining: &remaining, now: now, snapshot: stat) != .pending
                await Task.yield()
            }
        }
        return try commitRebuild(rebuilt, dates: dates, startedAt: now)
    }

    private func loadLedger() throws -> TokenHistoryLedger {
        let ledger = try CodexTokenFileStorage.load(TokenHistoryLedger.self, from: directoryURL.appendingPathComponent("ledger.json"))
            ?? TokenHistoryLedger()
        guard ledger.schema == TokenHistoryLedger.currentSchema else { throw CocoaError(.fileReadCorruptFile) }
        return ledger
    }

    private func commitRebuild(_ rebuilt: TokenHistoryLedger, dates: Set<String>, startedAt: Date) throws -> CodexTokenRebuildResult {
        try CodexTokenFileStorage.withLock(in: directoryURL) {
            try Task.checkCancellation()
            var ledger = try loadLedger()
            let requiredRoots = Set(rebuilt.turns.values.filter { $0.usage != nil }.map(\.rootID))
            var rebuiltDates: Set<String> = []
            var turnCount = 0
            for var turn in rebuilt.turns.values {
                let previous = ledger.turns[turn.id]
                if turn.usage == nil, let previous {
                    turn.rootID = previous.rootID
                }
                guard let start = rebuilt.turns[turn.rootID]?.startedAt ?? ledger.turns[turn.rootID]?.startedAt,
                      dates.contains(CodexDateFormat.dayString(from: start)) else { continue }
                turn.startedAt = turn.startedAt ?? previous?.startedAt
                // 读取开始之后新产生的累计用量保留, 不用重建的文件快照覆盖活跃任务的新进展
                if var previous, previous.updatedAt > startedAt {
                    previous.rebuiltAt = nil
                    turn = turn.merging(previous)
                }
                if turn.usage != nil || previous?.usage != nil || requiredRoots.contains(turn.id) {
                    turn.rebuiltAt = max(startedAt, previous?.rebuiltAt?.addingTimeInterval(0.001) ?? startedAt)
                }
                ledger.turns[turn.id] = turn
                ledger.recoveryCutoffs?.removeValue(forKey: turn.id)
                rebuiltDates.insert(CodexDateFormat.dayString(from: start))
                if turn.usage != nil {
                    turnCount += 1
                }
            }
            try CodexTokenFileStorage.save(ledger, to: directoryURL.appendingPathComponent("ledger.json"))
            return CodexTokenRebuildResult(dateKeys: rebuiltDates, turnCount: turnCount)
        }
    }
}

nonisolated struct CodexTokenRebuildResult {
    let dateKeys: Set<String>
    let turnCount: Int
    static let empty = Self(dateKeys: [], turnCount: 0)
}

private nonisolated enum CodexTokenRebuildError: LocalizedError {
    case sourceChanged
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .sourceChanged: String(localized: "workflow.rebuild.error.source-changed")
        case .alreadyRunning: String(localized: "workflow.rebuild.error.token-history-already-running")
        }
    }
}

private nonisolated enum TokenHistoryScanResult {
    case pending
    case waitingForLine
    case complete
    case unavailable

    init(reachedEnd: Bool, hasPartialLine: Bool) {
        if !reachedEnd {
            self = .pending
        } else {
            self = hasPartialLine ? .waitingForLine : .complete
        }
    }
}

/// 只记录扫描工作量, 不携带路径 轮次身份或 token 用量
nonisolated struct CodexTokenReplayProgress {
    let totalFiles: Int
    let batchBytes: Int
    let elapsed: String
    var completedFiles = 0
    var unavailableFiles = 0
    var waitingFiles = 0
    var totalBytes: UInt64 = 0
    var processedBytes: UInt64 = 0

    var isComplete: Bool {
        completedFiles == totalFiles
    }

    var remainingBytes: UInt64 {
        totalBytes - min(processedBytes, totalBytes)
    }

    func hasSamePosition(as other: Self) -> Bool {
        totalFiles == other.totalFiles && completedFiles == other.completedFiles
            && unavailableFiles == other.unavailableFiles && waitingFiles == other.waitingFiles
            && totalBytes == other.totalBytes && processedBytes == other.processedBytes
    }

    func writeLog() {
        let fraction = totalBytes == 0 ? 0 : Double(processedBytes) / Double(totalBytes)
        let percent = isComplete ? 100 : min(99.9, fraction * 100)
        let details = LogFields.joined(
            "files=\(completedFiles)/\(totalFiles)",
            "progress=\(String(format: "%.1f%%", percent))",
            "processed=\(Self.formattedBytes(processedBytes))/\(Self.formattedBytes(totalBytes))",
            "remaining=\(Self.formattedBytes(remainingBytes))",
            "read=\(Self.formattedBytes(UInt64(max(0, batchBytes))))",
            "waiting=\(waitingFiles)",
            "unavailable=\(unavailableFiles)",
            "elapsed=\(elapsed)"
        )
        if isComplete {
            AppLog.workflow.notice("Rollout 回放完成: \(details, privacy: .public)")
        } else {
            AppLog.workflow.notice("Rollout 回放进度: \(details, privacy: .public)")
        }
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes)B"
        }
        if bytes < 1024 * 1024 {
            return String(format: "%.2fKiB", Double(bytes) / 1024)
        }
        return String(format: "%.2fMiB", Double(bytes) / (1024 * 1024))
    }
}

private nonisolated struct TokenHistoryReadSource {
    let stat: WorkflowFileStat
    let thread: String
    let session: String
    let handle: FileHandle
}

private nonisolated struct TokenHistoryLedger: Codable {
    static let currentSchema = 1
    var schema = currentSchema
    var turns: [String: CodexTokenTurn] = [:]
    var files: [String: TokenHistoryCursor] = [:]
    var recoveryCutoffs: [String: Date]?

    mutating func restore(_ turn: CodexTokenTurn) {
        turns[turn.id] = turn
        if recoveryCutoffs == nil {
            recoveryCutoffs = [:]
        }
        recoveryCutoffs?[turn.id] = turn.rebuiltAt
    }
}

private nonisolated struct TokenHistoryCursor: Codable {
    let inode: UInt64
    var offset: UInt64 = 0
    var committedOffset: UInt64 = 0
    var droppingLongLine = false
    var lastReadAt = Date.distantPast
    var boundaryHash: String?
}

private nonisolated struct TokenHistoryLine: Decodable {
    let type: String
    let timestamp: String?
    let payload: TokenHistoryEvent?
    var date: Date? {
        timestamp.flatMap(CodexDateFormat.iso8601Date)
    }

    static func eventDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100000000000 ? value / 1000 : value)
    }
}

private nonisolated struct TokenHistoryEvent: Decodable {
    let type: String?
    let turnID: String?
    let startedAt: Double?
    enum CodingKeys: String, CodingKey {
        case type
        case turnID = "turn_id"
        case startedAt = "started_at"
    }
}

/// 独立文件锁避免 Debug 与 Release 互相覆盖, 不占用 Hook recorder 的锁
nonisolated enum CodexTokenFileStorage {
    static func withLock<T>(in directory: URL, _ operation: () throws -> T) throws -> T {
        guard let descriptor = try acquireLock(in: directory) else { throw POSIXError(.EIO) }
        defer { releaseLock(descriptor) }
        return try operation()
    }

    static func acquireLock(in directory: URL, name: String = "store.lock", nonblocking: Bool = false) throws -> Int32? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent(name).path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            let code = errno
            close(descriptor)
            if nonblocking, code == EWOULDBLOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    static func releaseLock(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func load<T: Decodable>(_: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func save(_ value: some Encodable, to url: URL) throws {
        let data = try JSONLines.stableEncoder.encode(value)
        guard (try? Data(contentsOf: url)) != data else { return }
        try data.write(to: url, options: .atomic)
    }
}

/// 调用方持有文件锁, 每次核对磁盘字节后复用解码结果, 不依赖 mtime 判断跨进程修改
nonisolated struct CodexTokenFileCache<Value: Codable & Equatable> {
    let url: URL
    private var data: Data?
    private var value: Value?

    init(url: URL) {
        self.url = url
    }

    mutating func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            data = nil
            value = nil
            return nil
        }
        let current = try Data(contentsOf: url)
        if current == data {
            return value
        }
        let decoded = try JSONDecoder().decode(Value.self, from: current)
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
