import CloudKit
import CryptoKit
import Foundation
import Synchronization
import Testing

struct TokenHistoryTests {
    @Test func unchangedTokenStorageDoesNotReplaceFile() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.json")
        let values = [turn("main", "a", input: 100)]
        try JSONFileStorage.save(values, to: url)
        let before = try #require(HistoryStorage.fileStat(at: url))
        try JSONFileStorage.save(values, to: url)
        let after = try #require(HistoryStorage.fileStat(at: url))
        #expect(after.identifier == before.identifier)
        #expect(after.modifiedAtNanoseconds == before.modifiedAtNanoseconds)
        #expect(try JSONFileStorage.load([TokenTurn].self, from: url) == values)
    }

    @Test func tokenIdentitiesMatchExistingEncodingExactly() throws {
        let bytes = Data((0 ... 255).map(UInt8.init))
        #expect(TokenTurn.hexString(bytes) == bytes.map { String(format: "%02x", $0) }.joined())
        #expect(TokenTurn.hexString(Data()).isEmpty)
        let salt = Data((0 ... 255).map(UInt8.init))
        for thread in ["", "thread", "中文/路径", "a\u{0000}b", String(repeating: "x", count: 1024)] {
            let data = try JSONEncoder().encode(["token-turn-v1", thread, "turn"])
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(TokenTurn.identifier(thread: thread, turn: "turn") == expected)
            for root in [expected, "other-root"] {
                let value = TokenTurn(id: expected, rootID: root, updatedAt: TestFixtures.now)
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
            #expect(TokenTurn.pseudonymized(records, salt: salt) == records.map { $0.pseudonymized(salt: salt) })
        }
    }

    @Test func cachedTokenFileChecksBytesAcrossExternalWritesAndDeletion() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.json")
        var first = TokenFileCache<[String: Int]>(url: url)
        var second = TokenFileCache<[String: Int]>(url: url)
        try first.save(["cursor": 1])
        #expect(try first.load() == ["cursor": 1])
        #expect(try second.load() == ["cursor": 1])
        let initial = try #require(HistoryStorage.fileStat(at: url))
        try first.save(["cursor": 1])
        #expect(HistoryStorage.fileStat(at: url)?.identifier == initial.identifier)
        let modifiedAt = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        try Data("{\"cursor\":2}".utf8).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        #expect(HistoryStorage.fileStat(at: url)?.size == initial.size)
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

    @Test func cloudRebuildMarkerOverridesStaleTotalsAndCanClearUsage() {
        let stale = turn("main", "a", input: 500)
        var rebuilt = turn("main", "a", input: 100)
        rebuilt.startNewGeneration(at: TestFixtures.now)
        #expect(stale.merging(rebuilt) == rebuilt)
        #expect(rebuilt.merging(stale) == rebuilt)
        let exported = rebuilt.pseudonymized(salt: Data("account".utf8))
        let record = CKRecord(recordType: TokenSync.recordType, recordID: .init(recordName: exported.id))
        TokenSync.apply(exported, to: record)
        #expect(TokenSync.turn(from: record) == exported)
        var cleared = exported
        cleared.usage = nil
        cleared.startNewGeneration(at: TestFixtures.now.addingTimeInterval(1))
        TokenSync.apply(cleared, to: record)
        #expect(TokenSync.turn(from: record) == cleared)
        #expect(exported.merging(cleared).usage == nil)
        #expect(TokenTurn.syncable([cleared]) == [cleared])
    }

    @Test func cloudRecoveryMatchesAccountSaltAndRootIdentity() {
        let local = turn("child", "b", root: TokenTurn.identifier(thread: "main", turn: "a"), input: 100)
        var remote = local.pseudonymized(salt: Data("account-a".utf8))
        remote.startNewGeneration(at: TestFixtures.now)
        #expect(TokenHistoryBaseline(salt: Data("account-b".utf8), turns: [remote.id: remote]).replacement(for: local) == nil)
        let baseline = TokenHistoryBaseline(salt: Data("account-a".utf8), turns: [remote.id: remote])
        #expect(baseline.replacement(for: local)?.rootID == local.rootID)
        var unknownRoot = local
        unknownRoot.rootID = local.id
        #expect(baseline.replacement(for: unknownRoot) == nil)
    }

    @Test func sharedSyncLockExcludesConcurrentWritersWithoutBlockingCacheReads() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = try #require(try JSONFileStorage.acquireLock(in: directory.url, name: "sync.lock", nonblocking: true))
        let competing = try JSONFileStorage.acquireLock(in: directory.url, name: "sync.lock", nonblocking: true)
        #expect(competing == nil)
        if let competing {
            JSONFileStorage.releaseLock(competing)
        }
        try JSONFileStorage.withLock(in: directory.url) {}
        JSONFileStorage.releaseLock(first)
        let next = try #require(try JSONFileStorage.acquireLock(in: directory.url, name: "sync.lock", nonblocking: true))
        JSONFileStorage.releaseLock(next)
    }

    @Test func cumulativeSnapshotsAndMultipleDevicesCountEachThreadTurnOnce() {
        let root = turn("main", "a", input: 100)
        var updated = turn("main", "a", input: 200)
        updated.updatedAt = TestFixtures.now.addingTimeInterval(10)
        let child = turn("child", "b", root: root.id, input: 300)
        let result = TokenTurn.dailyUsage([root, updated, root, child, child], now: TestFixtures.now.addingTimeInterval(60))
        #expect(result[day]?.totalTokens == 520)
        #expect(TokenTurn.merged([updated, root])[root.id] == TokenTurn.merged([root, updated])[root.id])
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
        let days = TokenTurn.dailyUsage([root, child, followup], now: start.addingTimeInterval(100))
        #expect(days.count == 1)
        #expect(days["2026-09-15"]?.totalTokens == 630)
        #expect(TokenTurn.dailyUsage([child], now: start.addingTimeInterval(100)).isEmpty)
    }

    @Test func cacheRateUsesDailyTotalsAndMissingUsageDoesNotBecomeZero() {
        var a = turn("main", "a", input: 100)
        var b = turn("other", "a", input: 300)
        a.usage = usage(input: 100, cached: 80)
        b.usage = usage(input: 300, cached: 30)
        let merged = TokenTurn.dailyUsage([a, b], now: TestFixtures.now)
        #expect(merged[day]?.cacheHitRate == 0.275)
        a.usage = nil
        #expect(TokenTurn.dailyUsage([a], now: TestFixtures.now).isEmpty)
        a.usage = TokenUsage(inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0)
        #expect(TokenTurn.dailyUsage([a], now: TestFixtures.now)[day]?.totalTokens == 0)
    }

    @Test func cloudCodecUsesAccountScopedHashesAndRetainsAllCounters() throws {
        let source = turn("private-thread", "private-turn", input: 100)
        let exported = source.pseudonymized(salt: Data("account-a".utf8))
        #expect(exported.id == exported.rootID)
        #expect(exported.id != source.id)
        #expect(exported.id != source.pseudonymized(salt: Data("account-b".utf8)).id)
        let zone = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let id = TokenSync.recordID(exported.id, zoneID: zone)
        #expect(id.recordName == exported.id)
        let record = CKRecord(recordType: TokenSync.recordType, recordID: id)
        TokenSync.apply(exported, to: record)
        #expect(TokenSync.turn(from: record) == exported)
        #expect(Set(record.allKeys()) == ["updatedAt", "rootID", "version", "startedAt", "usage", "generationID", "ancestorIDs", "checkpoint", "hasConflict"])
        let cloudUsage = try #require(record["usage"] as? Data)
        let cloudCounts = try #require(JSONSerialization.jsonObject(with: cloudUsage) as? [String: Int64])
        #expect(Set(cloudCounts.keys) == [
            "inputTokens", "cachedInputTokens", "cacheWriteInputTokens",
            "outputTokens", "reasoningOutputTokens", "totalTokens"
        ])
        let text = try #require(String(data: JSONEncoder().encode(exported), encoding: .utf8))
        #expect(!text.contains("private-thread"))
        #expect(!text.contains("private-turn"))
        record["version"] = 99 as CKRecordValue
        #expect(record.recordID == TokenSync.recordID(exported.id, zoneID: zone))
        #expect(TokenSync.turn(from: record) == nil)
    }

    @Test func childUsageWaitsForRootStartAndNeedsNoRootUsageRecord() {
        var root = turn("main", "a", input: 100)
        root.usage = nil
        let child = turn("child", "b", root: root.id, input: 200)
        #expect(TokenTurn.dailyUsage([child], now: TestFixtures.now).isEmpty)
        #expect(TokenTurn.dailyUsage([root, child], now: TestFixtures.now)[day]?.totalTokens == 210)
        #expect(Set(TokenTurn.syncable([root, child]).map(\.id)) == [root.id, child.id])
    }

    @Test func dailyOverflowIsUnavailableAndExpiredTurnsAreExcluded() {
        var root = turn("main", "a", input: 100)
        root.usage = TokenUsage(
            inputTokens: .max, cachedInputTokens: 0, cacheWriteInputTokens: 0,
            outputTokens: 0, reasoningOutputTokens: 0, totalTokens: .max
        )
        let child = turn("child", "b", root: root.id, input: 200)
        #expect(TokenTurn.dailyUsage([root, child], now: TestFixtures.now).isEmpty)
        root.startedAt = TestFixtures.now.addingTimeInterval(-220 * 86400)
        #expect(TokenTurn.dailyUsage([root], now: TestFixtures.now).isEmpty)
    }

    @Test func heatmapSeparatesAccountIntensityFromLocalDailyMetrics() throws {
        var history = HistorySnapshot.empty
        history.tokenUsageByDate = [day: usage(input: 100)]
        let grid = UsageHeatmapDay.grid(usage: nil, history: history, showsActivity: true, columnCount: 2, today: TestFixtures.now)
        let today = try #require(grid.compactMap(\.self).first { $0.startDate == day })
        #expect(today.tokenState == .unavailable)
        #expect(today.tokenUsage?.totalTokens == 110)
        #expect(today.history.turnCount == 0)
    }

    private var day: String {
        CodexDateFormat.dayString(from: TestFixtures.now)
    }

    private func usage(input: Int64, cached: Int64 = 20) -> TokenUsage {
        TokenUsage(inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 5, outputTokens: 10, reasoningOutputTokens: 2, totalTokens: input + 10)
    }

    private func turn(_ thread: String, _ turn: String, root: String? = nil, input: Int64) -> TokenTurn {
        let id = TokenTurn.identifier(thread: thread, turn: turn)
        return TokenTurn(id: id, rootID: root ?? id, startedAt: TestFixtures.now, updatedAt: TestFixtures.now, usage: usage(input: input))
    }
}

