import CloudKit
import CryptoKit
import Foundation
import Synchronization
import Testing

struct CodexTokenHistoryTests {
    @Test func unchangedTokenStorageDoesNotReplaceFile() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.json")
        let values = [turn("main", "a", input: 100)]
        try CodexTokenFileStorage.save(values, to: url)
        let before = try #require(WorkflowStorage.fileStat(at: url))
        try CodexTokenFileStorage.save(values, to: url)
        let after = try #require(WorkflowStorage.fileStat(at: url))
        #expect(after.identifier == before.identifier)
        #expect(after.modifiedAtNanoseconds == before.modifiedAtNanoseconds)
        #expect(try CodexTokenFileStorage.load([CodexTokenTurn].self, from: url) == values)
    }

    @Test func tokenIdentitiesMatchExistingEncodingExactly() throws {
        let bytes = Data((0 ... 255).map(UInt8.init))
        #expect(CodexTokenTurn.hexString(bytes) == bytes.map { String(format: "%02x", $0) }.joined())
        #expect(CodexTokenTurn.hexString(Data()).isEmpty)
        let salt = Data((0 ... 255).map(UInt8.init))
        for thread in ["", "thread", "中文/路径", "a\u{0000}b", String(repeating: "x", count: 1024)] {
            let data = try JSONEncoder().encode(["token-turn-v1", thread, "turn"])
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(CodexTokenTurn.identifier(thread: thread, turn: "turn") == expected)
            for root in [expected, "other-root"] {
                let value = CodexTokenTurn(id: expected, rootID: root, updatedAt: TestFixtures.now)
                let exported = value.pseudonymized(salt: salt)
                func legacyHash(_ text: String) -> String {
                    HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: salt))
                        .map { String(format: "%02x", $0) }.joined()
                }
                #expect(exported.id == legacyHash(expected))
                #expect(exported.rootID == legacyHash(root))
                #expect(exported.updatedAt == value.updatedAt)
            }
        }
    }

    @Test func batchPseudonymsPreserveUpdatedValuesAndAccountIsolation() {
        let root = turn("main", "a", input: 100)
        let child = turn("child", "b", root: root.id, input: 200)
        var updated = child
        updated.usage = usage(input: 50)
        updated.rebuiltAt = TestFixtures.now.addingTimeInterval(60)
        let records = [root, child, updated]
        for salt in [Data("account-a".utf8), Data("account-b".utf8), Data()] {
            #expect(CodexTokenTurn.pseudonymized(records, salt: salt) == records.map { $0.pseudonymized(salt: salt) })
        }
    }

    @Test func cachedTokenFileChecksBytesAcrossExternalWritesAndDeletion() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.json")
        var first = CodexTokenFileCache<[String: Int]>(url: url)
        var second = CodexTokenFileCache<[String: Int]>(url: url)
        try first.save(["cursor": 1])
        #expect(try first.load() == ["cursor": 1])
        #expect(try second.load() == ["cursor": 1])
        let initial = try #require(WorkflowStorage.fileStat(at: url))
        try first.save(["cursor": 1])
        #expect(WorkflowStorage.fileStat(at: url)?.identifier == initial.identifier)
        let modifiedAt = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        try Data("{\"cursor\":2}".utf8).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        #expect(WorkflowStorage.fileStat(at: url)?.size == initial.size)
        #expect(try first.load() == ["cursor": 2])
        #expect(try second.load() == ["cursor": 2])
        try second.save(["cursor": 3])
        #expect(try first.load() == ["cursor": 3])
        // 内存命中不能跳过另一进程修改后的保存检查点
        try second.save(["cursor": 4])
        try first.save(["cursor": 3])
        #expect(try second.load() == ["cursor": 3])
        try Data("invalid".utf8).write(to: url)
        #expect(throws: (any Error).self) { try first.load() }
        try FileManager.default.removeItem(at: url)
        #expect(try first.load() == nil)
        try first.save(["cursor": 3])
        #expect(try second.load() == ["cursor": 3])
    }

    @Test func idleRefreshPreservesResultsAndPersistedScanScheduling() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let source = try directory.write(lines(input: 100), to: "sessions/rollout-main.jsonl")
        let store = makeStore(directory)
        let original = try await store.refresh(now: TestFixtures.now)
        let later = TestFixtures.now.addingTimeInterval(60)
        #expect(try await store.refresh(now: later) == original)
        let ledgerURL = directory.url.appendingPathComponent("history/ledger.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
        let cursors = try #require(json["files"] as? [String: [String: Any]])
        let cursor = try #require(cursors.values.first)
        #expect(cursor["lastReadAt"] as? Double == later.timeIntervalSinceReferenceDate)
        let sourceSize = try Data(contentsOf: source).count
        #expect(cursor["offset"] as? Int == sourceSize)
        #expect(try await makeStore(directory).refresh(now: later) == original)
    }

    @Test func replayProgressReportsBackfillAndCompletionWithoutIdleOrIncrementalSpam() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let records = (1 ... 20).map { record(input: $0 * 100) + "\n" }.joined()
        let file = try directory.write(metadata() + "\n" + start() + "\n" + records, to: "sessions/rollout-main.jsonl")
        let reports = Mutex<[CodexTokenReplayProgress]>([])
        let store = CodexTokenHistoryStore(
            codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 256,
            reportProgress: { progress in reports.withLock { $0.append(progress) } }
        )
        for _ in 0 ..< 30 {
            _ = try await store.refresh(now: TestFixtures.now)
        }
        let progress = reports.withLock { $0 }
        #expect(progress.count > 1)
        #expect(progress.first?.isComplete == false)
        #expect(progress.first?.remainingBytes ?? 0 > 0)
        #expect(progress.allSatisfy { $0.totalFiles == 1 && $0.unavailableFiles == 0 })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.processedBytes < $1.processedBytes })
        let completed = try #require(progress.last)
        #expect(completed.isComplete)
        #expect(completed.remainingBytes == 0)
        #expect(try completed.processedBytes == UInt64(Data(contentsOf: file).count))
        let count = progress.count
        try append(record(input: 3000) + "\n", to: file)
        _ = try await store.refresh(now: TestFixtures.now)
        #expect(reports.withLock { $0.count } == count)
        #expect(try await daily(store)[day]?.totalTokens == 3010)
    }

    @Test func replayProgressDoesNotCallPartialOrUnreadableFilesComplete() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let file = try directory.write(lines(input: 100) + record(input: 200), to: "sessions/rollout-main.jsonl")
        let broken = try directory.write("invalid metadata\n", to: "sessions/rollout-broken.jsonl")
        let reports = Mutex<[CodexTokenReplayProgress]>([])
        let store = CodexTokenHistoryStore(
            codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"),
            reportProgress: { progress in reports.withLock { $0.append(progress) } }
        )
        _ = try await store.refresh(now: TestFixtures.now)
        let first = try #require(reports.withLock { $0.last })
        #expect(!first.isComplete)
        #expect(first.waitingFiles == 1)
        #expect(first.unavailableFiles == 1)
        #expect(first.completedFiles == 0)
        _ = try await store.refresh(now: TestFixtures.now)
        #expect(reports.withLock { $0.count } == 1)
        try append("\n", to: file)
        _ = try await store.refresh(now: TestFixtures.now)
        let partial = try #require(reports.withLock { $0.last })
        #expect(!partial.isComplete)
        #expect(partial.completedFiles == 1)
        #expect(partial.waitingFiles == 0)
        try FileManager.default.removeItem(at: broken)
        _ = try await store.refresh(now: TestFixtures.now)
        #expect(reports.withLock { $0.last?.isComplete } == true)
    }

    @Test func replayProgressResumesPersistedOffsetsAndReportsReplacement() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let file = try directory.write(lines(input: 100), to: "sessions/rollout-main.jsonl")
        let reports = Mutex<[CodexTokenReplayProgress]>([])
        let first = CodexTokenHistoryStore(
            codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 256,
            reportProgress: { progress in reports.withLock { $0.append(progress) } }
        )
        _ = try await first.refresh(now: TestFixtures.now)
        let initial = try #require(reports.withLock { $0.last })
        let restarted = CodexTokenHistoryStore(
            codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"),
            reportProgress: { progress in reports.withLock { $0.append(progress) } }
        )
        _ = try await restarted.refresh(now: TestFixtures.now)
        let completed = try #require(reports.withLock { $0.last })
        #expect(completed.isComplete)
        #expect(completed.processedBytes > initial.processedBytes)
        #expect(UInt64(completed.batchBytes) < completed.totalBytes)
        try Data((metadata() + "\n" + start() + "\n" + record(input: 200)).utf8).write(to: file, options: .atomic)
        _ = try await restarted.refresh(now: TestFixtures.now)
        #expect(reports.withLock { $0.last?.waitingFiles } == 1)
        #expect(reports.withLock { $0.last?.isComplete } == false)
        try append("\n", to: file)
        _ = try await restarted.refresh(now: TestFixtures.now)
        #expect(reports.withLock { $0.last?.isComplete } == true)
    }

    @Test func rebuildReplacesOnlySelectedLocalTurnsAndKeepsIncrementalReading() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let source = try directory.write(lines(input: 500), to: "sessions/rollout-main.jsonl")
        let otherDay = TestFixtures.now.addingTimeInterval(-86400)
        let other = lines(input: 200).replacingOccurrences(of: "thread-main", with: "thread-other")
            .replacingOccurrences(of: String(TestFixtures.now.timeIntervalSince1970), with: String(otherDay.timeIntervalSince1970))
        let otherFile = try directory.write(other, to: "sessions/rollout-other.jsonl")
        let store = makeStore(directory)
        let initial = try await store.refresh(now: TestFixtures.now.addingTimeInterval(60))
        let otherID = CodexTokenTurn.identifier(thread: "thread-other", turn: "turn-main")
        let previousOther = try #require(initial.first { $0.id == otherID })
        try Data(lines(input: 100).utf8).write(to: source, options: .atomic)
        let changedOther = lines(input: 400).replacingOccurrences(of: "thread-main", with: "thread-other")
            .replacingOccurrences(of: String(TestFixtures.now.timeIntervalSince1970), with: String(otherDay.timeIntervalSince1970))
        try Data(changedOther.utf8).write(to: otherFile, options: .atomic)
        _ = try directory.write(lines(input: 100), to: "archived_sessions/rollout-copy.jsonl")
        let result = try await store.rebuild(for: [day], now: TestFixtures.now.addingTimeInterval(120))
        #expect(result.dateKeys == [day])
        #expect(result.turnCount == 1)
        let current = try await store.currentTurns()
        #expect(current.first { $0.id == otherID } == previousOther)
        #expect(CodexTokenTurn.dailyUsage(current, now: TestFixtures.now.addingTimeInterval(180))[day]?.totalTokens == 110)
        #expect(CodexTokenTurn.dailyUsage(current + initial, now: TestFixtures.now.addingTimeInterval(180))[day]?.totalTokens == 110)
        try append(record(input: 300) + "\n", to: source)
        #expect(try await daily(makeStore(directory))[day]?.totalTokens == 310)
    }

    @Test func rebuildWithMissingRolloutsPreservesKnownTurns() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let source = try directory.write(lines(input: 500), to: "sessions/rollout-main.jsonl")
        let store = makeStore(directory)
        let before = try await store.refresh(now: TestFixtures.now)
        try FileManager.default.removeItem(at: source)
        let result = try await store.rebuild(for: [day], now: TestFixtures.now)
        #expect(result.dateKeys.isEmpty)
        #expect(try await store.currentTurns() == before)
    }

    @Test func rebuildCanClearPreviouslyCountedUsageAndExcludesConcurrentRebuilds() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let source = try directory.write(lines(input: 500), to: "sessions/rollout-main.jsonl")
        let store = makeStore(directory)
        let before = try await store.refresh(now: TestFixtures.now)
        let lock = try #require(try CodexTokenFileStorage.acquireLock(in: directory.url.appendingPathComponent("history"), name: "rebuild.lock"))
        await #expect(throws: (any Error).self) { try await store.rebuild(for: [day], now: TestFixtures.now) }
        CodexTokenFileStorage.releaseLock(lock)
        #expect(try await store.currentTurns() == before)
        try Data((metadata() + "\n" + start() + "\n").utf8).write(to: source, options: .atomic)
        _ = try await store.rebuild(for: [day], now: TestFixtures.now.addingTimeInterval(60))
        let current = try await store.currentTurns()
        #expect(current.count == 1)
        #expect(current.first?.usage == nil)
        #expect(current.first?.rebuiltAt != nil)
        #expect(CodexTokenTurn.dailyUsage(current + before, now: TestFixtures.now.addingTimeInterval(60)).isEmpty)
    }

    @Test func incompleteOrCancelledRebuildDoesNotPublishPartialResults() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let source = try directory.write(lines(input: 500), to: "sessions/rollout-main.jsonl")
        let store = makeStore(directory)
        let before = try await store.refresh(now: TestFixtures.now)
        try Data(lines(input: 100).utf8).write(to: source, options: .atomic)
        let cancelled = Task { try await store.rebuild(for: [day], now: TestFixtures.now) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.currentTurns() == before)
        _ = try directory.write("broken metadata\n", to: "sessions/rollout-broken.jsonl")
        await #expect(throws: (any Error).self) { try await store.rebuild(for: [day], now: TestFixtures.now) }
        #expect(try await store.currentTurns() == before)
    }

    @Test func rebuildReadsAllBatchesButLeavesPartialTailForIncrementalRefresh() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let body = "{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 2 * 1024 * 1024) + "\"}\n"
        let source = try directory.write(lines(input: 100) + body + record(input: 300), to: "sessions/rollout-main.jsonl")
        let store = CodexTokenHistoryStore(codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 4096)
        let result = try await store.rebuild(for: [day], now: TestFixtures.now.addingTimeInterval(60))
        #expect(result.turnCount == 1)
        let current = try await store.currentTurns()
        #expect(CodexTokenTurn.dailyUsage(current, now: TestFixtures.now.addingTimeInterval(60))[day]?.totalTokens == 110)
        try append("\n", to: source)
        #expect(try await daily(makeStore(directory))[day]?.totalTokens == 310)
    }

    @Test func rebuildGroupsCrossMidnightChildUsageUnderRootStartDay() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let rootStart = try #require(CodexDateFormat.dayDate(from: day)).addingTimeInterval(-10)
        let rootDay = CodexDateFormat.dayString(from: rootStart)
        let main = lines(input: 100).replacingOccurrences(
            of: String(TestFixtures.now.timeIntervalSince1970), with: String(rootStart.timeIntervalSince1970)
        )
        _ = try directory.write(main, to: "sessions/rollout-main.jsonl")
        let child = metadata(thread: "thread-child") + "\n" + start(turn: "turn-child") + "\n"
            + record(input: 300, thread: "thread-child", turn: "turn-child") + "\n"
        _ = try directory.write(child, to: "sessions/rollout-child.jsonl")
        let store = makeStore(directory)
        let result = try await store.rebuild(for: [rootDay], now: TestFixtures.now.addingTimeInterval(60))
        #expect(result.turnCount == 2)
        #expect(result.dateKeys == [rootDay])
        let current = try await store.currentTurns()
        #expect(CodexTokenTurn.dailyUsage(current, now: TestFixtures.now.addingTimeInterval(60))[rootDay]?.totalTokens == 420)
    }

    @Test func cloudRebuildMarkerOverridesStaleTotalsAndCanClearUsage() {
        let stale = turn("main", "a", input: 500)
        var rebuilt = turn("main", "a", input: 100)
        rebuilt.rebuiltAt = TestFixtures.now
        #expect(stale.merging(rebuilt) == rebuilt)
        #expect(rebuilt.merging(stale) == rebuilt)
        let exported = rebuilt.pseudonymized(salt: Data("account".utf8))
        let record = CKRecord(recordType: CodexTokenHistorySync.recordType, recordID: .init(recordName: exported.id))
        CodexTokenHistorySync.apply(exported, to: record)
        #expect(CodexTokenHistorySync.turn(from: record) == exported)
        var cleared = exported
        cleared.usage = nil
        cleared.rebuiltAt = TestFixtures.now.addingTimeInterval(1)
        CodexTokenHistorySync.apply(cleared, to: record)
        #expect(CodexTokenHistorySync.turn(from: record) == cleared)
        #expect(exported.merging(cleared).usage == nil)
        #expect(CodexTokenTurn.syncable([cleared]) == [cleared])
    }

    @Test(arguments: [false, true])
    func cloudBaselineRecoveryReplaysNewUsageWithoutRevivingOldTotals(scanBeforeRecovery: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let source = try directory.write(lines(input: 100), to: "sessions/rollout-main.jsonl")
        let store = makeStore(directory)
        let rebuiltAt = TestFixtures.now.addingTimeInterval(60)
        _ = try await store.rebuild(for: [day], now: rebuiltAt)
        let corrected = try #require(try await store.currentTurns().first)
        let salt = Data("test-account".utf8)
        let remote = corrected.pseudonymized(salt: salt)
        let unrelated = turn("other-device", "other-turn", input: 900).pseudonymized(salt: salt)
        let baseline = CodexTokenHistoryBaseline(salt: salt, turns: [remote.id: remote, unrelated.id: unrelated])
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("history"))
        // 同一文件混有旧的大数值和重建后的新记录, 聚合时间较新不能证明聚合值也较新
        let newRecord = record(input: 200).replacingOccurrences(
            of: "2026-09-15T08:00:10Z", with: rebuiltAt.addingTimeInterval(20).ISO8601Format()
        )
        try Data((lines(input: 500) + newRecord + "\n").utf8).write(to: source)
        if scanBeforeRecovery {
            #expect(try await daily(makeStore(directory))[day]?.totalTokens == 510)
        }
        let restored = try await makeStore(directory).refresh(now: rebuiltAt.addingTimeInterval(30), baseline: baseline)
        let recovered = try #require(restored.first)
        #expect(restored.count == 1)
        #expect(recovered.rebuiltAt == corrected.rebuiltAt)
        #expect(recovered.usage?.totalTokens == 210)
        #expect(remote.merging(recovered.pseudonymized(salt: salt)).usage?.totalTokens == 210)
        // 新进程且本轮云端不可用, 仍然记住恢复边界, 归档旧副本不能重新抬高统计
        _ = try directory.write(lines(input: 700), to: "archived_sessions/rollout-old.jsonl")
        #expect(try await daily(makeStore(directory))[day]?.totalTokens == 210)
        let nextRecord = record(input: 300).replacingOccurrences(
            of: "2026-09-15T08:00:10Z", with: rebuiltAt.addingTimeInterval(40).ISO8601Format()
        )
        try append(nextRecord + "\n", to: source)
        #expect(try await daily(makeStore(directory))[day]?.totalTokens == 310)
    }

    @Test func recoveredClearUsageAndSmallBudgetSurviveRestarts() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let body = "{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 8192) + "\"}\n"
        let file = try directory.write(lines(input: 500) + body, to: "sessions/rollout-main.jsonl")
        let original = try #require(try await makeStore(directory).refresh(now: TestFixtures.now).first)
        var cleared = original
        cleared.usage = nil
        cleared.rebuiltAt = TestFixtures.now.addingTimeInterval(60)
        let salt = Data("account".utf8)
        let cloud = cleared.pseudonymized(salt: salt)
        let baseline = CodexTokenHistoryBaseline(salt: salt, turns: [cloud.id: cloud])
        let record = record(input: 200).replacingOccurrences(
            of: "2026-09-15T08:00:10Z", with: TestFixtures.now.addingTimeInterval(80).ISO8601Format()
        )
        try append(record + "\n", to: file)
        var turns: [CodexTokenTurn] = []
        for iteration in 0 ..< 12 {
            let store = CodexTokenHistoryStore(
                codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 1024
            )
            turns = try await store.refresh(now: TestFixtures.now.addingTimeInterval(90), baseline: baseline)
            if iteration == 0 {
                #expect(turns.first?.usage == nil)
            }
        }
        #expect(turns.first?.usage?.totalTokens == 210)
        #expect(turns.first?.rebuiltAt == cleared.rebuiltAt)
        // 较早的云端基线不能覆盖后续手动重建
        try Data(lines(input: 100).utf8).write(to: file, options: .atomic)
        _ = try await makeStore(directory).rebuild(for: [day], now: TestFixtures.now.addingTimeInterval(120))
        let rebuilt = try await makeStore(directory).refresh(now: TestFixtures.now.addingTimeInterval(130), baseline: baseline)
        #expect(rebuilt.first?.usage?.totalTokens == 110)
    }

    @Test func recoveryKeepsChildUsageUnderRootDayWithoutImportingRemoteOnlyTurns() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try directory.write(lines(input: 100), to: "sessions/rollout-main.jsonl")
        let child = metadata(thread: "thread-child") + "\n" + start(turn: "turn-child") + "\n"
            + record(input: 200, thread: "thread-child", turn: "turn-child") + "\n"
        let childFile = try directory.write(child, to: "sessions/rollout-child.jsonl")
        let store = makeStore(directory)
        _ = try await store.rebuild(for: [day], now: TestFixtures.now.addingTimeInterval(60))
        let salt = Data("account".utf8)
        let remote = try await store.currentTurns().map { $0.pseudonymized(salt: salt) }
        let baseline = CodexTokenHistoryBaseline(salt: salt, turns: CodexTokenTurn.merged(remote))
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("history"))
        let updated = record(input: 300, thread: "thread-child", turn: "turn-child").replacingOccurrences(
            of: "2026-09-15T08:00:10Z", with: TestFixtures.now.addingTimeInterval(80).ISO8601Format()
        )
        try append(updated + "\n", to: childFile)
        let turns = try await makeStore(directory).refresh(now: TestFixtures.now.addingTimeInterval(90), baseline: baseline)
        #expect(turns.count == 2)
        #expect(CodexTokenTurn.dailyUsage(turns, now: TestFixtures.now.addingTimeInterval(90))[day]?.totalTokens == 420)
        let childID = CodexTokenTurn.identifier(thread: "thread-child", turn: "turn-child")
        #expect(turns.first { $0.id == childID }?.startedAt == TestFixtures.now)
        #expect(turns.first { $0.id == childID }?.rootID == CodexTokenTurn.identifier(thread: "thread-main", turn: "turn-main"))
    }

    @Test func cloudRecoveryMatchesAccountSaltAndRootIdentity() {
        let local = turn("child", "b", root: CodexTokenTurn.identifier(thread: "main", turn: "a"), input: 100)
        var remote = local.pseudonymized(salt: Data("account-a".utf8))
        remote.rebuiltAt = TestFixtures.now
        #expect(CodexTokenHistoryBaseline(salt: Data("account-b".utf8), turns: [remote.id: remote]).replacement(for: local) == nil)
        let baseline = CodexTokenHistoryBaseline(salt: Data("account-a".utf8), turns: [remote.id: remote])
        #expect(baseline.replacement(for: local)?.rootID == local.rootID)
        var unknownRoot = local
        unknownRoot.rootID = local.id
        #expect(baseline.replacement(for: unknownRoot) == nil)
    }

    @Test func sharedSyncLockExcludesConcurrentWritersWithoutBlockingCacheReads() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = try #require(try CodexTokenFileStorage.acquireLock(in: directory.url, name: "sync.lock", nonblocking: true))
        let competing = try CodexTokenFileStorage.acquireLock(in: directory.url, name: "sync.lock", nonblocking: true)
        #expect(competing == nil)
        if let competing {
            CodexTokenFileStorage.releaseLock(competing)
        }
        try CodexTokenFileStorage.withLock(in: directory.url) {}
        CodexTokenFileStorage.releaseLock(first)
        let next = try #require(try CodexTokenFileStorage.acquireLock(in: directory.url, name: "sync.lock", nonblocking: true))
        CodexTokenFileStorage.releaseLock(next)
    }

    @Test func freshHistoryReadsRecentFilesBeforeOlderBackfill() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        for index in 0 ..< 20 {
            _ = try directory.write(lines(input: 100), to: "sessions/rollout-\(index).jsonl")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory.url.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        let recent = try #require(files.last)
        for file in files {
            try FileManager.default.setAttributes([.modificationDate: TestFixtures.now.addingTimeInterval(-86400)], ofItemAtPath: file.path)
        }
        try Data(lines(input: 10000).utf8).write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: TestFixtures.now], ofItemAtPath: recent.path)
        let store = CodexTokenHistoryStore(codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 2048)
        #expect(try await daily(store)[day]?.totalTokens == 10010)
    }

    @Test func cumulativeSnapshotsAndMultipleDevicesCountEachThreadTurnOnce() {
        let root = turn("main", "a", input: 100)
        var updated = turn("main", "a", input: 200)
        updated.updatedAt = TestFixtures.now.addingTimeInterval(10)
        let child = turn("child", "b", root: root.id, input: 300)
        let result = CodexTokenTurn.dailyUsage([root, updated, root, child, child], now: TestFixtures.now.addingTimeInterval(60))
        #expect(result[day]?.totalTokens == 520)
        #expect(CodexTokenTurn.merged([updated, root])[root.id] == CodexTokenTurn.merged([root, updated])[root.id])
    }

    @Test func allChildrenIncludingLaterTurnsBelongToRootStartDate() throws {
        let start = try #require(CodexDateFormat.dayDate(from: "2026-09-15")?.addingTimeInterval(86390))
        var root = turn("main", "a", input: 100)
        root.startedAt = start
        root.updatedAt = start.addingTimeInterval(30)
        var child = turn("child", "b", root: root.id, input: 200)
        child.startedAt = start.addingTimeInterval(20)
        child.updatedAt = start.addingTimeInterval(80)
        var followup = turn("child", "c", root: root.id, input: 300)
        followup.startedAt = start.addingTimeInterval(40)
        followup.updatedAt = start.addingTimeInterval(90)
        let days = CodexTokenTurn.dailyUsage([root, child, followup], now: start.addingTimeInterval(100))
        #expect(days.count == 1)
        #expect(days["2026-09-15"]?.totalTokens == 630)
        #expect(CodexTokenTurn.dailyUsage([child], now: start.addingTimeInterval(100)).isEmpty)
    }

    @Test func cacheRateUsesDailyTotalsAndMissingUsageDoesNotBecomeZero() {
        var a = turn("main", "a", input: 100)
        var b = turn("other", "a", input: 300)
        a.usage = usage(input: 100, cached: 80)
        b.usage = usage(input: 300, cached: 30)
        let merged = CodexTokenTurn.dailyUsage([a, b], now: TestFixtures.now)
        #expect(merged[day]?.cacheHitRate == 0.275)
        a.usage = nil
        #expect(CodexTokenTurn.dailyUsage([a], now: TestFixtures.now).isEmpty)
        a.usage = CodexTokenUsage(inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)
        #expect(CodexTokenTurn.dailyUsage([a], now: TestFixtures.now)[day]?.totalTokens == 0)
    }

    @Test func cloudCodecUsesAccountScopedHashesAndRetainsAllCounters() throws {
        let source = turn("private-thread", "private-turn", input: 100)
        let exported = source.pseudonymized(salt: Data("account-a".utf8))
        #expect(exported.id == exported.rootID)
        #expect(exported.id != source.id)
        #expect(exported.id != source.pseudonymized(salt: Data("account-b".utf8)).id)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let id = CodexTokenHistorySync.recordID(exported.id, zoneID: zone)
        #expect(id.recordName == exported.id)
        let record = CKRecord(recordType: CodexTokenHistorySync.recordType, recordID: id)
        CodexTokenHistorySync.apply(exported, to: record)
        #expect(CodexTokenHistorySync.turn(from: record) == exported)
        #expect(record.allKeys().sorted() == ["observedAt", "rootID", "schemaVersion", "startedAt", "usage"])
        let text = try #require(String(data: JSONEncoder().encode(exported), encoding: .utf8))
        #expect(!text.contains("private-thread"))
        #expect(!text.contains("private-turn"))
        record["schemaVersion"] = 99 as CKRecordValue
        #expect(record.recordID == CodexTokenHistorySync.recordID(exported.id, zoneID: zone))
        #expect(CodexTokenHistorySync.turn(from: record) == nil)
    }

    @Test func incrementalReadRestartAndArchivedCopiesDoNotDuplicateUsage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let file = try directory.write(lines(input: 100), to: "sessions/2026/09/15/rollout-main.jsonl")
        let store = makeStore(directory)
        #expect(try await daily(store)[day]?.totalTokens == 110)
        try append(record(input: 200), to: file)
        #expect(try await daily(store)[day]?.totalTokens == 110)
        try append("\n", to: file)
        #expect(try await daily(store)[day]?.totalTokens == 210)
        let restarted = makeStore(directory)
        _ = try directory.write(Data(contentsOf: file), to: "archived_sessions/rollout-copy.jsonl")
        #expect(try await daily(restarted)[day]?.totalTokens == 210)
        let ledger = try String(contentsOf: directory.url.appendingPathComponent("history/ledger.json"), encoding: .utf8)
        #expect(!ledger.contains("thread-main"))
        #expect(!ledger.contains("turn-main"))
        #expect(!ledger.contains("PRIVATE_BODY"))
    }

    @Test func childInheritedHistoryIsIgnoredAndNewUsageIsIncludedOnce() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try directory.write(lines(input: 100), to: "sessions/rollout-main.jsonl")
        let child = metadata(thread: "thread-child", session: "thread-main") + "\n" + lines(input: 100)
            + start(turn: "turn-child") + "\n" + record(input: 300, thread: "thread-child", turn: "turn-child") + "\n"
        _ = try directory.write(child, to: "sessions/rollout-child.jsonl")
        #expect(try await daily(makeStore(directory))[day]?.totalTokens == 420)
    }

    @Test func truncationAndReplacementPreserveKnownConsumptionWithoutDoubleCounting() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let file = try directory.write(lines(input: 100), to: "sessions/rollout-main.jsonl")
        let store = makeStore(directory)
        #expect(try await daily(store)[day]?.totalTokens == 110)
        try Data(lines(input: 300).utf8).write(to: file)
        #expect(try await daily(store)[day]?.totalTokens == 310)
        try Data(lines(input: 100).utf8).write(to: file, options: .atomic)
        #expect(try await daily(store)[day]?.totalTokens == 310)
    }

    @Test func boundedReadsCrossOversizedBodyAndNeverLoseFollowingUsage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let body = "{\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 3 * 1024 * 1024) + "\"}}\n"
        _ = try directory.write(lines(input: 100) + body + record(input: 300) + "\n", to: "sessions/rollout-main.jsonl")
        let store = CodexTokenHistoryStore(codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 256 * 1024)
        var result: [String: CodexTokenUsage] = [:]
        for _ in 0 ..< 15 {
            result = try await daily(store)
        }
        #expect(result[day]?.totalTokens == 310)
    }

    @Test func malformedUsageAndLegacySnapshotsCannotInventCounts() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let invalid = record(input: 100).replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":-1")
        let legacy = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n"
        _ = try directory.write(metadata() + "\n" + start() + "\n" + invalid + "\n" + legacy, to: "sessions/rollout-main.jsonl")
        #expect(try await daily(makeStore(directory)).isEmpty)
    }

    @Test func smallReadBudgetStopsAtOneLineAndEventuallyCatchesUp() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let records = (1 ... 100).map { record(input: $0 * 100) + "\n" }.joined()
        _ = try directory.write(metadata() + "\n" + start() + "\n" + records, to: "sessions/rollout-main.jsonl")
        let store = CodexTokenHistoryStore(codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"), byteBudget: 256)
        let initial = try await daily(store)
        #expect((initial[day]?.totalTokens ?? 0) < 10010)
        var result = initial
        for _ in 0 ..< 110 {
            result = try await daily(store)
        }
        #expect(result[day]?.totalTokens == 10010)
    }

    @Test func childUsageWaitsForRootStartAndNeedsNoRootUsageRecord() {
        var root = turn("main", "a", input: 100)
        root.usage = nil
        let child = turn("child", "b", root: root.id, input: 200)
        #expect(CodexTokenTurn.dailyUsage([child], now: TestFixtures.now).isEmpty)
        #expect(CodexTokenTurn.dailyUsage([root, child], now: TestFixtures.now)[day]?.totalTokens == 210)
        #expect(Set(CodexTokenTurn.syncable([root, child]).map(\.id)) == [root.id, child.id])
    }

    @Test func dailyOverflowIsUnavailableAndExpiredTurnsAreExcluded() {
        var root = turn("main", "a", input: 100)
        root.usage = CodexTokenUsage(
            inputTokens: .max, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: .max
        )
        let child = turn("child", "b", root: root.id, input: 200)
        #expect(CodexTokenTurn.dailyUsage([root, child], now: TestFixtures.now).isEmpty)
        root.startedAt = TestFixtures.now.addingTimeInterval(-220 * 86400)
        #expect(CodexTokenTurn.dailyUsage([root], now: TestFixtures.now).isEmpty)
    }

    @Test func heatmapSeparatesAccountIntensityFromRolloutDailyMetrics() throws {
        var workflow = WorkflowSnapshot.empty
        workflow.tokenUsageByDate = [day: usage(input: 100)]
        let grid = UsageHeatmapDay.grid(usage: nil, workflow: workflow, showsWorkflow: true, columnCount: 2, today: TestFixtures.now)
        let today = try #require(grid.compactMap(\.self).first { $0.startDate == day })
        #expect(today.tokenState == .unavailable)
        #expect(today.tokenUsage?.totalTokens == 110)
        #expect(today.workflow.turnCount == 0)
    }

    private var day: String {
        CodexDateFormat.dayString(from: TestFixtures.now)
    }

    private func usage(input: Int64, cached: Int64 = 20) -> CodexTokenUsage {
        CodexTokenUsage(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 5, outputTokens: 10, reasoningOutputTokens: 2, totalTokens: input + 10)
    }

    private func turn(_ thread: String, _ turn: String, root: String? = nil, input: Int64) -> CodexTokenTurn {
        let id = CodexTokenTurn.identifier(thread: thread, turn: turn)
        return CodexTokenTurn(id: id, rootID: root ?? id, startedAt: TestFixtures.now, updatedAt: TestFixtures.now, usage: usage(input: input))
    }

    private func makeStore(_ directory: TestDirectory) -> CodexTokenHistoryStore {
        CodexTokenHistoryStore(codexHomeURL: directory.url, directoryURL: directory.url.appendingPathComponent("history"))
    }

    private func daily(_ store: CodexTokenHistoryStore) async throws -> [String: CodexTokenUsage] {
        try await CodexTokenTurn.dailyUsage(store.refresh(now: TestFixtures.now.addingTimeInterval(60)), now: TestFixtures.now.addingTimeInterval(60))
    }

    private func metadata(thread: String = "thread-main", session: String = "thread-main") -> String {
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\",\"session_id\":\"\(session)\",\"source\":\"cli\"}}"
    }

    private func start(turn: String = "turn-main") -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(turn)\",\"started_at\":\(TestFixtures.now.timeIntervalSince1970)}}"
    }

    private func record(input: Int, thread: String = "thread-main", turn: String = "turn-main") -> String {
        """
        {"timestamp":"2026-09-15T08:00:10Z","type":"token_usage_record","payload":{"thread_id":"\(thread)","session_id":"thread-main",\
        "turn_id":"\(turn)","root_turn_id":"turn-main","response_id":"response-\(input)","turn_token_usage":{\
        "input_tokens":\(input),"cached_input_tokens":20,"cache_write_input_tokens":5,"output_tokens":10,"reasoning_output_tokens":2,"total_tokens":\(input + 10)}}}
        """
    }

    private func lines(input: Int) -> String {
        metadata() + "\n" + start() + "\n{\"type\":\"response_item\",\"payload\":{\"text\":\"PRIVATE_BODY\"}}\n" + record(input: input) + "\n"
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
