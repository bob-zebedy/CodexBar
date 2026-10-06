import Foundation
import Testing

struct ProtectionStoreTests {
    @Test func expiredRecordsArePrunedAtExactDeadline() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let store = ProtectionStore(directoryURL: directory.url)
        let record = makeRecord("task", markedAfter: 0, expiresAfter: 10)
        try await store.apply(upserts: [record], now: TestFixtures.now)
        #expect(await store.load(now: TestFixtures.now.addingTimeInterval(9))["task"] == record)
        #expect(await store.load(now: TestFixtures.now.addingTimeInterval(10)).isEmpty)
        let reopened = ProtectionStore(directoryURL: directory.url)
        #expect(await reopened.load(now: TestFixtures.now).isEmpty)
    }

    @Test func olderUpsertAndStaleRemovalCannotOverwriteNewerRecord() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = ProtectionStore(directoryURL: directory.url)
        let second = ProtectionStore(directoryURL: directory.url)
        let older = makeRecord("task", markedAfter: 0)
        let newer = makeRecord("task", markedAfter: 5)
        try await first.apply(upserts: [newer], now: TestFixtures.now)
        try await second.apply(upserts: [older], removals: [ProtectionRemoval(taskIdentifier: "task", matchingMarkedAt: older.markedAt)], now: TestFixtures.now)
        #expect(await first.load(now: TestFixtures.now)["task"] == newer)
        try await second.apply(removals: [ProtectionRemoval(taskIdentifier: "task", matchingMarkedAt: newer.markedAt)], now: TestFixtures.now)
        #expect(await first.load(now: TestFixtures.now).isEmpty)
    }

    @Test func concurrentStoreInstancesPreserveIndependentRecords() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let first = ProtectionStore(directoryURL: directory.url)
        let second = ProtectionStore(directoryURL: directory.url)
        async let firstWrite: Void = first.apply(upserts: [makeRecord("first", markedAfter: 0)], now: TestFixtures.now)
        async let secondWrite: Void = second.apply(upserts: [makeRecord("second", markedAfter: 0)], now: TestFixtures.now)
        _ = try await (firstWrite, secondWrite)
        #expect(await Set(first.load(now: TestFixtures.now).keys) == ["first", "second"])
    }

    @Test(arguments: ["not-json", #"{"version":999,"records":[]}"#])
    func invalidStateLoadsEmptyAndCanBeReplaced(_ content: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        _ = try directory.write(content, to: "state.json")
        let store = ProtectionStore(directoryURL: directory.url)
        #expect(await store.load(now: TestFixtures.now).isEmpty)
        let record = makeRecord("task", markedAfter: 0)
        try await store.apply(upserts: [record], now: TestFixtures.now)
        #expect(await store.load(now: TestFixtures.now)["task"] == record)
    }

    @Test func duplicateStoredIdentifiersChooseLatestMarkAndFileIsPrivate() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let older = makeRecord("task", markedAfter: 0)
        let newer = makeRecord("task", markedAfter: 5)
        let records = try #require(String(data: JSONEncoder().encode([newer, older]), encoding: .utf8))
        let url = try directory.write("{\"version\":1,\"records\":\(records)}", to: "state.json")
        let store = ProtectionStore(directoryURL: directory.url)
        #expect(await store.load(now: TestFixtures.now)["task"] == newer)
        try await store.apply(now: TestFixtures.now)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    private nonisolated func makeRecord(_ identifier: String, markedAfter: TimeInterval, expiresAfter: TimeInterval = 60) -> ProtectionRecord {
        ProtectionRecord(
            taskIdentifier: identifier, lastProgressAt: TestFixtures.now.addingTimeInterval(-3600),
            markedAt: TestFixtures.now.addingTimeInterval(markedAfter), expiresAt: TestFixtures.now.addingTimeInterval(expiresAfter)
        )
    }
}
