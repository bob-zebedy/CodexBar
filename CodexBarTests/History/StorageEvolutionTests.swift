import Foundation
import Testing

struct StorageEvolutionTests {
    @Test(arguments: ["version", "aggregationVersion"])
    func unsupportedAggregateIsNotRewrittenOrShownAsZero(_ field: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        var aggregate = TestFixtures.aggregate()
        aggregate = ActivityAggregate(date: HistoryStorage.dateKey(for: Date()), generationID: aggregate.generationID)
        var object = try #require(JSONSerialization.jsonObject(with: aggregate.jsonLineData()) as? [String: Any])
        object[field] = 999
        let original = try JSONSerialization.data(withJSONObject: object)
        let url = try directory.write(original, to: "Aggregates/activity.jsonl")
        let history = HistoryService(directoryURL: directory.url, syncService: SyncService(isEnabled: { false }))
        let result = await history.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual)
        #expect(!result.snapshot.isActivityComplete)
        #expect(try Data(contentsOf: url) == original)
        let days = UsageHeatmapDay.grid(usage: nil, history: result.snapshot, columnCount: 1, today: Date()).compactMap(\.self)
        #expect(days.allSatisfy { $0.history.threadCount == nil && $0.history.toolCallCount == nil })
    }

    @Test func unsupportedJournalCannotBeAppendedOrPruned() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date()
        let old = HistoryStorage.retentionCutoffDate(today: now).addingTimeInterval(-86400)
        let date = HistoryStorage.dateKey(for: old)
        let data = Data("{\"version\":999,\"date\":\"\(date)\",\"generationID\":\"source\"}\n".utf8)
        let url = try directory.write(data, to: "Events/\(date).jsonl")
        var journal = AppServerEventJournal()
        #expect(throws: StorageCompatibilityError.self) {
            try journal.append(AppServerEventRecord(activity: TestFixtures.event(at: old)), in: directory.url)
        }
        let history = HistoryService(directoryURL: directory.url, syncService: SyncService(isEnabled: { false }))
        _ = await history.loadSnapshotWithMaintenance(synchronize: false, trigger: .manual, now: now)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func checkpointDetectsMiddleRewriteOutsideOldTailWindow() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let url = try directory.write(Data(repeating: 97, count: 16384), to: "prefix")
        let checkpoint = try ActivitySourceCheckpoint.read(at: url, byteCount: 16384)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 10)
        try handle.write(contentsOf: Data([98]))
        try handle.close()
        #expect(try ActivitySourceCheckpoint.read(at: url, byteCount: 16384) != checkpoint)
        #expect(throws: StorageCompatibilityError.incompleteSource) {
            try ActivitySourceCheckpoint.read(at: url, byteCount: 16385)
        }
    }

    @Test func tokenAlgorithmMismatchCannotBeMerged() throws {
        let first = TestFixtures.tokenTurn(id: "turn", rootID: "turn", startedAt: Date(), updatedAt: Date(), usage: .zero)
        var unsupported = first
        unsupported.aggregationVersion = 999
        #expect(throws: StorageCompatibilityError.self) { try first.merging(unsupported) }
        #expect(throws: StorageCompatibilityError.self) {
            try JSONLines.decoder.decode(TokenTurn.self, from: JSONLines.stableEncoder.encode(unsupported))
        }
    }

    @Test func protocolBoundaryNormalizesStatusAndTimeUnits() throws {
        let input = try TestFixtures.decode(ActivityInput.self, """
        {"method":"turn/completed","params":{"threadId":"thread","turn":{"id":"turn","status":"completed","startedAt":1000,"completedAt":1002,"durationMs":1500}}}
        """)
        #expect(input.kind == .turnFinished)
        #expect(input.params.turn?.status == .completed)
        #expect(input.params.turn?.startedAt == Date(timeIntervalSince1970: 1000))
        #expect(input.params.turn?.duration == 1.5)
        let unknown = try TestFixtures.decode(ActivityInput.self, "{\"method\":\"future/event\",\"params\":{}}")
        #expect(unknown.kind == .ignored)
    }
}
