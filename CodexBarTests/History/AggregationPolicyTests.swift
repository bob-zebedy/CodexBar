import CloudKit
import Foundation
import Testing

struct AggregationPolicyTests {
    @Test func tokenUsageIdentityAndCloudEncodingPreserveAlgorithmVersions() throws {
        let now = Date()
        var turn = TestFixtures.tokenUsageAggregate(at: now)
        turn.aggregationVersion = 1
        let daily = try #require(TokenUsageSyncRecord.dailyRecords(local: [turn], deviceID: "device", now: now).first)
        let record = CKRecord(recordType: TokenUsageSync.recordType, recordID: CKRecord.ID(recordName: daily.id))
        try TokenUsageSync.apply(daily, to: record)
        #expect(try TokenUsageSync.dailyRecord(from: record)?.aggregationVersion == AggregationVersion.tokenUsage)
        let observation = TestFixtures.tokenUsageObservation(at: now, tokenUsage: .zero)
        let encoded = try JSONLines.stableEncoder.encode(observation)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["turn"] == nil)
        #expect(object["rootID"] == nil)
        #expect(object["aggregationVersion"] == nil)
        #expect(object["observedAt"] != nil)
    }

    @Test func algorithmCompatibilityAcceptsPastAndRejectsFuture() throws {
        try AggregationVersion.require(1, current: 2, name: "test")
        #expect(throws: StorageCompatibilityError.self) { try AggregationVersion.require(3, current: 2, name: "test") }
        #expect(throws: StorageCompatibilityError.self) { try AggregationVersion.require(0, current: 2, name: "test") }
    }

    @Test func partialSourcesKeepKnownValuesVisible() {
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        var aggregate = ActivityDataAggregate(date: date)
        aggregate.turnCount = 3
        var snapshot = HistorySnapshot(activityData: [aggregate.metrics])
        snapshot.isActivityDataComplete = false
        let day = UsageHeatmapDay.grid(usage: nil, history: snapshot, columnCount: 1, today: now).compactMap(\.self).first { $0.startDate == date }
        #expect(day?.activityData.turnCount == 3)
    }
}
