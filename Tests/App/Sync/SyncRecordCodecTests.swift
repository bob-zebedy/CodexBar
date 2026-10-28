import CloudKit
import Foundation
import Testing

struct SyncRecordCodecTests {
    @Test func cloudDailyCountsRoundTripWithEventNames() throws {
        let counts = [
            "threadCount": 2, "turnCount": 3,
            "turnStartedCount": 3,
            "turnCompletedCount": 4, "turnAbortedCount": 5, "toolStartedCount": 6,
            "toolCompletedCount": 7, "approvalRequestedCount": 8, "compactionStartedCount": 9,
            "compactionCompletedCount": 10, "subagentStartedCount": 11, "subagentEndedCount": 12
        ]
        var fields: [String: Any] = counts
        fields["schemaVersion"] = 1
        fields["aggregationVersion"] = 1
        fields["date"] = "2026-09-15"
        let aggregate = try JSONDecoder().decode(
            SyncedActivityData.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        let record = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_device-a_2026-09-15"))
        try ActivityDataRecordCodec.apply(aggregate, deviceID: "device-a", to: record)
        #expect(Set(record.allKeys()) == [
            "schemaVersion", "aggregationVersion", "deviceID", "date", "activityData", "updatedAt"
        ])
        let payload = try #require(record["activityData"] as? Data)
        let encodedCounts = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(Set(encodedCounts.keys) == Set(counts.keys).union(["eventCount", "projectCounts", "modelCounts"]))
        for (name, count) in counts {
            #expect(encodedCounts[name] as? Int == count)
        }
        #expect(encodedCounts["eventCount"] is NSNull)
        let restored = try #require(try ActivityDataRecordCodec.remoteDailyRecord(from: record))
        #expect(restored.deviceID == "device-a")
        #expect(restored.activityData == aggregate)

        var changed = aggregate
        changed.turnAbortedCount = nil
        changed.toolStartedCount = 0
        try ActivityDataRecordCodec.apply(changed, deviceID: "device-a", to: record)
        let changedData = try #require(record["activityData"] as? Data)
        let changedCounts = try #require(JSONSerialization.jsonObject(with: changedData) as? [String: Any])
        #expect(changedCounts["turnAbortedCount"] is NSNull)
        #expect(changedCounts["toolStartedCount"] as? Int == 0)
        let missing = try #require(try ActivityDataRecordCodec.remoteDailyRecord(from: record))
        #expect(missing.activityData.turnAbortedCount == nil)
        #expect(missing.activityData.toolStartedCount == 0)
    }

    @Test(arguments: [nil, ""]) func cloudActivityDataRejectsMissingDevice(deviceID: String?) {
        let record = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_device_2026-09-15"))
        record["schemaVersion"] = 1 as CKRecordValue
        record["aggregationVersion"] = 1 as CKRecordValue
        record["activityData"] = Data(#"{"projectCounts":{},"modelCounts":{}}"#.utf8) as CKRecordValue
        record["deviceID"] = deviceID as CKRecordValue?
        record["date"] = "2026-09-15" as CKRecordValue
        #expect(throws: ActivityDataSyncError.self) { try ActivityDataRecordCodec.remoteDailyRecord(from: record) }
    }

    @Test func cloudAndCachedActivityDataRejectMismatchedIdentity() throws {
        let daily = SyncedActivityData(
            date: "2026-09-15",
            projectCounts: [:],
            modelCounts: [:]
        )
        let record = CKRecord(recordType: "ActivityData", recordID: CKRecord.ID(recordName: "activityData_other_2026-09-15"))
        try ActivityDataRecordCodec.apply(daily, deviceID: "device", to: record)
        #expect(throws: ActivityDataSyncError.self) { try ActivityDataRecordCodec.remoteDailyRecord(from: record) }
        #expect(throws: DecodingError.self) {
            try TestFixtures.decode(
                ActivityDataSyncRecord.self,
                #"{"deviceID":"device","recordName":"activityData_other_2026-09-15","schemaVersion":1,"aggregationVersion":1,"date":"2026-09-15","activityData":{}}"#
            )
        }
    }

    @Test(arguments: [nil, TokenUsage.zero, TokenUsage(
        inputTokens: 100, cachedInputTokens: 20, cacheWriteInputTokens: 5,
        outputTokens: 10, reasoningOutputTokens: 2, totalTokens: 110
    )])
    func cloudDailyTokenUsageAlwaysEncodeAllQuantityKeys(tokenUsage: TokenUsage?) throws {
        let daily = TokenUsageSyncRecord(deviceID: "device", date: "2026-10-12", tokenUsage: tokenUsage)
        let record = try SyncTestFixtures.tokenUsageRecord(daily)
        #expect(record.recordID.recordName == "tokenUsage_device_2026-10-12")
        #expect(Set(record.allKeys()) == ["schemaVersion", "aggregationVersion", "deviceID", "date", "tokenUsage", "updatedAt"])
        let data = try #require(record["tokenUsage"] as? Data)
        let counts = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(counts.keys) == ["inputTokens", "cachedInputTokens", "cacheWriteInputTokens", "outputTokens", "reasoningOutputTokens", "totalTokens"])
        if let tokenUsage {
            #expect(try JSONDecoder().decode(TokenUsage.self, from: data) == tokenUsage)
        } else {
            #expect(counts.values.allSatisfy { $0 is NSNull })
        }
        let restored = try #require(try TokenUsageSync.dailyRecord(from: record))
        #expect(restored.hasSameData(as: daily))
        #expect(restored.updatedAt == record["updatedAt"] as? Date)
        record["deviceID"] = "other" as CKRecordValue
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSync.dailyRecord(from: record) }
    }

    @Test func cloudDailyTokenUsageRejectIncompleteKeysAndInvalidQuantities() throws {
        let daily = TokenUsageSyncRecord(deviceID: "device", date: "2026-10-12", tokenUsage: .zero)
        let record = try SyncTestFixtures.tokenUsageRecord(daily)
        let data = try #require(record["tokenUsage"] as? Data)
        var counts = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        counts.removeValue(forKey: "outputTokens")
        record["tokenUsage"] = try JSONSerialization.data(withJSONObject: counts) as CKRecordValue
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSync.dailyRecord(from: record) }
        counts["outputTokens"] = -1
        record["tokenUsage"] = try JSONSerialization.data(withJSONObject: counts) as CKRecordValue
        #expect(throws: StorageCompatibilityError.self) { try TokenUsageSync.dailyRecord(from: record) }
        counts["outputTokens"] = NSNull()
        record["tokenUsage"] = try JSONSerialization.data(withJSONObject: counts) as CKRecordValue
        #expect(try TokenUsageSync.dailyRecord(from: record)?.tokenUsage == nil)
    }
}