extension TokenHistoryTests {
    @Test func unknownCacheVersionIsNotOverwritten() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let data = Data(#"{"version":999,"turns":{},"files":{}}"#.utf8)
        let url = try directory.write(data, to: "Aggregates/tokens.json")
        let store = TokenHistoryStore(directoryURL: directory.url)
        await #expect(throws: TokenCacheError.self) { try await store.refresh() }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func cacheReadFailureIsNotReplacedWithEmptyData() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("Aggregates/tokens.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = TokenHistoryStore(directoryURL: directory.url)
        await #expect(throws: (any Error).self) { try await store.refresh() }
        #expect(try (url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
    }

    @Test func incompleteJournalDoesNotOverwriteDamagedCache() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let cache = try directory.write("broken cache", to: "Aggregates/tokens.json")
        _ = try directory.write("broken event\n", to: "Events/\(HistoryStorage.dateKey(for: Date())).jsonl")
        let store = TokenHistoryStore(directoryURL: directory.url)
        await #expect(throws: TokenCacheError.self) { try await store.refresh() }
        #expect(try String(contentsOf: cache, encoding: .utf8) == "broken cache")
    }
}

extension TokenHistoryTests {
    private func observation(sequence: Int64, previous: Int64, current: Int64, stream: String = "stream") -> TokenObservation {
        let id = TokenTurn.identifier(thread: "observed", turn: "turn")
        func counts(_ count: Int64) -> TokenUsage {
            TokenUsage(
                inputTokens: count,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: count
            )
        }
        return TokenObservation(
            turn: TokenTurn(id: id, rootID: id, startedAt: TestFixtures.now, updatedAt: TestFixtures.now),
            rootStartedAt: TestFixtures.now,
            streamID: stream,
            sequence: sequence,
            previous: counts(previous),
            current: counts(current)
        )
    }

