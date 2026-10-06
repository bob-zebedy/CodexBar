import Darwin
import Foundation
import Testing

struct AppServerEventStorageTests {
    private let now = TestFixtures.now

    private func token(id: String = "root", root: String = "root", at date: Date? = nil, input: Int64 = 100) -> TokenTurn {
        TokenTurn(id: id, rootID: root, startedAt: date ?? now, updatedAt: date ?? now, usage: TokenUsage(
            inputTokens: input, cachedInputTokens: 20, cacheWriteInputTokens: 5,
            outputTokens: 10, reasoningOutputTokens: 2, totalTokens: input + 10
        ))
    }

    private func events(in directory: URL, date: Date? = nil) throws -> [AppServerEventRecord] {
        var records: [AppServerEventRecord] = []
        let url = HistoryStorage.eventLogURL(for: HistoryStorage.dateKey(for: date ?? now), in: HistoryStorage.eventsDirectoryURL(in: directory))
        try AppServerEventJournal.read(at: url) { records.append($0) }
        return records
    }

    @Test func mixedJournalPreservesEveryActivityMetricAndSkipsTokensWithoutCorruption() throws {
        let activity = ActivityEventKind.allCases.map { TestFixtures.event($0) }
        var before = ActivityAccumulator(rebuilding: HistoryStorage.dateKey(for: now), generationID: nil, generationStartedEmpty: true, eventCountAvailability: .all)
        var after = before
        var corrupt = 0
        for event in activity {
            before.record(event)
            let record = AppServerEventRecord(activity: event, recordedAt: now)
            corrupt += try HistoryService.decode(record.jsonLineData()) { after.record($0) }
            let token = AppServerEventRecord(token: token(), recordedAt: now)
            corrupt += try HistoryService.decode(token.jsonLineData()) { after.record($0) }
        }
        let expected = before.finalized(identifierStorage: .retained)
        let actual = after.finalized(identifierStorage: .retained)
        #expect(corrupt == 0)
        #expect(actual == expected)
    }

    @Test func nativeMetadataRoundTripsWithoutChangingBusinessIdentity() throws {
        var event = TestFixtures.event(.toolStarted, session: "root", turn: "child-turn", agent: "child", origin: .auxiliary)
        event.source = AppServerEventSource(
            method: "item/started", threadID: "child", turnID: "child-turn", parentThreadID: "parent",
            rootThreadID: "root", rootTurnID: "root-turn", itemID: "item", itemType: "commandExecution", itemStatus: "inProgress"
        )
        let record = AppServerEventRecord(activity: event, recordedAt: now)
        let decoded = try AppServerEventRecord.decode(from: record.jsonLineData())
        #expect(decoded.activity == event)
        #expect(decoded.source?.threadID == "child")
        #expect(decoded.activity?.sessionID == "root")
        let text = try #require(String(bytes: record.jsonLineData(), encoding: .utf8))
        #expect(text.contains("toolStarted"))
        #expect(!text.contains("PreToolUse"))
        #expect(!text.contains("commandLine"))
    }

