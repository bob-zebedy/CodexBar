import CloudKit
import Foundation

// MARK: - CloudKit 记录编解码

nonisolated enum ActivityDataRecordCodec {
    static let schemaVersion = 1
    static let metadataSchemaVersion = 1

    enum RecordTypes {
        static let metadata = "Metadata"
        static let activityData = "ActivityData"
    }

    enum FieldKeys {
        static let salt = "salt"
        static let schemaVersion = "schemaVersion"
        static let aggregationVersion = "aggregationVersion"
        static let deviceID = "deviceID"
        static let date = "date"
        static let activityData = "activityData"
        static let updatedAt = "updatedAt"
    }

    static func apply(
        _ aggregate: SyncedActivityData,
        deviceID: String,
        to record: CKRecord
    ) throws {
        record[FieldKeys.schemaVersion] = schemaVersion as CKRecordValue
        record[FieldKeys.aggregationVersion] = aggregate.aggregationVersion as CKRecordValue
        record[FieldKeys.deviceID] = deviceID as CKRecordValue
        record[FieldKeys.date] = aggregate.date as CKRecordValue
        record[FieldKeys.activityData] = try JSONLines.stableEncoder.encode(aggregate.counts) as CKRecordValue
        record[FieldKeys.updatedAt] = Date() as CKRecordValue
    }

    static func remoteDailyRecord(from record: CKRecord) throws -> ActivityDataSyncRecord? {
        guard record.recordType == RecordTypes.activityData else { return nil }
        try StorageVersion.require(optionalIntValue(record[FieldKeys.schemaVersion]) ?? -1, current: schemaVersion, name: "CloudActivityData")
        try AggregationVersion.require(optionalIntValue(record[FieldKeys.aggregationVersion]) ?? -1, current: AggregationVersion.activityData, name: "activityData")
        guard
            let deviceID = record[FieldKeys.deviceID] as? String,
            let date = record[FieldKeys.date] as? String,
            HistoryStorage.isValidDateKey(date) else {
            throw ActivityDataSyncError.invalidRecordIdentity
        }

        guard let activityDataPayload = record[FieldKeys.activityData] as? Data else {
            throw StorageCompatibilityError.incompleteSource
        }
        let activityData = try JSONDecoder().decode(ActivityDataCounts.self, from: activityDataPayload)
        let quantities = [
            activityData.eventCount, activityData.turnStartedCount, activityData.turnCompletedCount, activityData.turnAbortedCount,
            activityData.toolStartedCount, activityData.toolCompletedCount, activityData.approvalRequestedCount,
            activityData.compactionStartedCount, activityData.compactionCompletedCount, activityData.subagentStartedCount,
            activityData.subagentEndedCount, activityData.threadCount, activityData.turnCount
        ]
        guard quantities.compactMap(\.self).allSatisfy({ $0 >= 0 }),
              activityData.projectCounts.values.allSatisfy({ $0 >= 0 }),
              activityData.modelCounts.values.allSatisfy({ $0 >= 0 }) else {
            throw StorageCompatibilityError.incompleteSource
        }
        let aggregate = SyncedActivityData(
            aggregationVersion: optionalIntValue(record[FieldKeys.aggregationVersion]) ?? -1,
            date: date,
            eventCount: activityData.eventCount,
            turnStartedCount: activityData.turnStartedCount,
            turnCompletedCount: activityData.turnCompletedCount,
            turnAbortedCount: activityData.turnAbortedCount,
            toolStartedCount: activityData.toolStartedCount,
            toolCompletedCount: activityData.toolCompletedCount,
            approvalRequestedCount: activityData.approvalRequestedCount,
            compactionStartedCount: activityData.compactionStartedCount,
            compactionCompletedCount: activityData.compactionCompletedCount,
            subagentStartedCount: activityData.subagentStartedCount,
            subagentEndedCount: activityData.subagentEndedCount,
            threadCount: activityData.threadCount,
            turnCount: activityData.turnCount,
            projectCounts: activityData.projectCounts,
            modelCounts: activityData.modelCounts
        )

        return try ActivityDataSyncRecord(
            deviceID: deviceID,
            activityData: aggregate,
            updatedAt: record[FieldKeys.updatedAt] as? Date ?? record.modificationDate,
            recordName: record.recordID.recordName
        )
    }

    static func optionalIntValue(_ value: CKRecordValue?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? Int {
            return value
        }
        return nil
    }

    private struct ActivityDataCounts: Decodable {
        let eventCount: Int?
        let turnStartedCount: Int?
        let turnCompletedCount: Int?
        let turnAbortedCount: Int?
        let toolStartedCount: Int?
        let toolCompletedCount: Int?
        let approvalRequestedCount: Int?
        let compactionStartedCount: Int?
        let compactionCompletedCount: Int?
        let subagentStartedCount: Int?
        let subagentEndedCount: Int?
        let threadCount: Int?
        let turnCount: Int?
        let projectCounts: [String: Int]
        let modelCounts: [String: Int]
    }
}