    @Test func correctionAndRetryPreserveOnlyUncoveredUsageAcrossRestart() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let first = observation(sequence: 1, previous: 0, current: 100)
        var corrected = try #require(try await store.recordObservations([first], now: TestFixtures.now).first)
        corrected.usage = observation(sequence: 1, previous: 0, current: 60).current
        corrected.startNewGeneration(at: TestFixtures.now.addingTimeInterval(-60))
        let salt = Data("test".utf8)
        let remote = corrected.pseudonymized(salt: salt)
        _ = try await store.refresh(now: TestFixtures.now, baseline: TokenHistoryBaseline(salt: salt, turns: [remote.id: remote]))
        let second = observation(sequence: 2, previous: 100, current: 110)
        let result = try await store.recordObservations([first, second, second], now: TestFixtures.now)
        #expect(result.first?.usage?.totalTokens == 70)
        #expect(result.first?.generationID == corrected.generationID)
        let restarted = TokenHistoryStore(directoryURL: directory.url)
        #expect(try await restarted.recordObservations([second], now: TestFixtures.now).first?.usage?.totalTokens == 70)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        #expect(try await restarted.refresh(now: TestFixtures.now).first?.usage?.totalTokens == 70)
    }

    @Test func remoteCoveredObservationIsNotAddedTwice() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let first = observation(sequence: 1, previous: 0, current: 100)
        let second = observation(sequence: 2, previous: 100, current: 110)
        let local = try #require(try await store.recordObservations([first], now: TestFixtures.now).first)
        var corrected = try second.applying(to: local)
        corrected.startNewGeneration(at: TestFixtures.now)
        corrected.usage = observation(sequence: 1, previous: 0, current: 60).current
        let salt = Data("test".utf8)
        let remote = corrected.pseudonymized(salt: salt)
        _ = try await store.refresh(now: TestFixtures.now, baseline: TokenHistoryBaseline(salt: salt, turns: [remote.id: remote]))
        #expect(try await store.recordObservations([second], now: TestFixtures.now).first?.usage?.totalTokens == 60)
    }

    @Test func rebuildRecomputesFromCountersAndRejectsIncompleteCoverage() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let first = observation(sequence: 1, previous: 1000, current: 1100)
        var bad = try #require(try await store.recordObservations([first], now: TestFixtures.now).first)
        bad.startNewGeneration(at: TestFixtures.now)
        bad.usage = observation(sequence: 1, previous: 0, current: 900).current
        try await directory.seedTokenSnapshots([bad], now: TestFixtures.now)
        _ = try await store.rebuild(for: [day], now: TestFixtures.now)
        let restored = try #require(try await store.currentTurns(now: TestFixtures.now).first)
        #expect(restored.usage?.totalTokens == 100)
        #expect(restored.generationID != bad.generationID)
        let second = observation(sequence: 2, previous: 1100, current: 1120)
        var remote = try second.applying(to: restored)
        remote.startNewGeneration(at: TestFixtures.now)
        try await directory.seedTokenSnapshots([remote], now: TestFixtures.now)
        let failed = try await store.rebuild(for: [day], now: TestFixtures.now)
        #expect(failed.failedDateKeys == [day])
        #expect(failed.turnCount == 0)
        #expect(try await store.currentTurns(now: TestFixtures.now).first == remote)
    }

    @Test func concurrentCorrectionsConvergeToExplicitConflictWithoutClockOrdering() throws {
        let original = try observation(sequence: 1, previous: 0, current: 100).applying(to: nil)
        var a = original
        var b = original
        a.startNewGeneration(at: TestFixtures.now.addingTimeInterval(9999))
        b.startNewGeneration(at: TestFixtures.now.addingTimeInterval(-9999))
        a.usage = observation(sequence: 1, previous: 0, current: 60).current
        b.usage = observation(sequence: 1, previous: 0, current: 80).current
        let merged = a.merging(b)
        #expect(merged.hasConflict)
        #expect(merged.usage == nil)
        #expect(merged.generationID == b.merging(a).generationID)
        #expect(merged.merging(a).generationID == merged.generationID)
        #expect(merged.merging(b).generationID == merged.generationID)
        #expect(TokenTurn.dailyUsage([merged], now: TestFixtures.now).isEmpty)
    }

    @Test func missingObservationCannotAdvanceCheckpoint() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let missingFirst = observation(sequence: 2, previous: 100, current: 110)
        await #expect(throws: TokenCacheError.self) { try await store.recordObservations([missingFirst], now: TestFixtures.now) }
        #expect(try await store.currentTurns(now: TestFixtures.now).isEmpty)
    }
}