    @Test func activityStorageSeparatesProtocolContextFromBusinessFields() throws {
        var event = TestFixtures.event(.approvalRequested, agent: "child", reviewer: .user)
        event.source = AppServerEventSource(
            method: "item/commandExecution/requestApproval", threadID: "child", turnID: "child-turn",
            parentThreadID: "parent", rootThreadID: "root", rootTurnID: "root-turn", itemID: "item",
            itemType: "commandExecution", itemStatus: "inProgress", agentThreadID: "child",
            itemKind: "started", requestID: "request", reviewID: "review", turnStatus: "inProgress",
            turnStartedAt: now, turnCompletedAt: now.addingTimeInterval(1), durationMs: 1000
        )
        let data = try AppServerEventRecord(activity: event, recordedAt: now).jsonLineData()
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(record.keys) == ["version", "kind", "recordedAt", "source", "activityPayload"])
        let context = try #require(record["source"] as? [String: Any])
        #expect(Set(context.keys) == [
            "method", "threadID", "turnID", "parentThreadID", "rootThreadID",
            "rootTurnID", "itemID", "itemType", "itemStatus", "agentThreadID",
            "itemKind", "requestID", "reviewID", "turnStatus", "turnStartedAt", "turnCompletedAt", "durationMs"
        ])
        #expect(context["itemKind"] as? String == "started")
        #expect(context["durationMs"] as? Double == 1000)
        #expect(context["turnStartedAt"] as? Double == now.timeIntervalSince1970 * 1000)
        let payload = try #require(record["activityPayload"] as? [String: Any])
        #expect(Set(payload.keys) == [
            "timestamp", "name", "origin", "cwd", "tool", "model", "effort",
            "approvalReviewer", "sessionID", "turnID", "agentID"
        ])
        #expect(try AppServerEventRecord.decode(from: data).activity == event)
    }

    @Test func tokenStorageAndCheckpointsUsePropertyNamesAndPreserveAllCounters() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        var turn = token()
        turn.rebuiltAt = now
        try await store.record([turn], now: now)
        let data = try AppServerEventRecord(token: turn, recordedAt: now).jsonLineData()
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(record.keys) == ["version", "kind", "recordedAt", "token"])
        let snapshot = try #require(record["token"] as? [String: Any])
        #expect(Set(snapshot.keys) == ["id", "rootID", "startedAt", "updatedAt", "rebuiltAt", "usage", "generationID", "ancestorIDs", "checkpoint", "hasConflict"])
        let counts = try #require(snapshot["usage"] as? [String: Int64])
        #expect(counts == ["inputTokens": 100, "cachedInputTokens": 20, "cacheWriteInputTokens": 5, "outputTokens": 10, "reasoningOutputTokens": 2, "totalTokens": 110])
        #expect(try AppServerEventRecord.decode(from: data).token == turn)
        _ = try await store.refresh(now: now)
        let cacheData = try Data(contentsOf: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        let cache = try #require(JSONSerialization.jsonObject(with: cacheData) as? [String: Any])
        #expect(Set(cache.keys) == ["version", "turns", "files"])
        let checkpoints = try #require(cache["files"] as? [String: [String: Any]])
        let checkpoint = try #require(checkpoints[HistoryStorage.dateKey(for: now)])
        #expect(Set(checkpoint.keys) == ["size", "identifier", "modificationTime"])
        #expect(try await TokenHistoryStore(directoryURL: directory.url).refresh(now: now) == [turn])
    }

    @Test func unsupportedVersionAndMixedPayloadAreRejected() throws {
        let valid = try #require(String(bytes: AppServerEventRecord(token: token(), recordedAt: now).jsonLineData(), encoding: .utf8))
        let future = valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":99")
        let mixed = valid.replacingOccurrences(of: "\"version\":2", with: "\"version\":2,\"activityPayload\":{}")
        for text in [future, mixed] {
            #expect(throws: (any Error).self) { try AppServerEventRecord.decode(from: Data(text.utf8)) }
        }
    }

    @Test func sharedJournalSurvivesRestartCacheDeletionAndDuplicateSnapshots() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = TokenHistoryStore(directoryURL: directory.url)
        let second = TokenHistoryStore(directoryURL: directory.url)
        try await first.record([token()], now: now)
        try await second.record([token()], now: now)
        #expect(try events(in: directory.url).count == 1)
        let update = token(at: now.addingTimeInterval(1), input: 200)
        try await second.record([update], now: now)
        #expect(try await first.refresh(now: now).first?.usage == update.usage)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        let restarted = TokenHistoryStore(directoryURL: directory.url)
        let restored = try await restarted.refresh(now: now)
        #expect(restored.count == 1)
        #expect(restored.first?.usage == update.usage)
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("Tokens").path))
    }

    @Test func submillisecondTimestampsRecoverExactlyFromJournal() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let timestamp = now.addingTimeInterval(0.1234567)
        try await store.record([token(at: timestamp)], now: timestamp)
        _ = try await store.rebuild(for: [HistoryStorage.dateKey(for: timestamp)], now: timestamp.addingTimeInterval(0.0000456))
        let original = try await store.refresh(now: timestamp)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        let recovered = try await TokenHistoryStore(directoryURL: directory.url).refresh(now: timestamp)
        #expect(recovered == original)
    }

    @Test func timestampsUseIntegerMillisecondsAcrossJournalAndSyncCache() throws {
        let timestamp = now.addingTimeInterval(0.1234567)
        let expected = Int64(now.timeIntervalSince1970 * 1000) + 123
        var event = TestFixtures.event(.turnStarted)
        event.source = AppServerEventSource(
            method: "turn/started", threadID: "thread", turnStartedAt: timestamp,
            turnCompletedAt: timestamp, durationMs: 0.4567
        )
        let data = try AppServerEventRecord(activity: event, recordedAt: timestamp).jsonLineData()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"recordedAt\":\(expected),"))
        #expect(text.contains("\"turnStartedAt\":\(expected)}"))
        let decoded = try AppServerEventRecord.decode(from: data)
        #expect(decoded.recordedAt == Date(timeIntervalSince1970: Double(expected) / 1000))
        #expect(decoded.source?.durationMs == 0.4567)

        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = directory.url.appendingPathComponent("cache.jsonl")
        let record = try ActivitySyncRecord(
            deviceID: "device", daily: ActivityAggregate(date: "2026-09-15", generationID: "source").syncedAggregate,
            updatedAt: timestamp, recordName: "device_2026-09-15_source"
        )
        try JSONFileStorage.save(record, to: url)
        let stored = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object["updatedAt"] as? Int64 == expected)
        #expect((object["daily"] as? [String: Any])?["date"] as? String == "2026-09-15")
        let records = JSONLines.decode(ActivitySyncRecord.self, from: stored)
        #expect(records.first?.updatedAt == decoded.recordedAt)
        #expect(try JSONLines.stableEncoder.encode(#require(records.first)) == stored)

        var cache = TokenFileCache<[TokenTurn]>(url: directory.url.appendingPathComponent("tokens.json"))
        try cache.save([token(at: timestamp)])
        var reopened = TokenFileCache<[TokenTurn]>(url: cache.url)
        #expect(try reopened.load()?.first?.updatedAt == decoded.recordedAt)
    }

    @Test func sameMillisecondSameSizeRewriteIsReadAgain() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        try await store.record([token()], now: now)
        let url = HistoryStorage.eventLogURL(for: HistoryStorage.dateKey(for: now), in: HistoryStorage.eventsDirectoryURL(in: directory.url))
        let seconds = Int(now.timeIntervalSince1970)
        let firstTimes = [timespec(tv_sec: seconds, tv_nsec: 1000100), timespec(tv_sec: seconds, tv_nsec: 1000100)]
        #expect(utimensat(AT_FDCWD, url.path, firstTimes, 0) == 0)
        _ = try await store.refresh(now: now)
        let before = try #require(HistoryStorage.fileStat(at: url))
        let replacement = try AppServerEventRecord(token: token(input: 200), recordedAt: now).jsonLineData()
        #expect(UInt64(replacement.count) == before.size)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: replacement)
        try handle.close()
        let secondTimes = [timespec(tv_sec: seconds, tv_nsec: 1000900), timespec(tv_sec: seconds, tv_nsec: 1000900)]
        #expect(utimensat(AT_FDCWD, url.path, secondTimes, 0) == 0)
        let after = try #require(HistoryStorage.fileStat(at: url))
        #expect(before.modificationTime == after.modificationTime)
        #expect(before.modifiedAtNanoseconds != after.modifiedAtNanoseconds)
        #expect(try await store.refresh(now: now).first?.usage?.inputTokens == 200)
        #expect(try await TokenHistoryStore(directoryURL: directory.url).refresh(now: now).first?.usage?.inputTokens == 200)
        let cache = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.url.appendingPathComponent("Aggregates/tokens.json"))) as? [String: Any])
        let checkpoints = try #require(cache["files"] as? [String: [String: Any]])
        #expect(checkpoints[HistoryStorage.dateKey(for: now)]?["modificationTime"] as? Int64 == after.modificationTime)
    }

    @Test func rebuildMarkerAlsoSurvivesDeletingAggregateCache() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = TokenHistoryStore(directoryURL: directory.url)
        let value = token()
        let observation = try TokenObservation(
            turn: TokenTurn(id: value.id, rootID: value.rootID, startedAt: now, updatedAt: now),
            rootStartedAt: now,
            streamID: "stream",
            sequence: 1,
            previous: .zero,
            current: #require(value.usage)
        )
        _ = try await store.recordObservations([observation], now: now)
        let rebuiltAt = now.addingTimeInterval(1)
        _ = try await store.rebuild(for: [HistoryStorage.dateKey(for: now)], now: rebuiltAt)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        #expect(try await store.refresh(now: rebuiltAt).first?.rebuiltAt == rebuiltAt)
    }

    @Test func childAfterMidnightKeepsRootDateWhenAllCachesAreDeleted() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let start = try #require(CodexDateFormat.dayDate(from: "2026-09-15")).addingTimeInterval(86390)
        let next = start.addingTimeInterval(60)
        let store = TokenHistoryStore(directoryURL: directory.url)
        try await store.record([token(at: start)], now: start)
        try await store.record([token(id: "child", at: next, input: 200)], now: next)
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Aggregates/tokens.json"))
        let restored = try await store.refresh(now: next)
        #expect(TokenTurn.dailyUsage(restored, now: next)["2026-09-15"]?.totalTokens == 320)
        #expect(TokenTurn.dailyUsage(restored, now: next).count == 1)
    }

    @Test func partialTailAndInterleavedActivityDoNotLoseTokensOrDefeatDeduplication() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let recorder = ActivityRecorder(directoryURL: directory.url)
        let store = TokenHistoryStore(directoryURL: directory.url)
        let event = ActivityRecord(
            timestamp: now, name: ActivityEventKind.toolStarted.rawValue, origin: .main,
            cwd: nil, tool: "Bash", model: "model", effort: nil,
            approvalReviewer: nil, sessionID: "thread", turnID: "turn", agentID: nil, id: "tool"
        )
        try await recorder.record(event: event)
        try await store.record([token()], now: now)
        let url = HistoryStorage.eventLogURL(for: HistoryStorage.dateKey(for: now), in: HistoryStorage.eventsDirectoryURL(in: directory.url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":".utf8))
        try handle.close()
        let updated = token(at: now.addingTimeInterval(1), input: 300)
        try await store.record([updated], now: now)
        try await recorder.record(event: event)
        let entries = try events(in: directory.url)
        #expect(entries.compactMap(\.activity).count == 1)
        #expect(entries.compactMap(\.token).count == 2)
        #expect(try await store.refresh(now: now).first?.usage == updated.usage)
    }
}