extension TokenHistoryTests {
    @Test func staleSnapshotRebasesOnlyItsUncoveredCheckpointTail() throws {
        let original = try observation(sequence: 1, previous: 0, current: 100).applying(to: nil)
        var correction = original
        correction.startNewGeneration(at: TestFixtures.now)
        correction.usage = observation(sequence: 1, previous: 0, current: 60).current
        let stale = try observation(sequence: 2, previous: 100, current: 110).applying(to: original)
        let merged = correction.merging(stale)
        #expect(merged.usage?.totalTokens == 70)
        #expect(merged.generationID == correction.generationID)
        #expect(stale.merging(correction) == merged)
        #expect(merged.merging(stale) == merged)
        #expect(merged.merging(correction) == merged)
    }
}

extension TokenHistoryTests {
    private func rebuildObservation(
        _ name: String, root: String? = nil, start: Date = TestFixtures.now,
        sequence: Int64 = 1, previous: Int64 = 0, current: Int64 = 10
    ) -> TokenObservation {
        let id = TokenTurn.identifier(thread: name, turn: "rebuild")
        let rootID = TokenTurn.identifier(thread: root ?? name, turn: "rebuild")
        let counts = observation(sequence: sequence, previous: previous, current: current)
        return TokenObservation(
            turn: TokenTurn(id: id, rootID: rootID, startedAt: start, updatedAt: TestFixtures.now),
            rootStartedAt: start, streamID: name, sequence: sequence, previous: counts.previous, current: counts.current
        )
    }

    private func writeJournal(_ observations: [TokenObservation], in directory: TestDirectory, at date: Date = TestFixtures.now) throws {
        let data = try observations.reduce(into: Data()) { result, observation in
            try result.append(AppServerEventRecord(observation: observation, recordedAt: date).jsonLineData())
        }
        _ = try directory.write(data, to: "Events/\(HistoryStorage.dateKey(for: date)).jsonl")
    }

    @Test func unselectedIncompleteRootDoesNotBlockRebuildOrSubsequentCacheLoad() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let selected = rebuildObservation("selected")
        let unselected = rebuildObservation("other", start: TestFixtures.now.addingTimeInterval(-86400), sequence: 2, previous: 10, current: 20)
        try writeJournal([selected, unselected], in: directory)
        let store = TokenHistoryStore(directoryURL: directory.url)
        let result = try await store.rebuild(for: [day], now: TestFixtures.now)
        #expect(result.failedDateKeys.isEmpty)
        #expect(result.turnCount == 1)
        let expected = try #require(result.turns?.first { $0.id == selected.turn.id })
        #expect(expected.usage?.totalTokens == 10)
        let restarted = TokenHistoryStore(directoryURL: directory.url)
        let loaded = try await restarted.refresh(now: TestFixtures.now)
        #expect(loaded == [expected])
        let cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appendingPathComponent("Aggregates/tokens.json"))) as? [String: Any])
        #expect((cache["files"] as? [String: Any])?.isEmpty == true)
    }

    @Test func failedRootPreservesOldResultWhileSameDayHealthyRootIsRebuilt() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let previous = rebuildObservation("bad")
        let old = try #require(try await store.recordObservations([previous], now: TestFixtures.now).first)
        let good = rebuildObservation("good")
        let broken = rebuildObservation("bad", sequence: 3, previous: 20, current: 30)
        try writeJournal([good, broken], in: directory)
        let result = try await store.rebuild(for: [day], now: TestFixtures.now)
        #expect(result.failedDateKeys == [day])
        #expect(result.turnCount == 1)
        #expect(result.turns?.first { $0.id == old.id } == old)
        let rebuilt = try #require(result.turns?.first { $0.id == good.turn.id })
        #expect(rebuilt.generationID != "initial")
        let reopened = TokenHistoryStore(directoryURL: directory.url)
        let loaded = try await reopened.refresh(now: TestFixtures.now)
        #expect(loaded.first { $0.id == old.id } == old)
        #expect(loaded.first { $0.id == rebuilt.id } == rebuilt)
    }

    @Test func rebuildIncludesChildObservationsWrittenOnAnotherDay() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let root = rebuildObservation("root")
        let child = rebuildObservation("child", root: "root", current: 20)
        try writeJournal([root], in: directory)
        try writeJournal([child], in: directory, at: TestFixtures.now.addingTimeInterval(86400))
        let store = TokenHistoryStore(directoryURL: directory.url)
        let result = try await store.rebuild(for: [day], now: TestFixtures.now.addingTimeInterval(86400))
        #expect(result.failedDateKeys.isEmpty)
        #expect(result.turnCount == 2)
        #expect(TokenTurn.dailyUsage(result.turns ?? [], now: TestFixtures.now.addingTimeInterval(86400))[day]?.totalTokens == 30)
    }

    @Test func missingCachedChildPreventsReplacingItsWholeRoot() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let root = rebuildObservation("root")
        let child = rebuildObservation("child", root: "root")
        let before = try await store.recordObservations([root, child], now: TestFixtures.now)
        try writeJournal([root], in: directory)
        let result = try await store.rebuild(for: [day], now: TestFixtures.now)
        #expect(result.failedDateKeys == [day])
        #expect(result.turnCount == 0)
        #expect(Set(result.turns?.map(\.generationID) ?? []) == Set(before.map(\.generationID)))
        #expect(result.turns?.first { $0.id == child.turn.id } == before.first { $0.id == child.turn.id })
    }

    @Test func failedRootRollsBackAcrossFilesAndRetainsCursorsUntilRepair() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = rebuildObservation("root")
        let second = rebuildObservation("root", sequence: 2, previous: 10, current: 20)
        let third = rebuildObservation("root", sequence: 3, previous: 20, current: 30)
        let fourth = rebuildObservation("root", sequence: 4, previous: 30, current: 40)
        let store = TokenHistoryStore(directoryURL: directory.url)
        let before = try #require(try await store.recordObservations([first], now: TestFixtures.now).first)
        try writeJournal([first, second], in: directory)
        let nextDay = TestFixtures.now.addingTimeInterval(86400)
        try writeJournal([fourth], in: directory, at: nextDay)
        let partial = try await store.refresh(now: nextDay)
        #expect(partial == [before])
        let cacheURL = directory.url.appendingPathComponent("Aggregates/tokens.json")
        let cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        #expect((cache["files"] as? [String: Any])?.isEmpty == true)
        try writeJournal([third, fourth], in: directory, at: nextDay)
        let restarted = TokenHistoryStore(directoryURL: directory.url)
        let repaired = try await restarted.refresh(now: nextDay)
        #expect(repaired.first?.usage?.totalTokens == 40)
        #expect(try await restarted.refresh(now: nextDay) == repaired)
    }

    @Test func unattributedCorruptionAndConflictingOwnershipDoNotOverwriteLedger() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let first = rebuildObservation("root")
        _ = try await store.recordObservations([first], now: TestFixtures.now)
        let cacheURL = directory.url.appendingPathComponent("Aggregates/tokens.json")
        let before = try Data(contentsOf: cacheURL)
        let eventURL = HistoryStorage.eventLogURL(for: day, in: HistoryStorage.eventsDirectoryURL(in: directory.url))
        try Data("broken record\n".utf8).write(to: eventURL)
        await #expect(throws: TokenCacheError.self) { try await store.rebuild(for: [day], now: TestFixtures.now) }
        #expect(try Data(contentsOf: cacheURL) == before)
        let ambiguous = rebuildObservation("root", root: "different")
        try writeJournal([first, ambiguous], in: directory)
        await #expect(throws: TokenCacheError.self) { try await store.rebuild(for: [day], now: TestFixtures.now) }
        #expect(try Data(contentsOf: cacheURL) == before)
    }
}
