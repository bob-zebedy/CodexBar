import CloudKit
import Foundation

// MARK: - CloudKit 记录编解码

nonisolated enum ActivityRecordCodec {
    static let version = 1
    static let metadataVersion = 1

    enum RecordTypes {
        static let metadata = "Metadata"
        static let activity = "Activity"
    }

    enum FieldKeys {
        static let salt = "salt"
        static let version = "version"
        static let aggregationVersion = "aggregationVersion"
        static let sourceCheckpoint = "sourceCheckpoint"
        static let deviceID = "deviceID"
        static let date = "date"
        static let generationID = "generationID"
        static let eventCount = "eventCount"
        static let turnStartedCount = "turnStartedCount"
        static let turnCompletedCount = "turnCompletedCount"
        static let turnAbortedCount = "turnAbortedCount"
        static let toolStartedCount = "toolStartedCount"
        static let toolCompletedCount = "toolCompletedCount"
        static let approvalRequestedCount = "approvalRequestedCount"
        static let compactionStartedCount = "compactionStartedCount"
        static let compactionCompletedCount = "compactionCompletedCount"
        static let subagentStartedCount = "subagentStartedCount"
        static let subagentEndedCount = "subagentEndedCount"
        static let threadCount = "threadCount"
        static let turnCount = "turnCount"
        static let projectCounts = "projectCounts"
        static let modelCounts = "modelCounts"
        static let updatedAt = "updatedAt"
    }

    static func apply(
        _ aggregate: SyncedActivity,
        deviceID: String,
        to record: CKRecord
    ) {
        record[FieldKeys.version] = version as CKRecordValue
        record[FieldKeys.aggregationVersion] = aggregate.aggregationVersion as CKRecordValue
        record[FieldKeys.deviceID] = deviceID as CKRecordValue
        record[FieldKeys.date] = aggregate.date as CKRecordValue
        record[FieldKeys.generationID] = aggregate.generationID as CKRecordValue?
        record[FieldKeys.eventCount] = aggregate.eventCount as CKRecordValue?
        record[FieldKeys.turnStartedCount] = aggregate.turnStartedCount as CKRecordValue?
        record[FieldKeys.turnCompletedCount] = aggregate.turnCompletedCount as CKRecordValue?
        record[FieldKeys.turnAbortedCount] = aggregate.turnAbortedCount as CKRecordValue?
        record[FieldKeys.toolStartedCount] = aggregate.toolStartedCount as CKRecordValue?
        record[FieldKeys.toolCompletedCount] = aggregate.toolCompletedCount as CKRecordValue?
        record[FieldKeys.approvalRequestedCount] = aggregate.approvalRequestedCount as CKRecordValue?
        record[FieldKeys.compactionStartedCount] = aggregate.compactionStartedCount as CKRecordValue?
        record[FieldKeys.compactionCompletedCount] = aggregate.compactionCompletedCount as CKRecordValue?
        record[FieldKeys.subagentStartedCount] = aggregate.subagentStartedCount as CKRecordValue?
        record[FieldKeys.subagentEndedCount] = aggregate.subagentEndedCount as CKRecordValue?
        record[FieldKeys.threadCount] = aggregate.threadCount as CKRecordValue?
        record[FieldKeys.turnCount] = aggregate.turnCount as CKRecordValue?
        record[FieldKeys.projectCounts] = countsData(aggregate.projectCounts) as CKRecordValue
        record[FieldKeys.modelCounts] = countsData(aggregate.modelCounts) as CKRecordValue
        record[FieldKeys.sourceCheckpoint] = aggregate.sourceCheckpoint.flatMap { try? JSONLines.stableEncoder.encode($0) } as CKRecordValue?
        record[FieldKeys.updatedAt] = Date() as CKRecordValue
    }

    static func remoteDailyRecord(from record: CKRecord) throws -> ActivitySyncRecord? {
        guard record.recordType == RecordTypes.activity else { return nil }
        try StorageVersion.require(optionalIntValue(record[FieldKeys.version]) ?? -1, current: version, name: "CloudActivity")
        try AggregationVersion.require(optionalIntValue(record[FieldKeys.aggregationVersion]) ?? -1, current: AggregationVersion.activity, name: "Activity")
        guard
            let deviceID = record[FieldKeys.deviceID] as? String,
            let date = record[FieldKeys.date] as? String,
            HistoryStorage.isValidDateKey(date) else {
            throw ActivitySyncError.invalidRecordIdentity
        }

        guard let checkpointData = record[FieldKeys.sourceCheckpoint] as? Data else {
            throw StorageCompatibilityError.incompleteSource
        }
        let checkpoint = try JSONDecoder().decode(ActivitySourceCheckpoint.self, from: checkpointData)
        let aggregate = try SyncedActivity(
            aggregationVersion: optionalIntValue(record[FieldKeys.aggregationVersion]) ?? -1,
            sourceCheckpoint: checkpoint,
            date: date,
            generationID: record[FieldKeys.generationID] as? String,
            eventCount: optionalIntValue(record[FieldKeys.eventCount]),
            turnStartedCount: optionalIntValue(record[FieldKeys.turnStartedCount]),
            turnCompletedCount: optionalIntValue(record[FieldKeys.turnCompletedCount]),
            turnAbortedCount: optionalIntValue(record[FieldKeys.turnAbortedCount]),
            toolStartedCount: optionalIntValue(record[FieldKeys.toolStartedCount]),
            toolCompletedCount: optionalIntValue(record[FieldKeys.toolCompletedCount]),
            approvalRequestedCount: optionalIntValue(record[FieldKeys.approvalRequestedCount]),
            compactionStartedCount: optionalIntValue(record[FieldKeys.compactionStartedCount]),
            compactionCompletedCount: optionalIntValue(record[FieldKeys.compactionCompletedCount]),
            subagentStartedCount: optionalIntValue(record[FieldKeys.subagentStartedCount]),
            subagentEndedCount: optionalIntValue(record[FieldKeys.subagentEndedCount]),
            threadCount: optionalIntValue(record[FieldKeys.threadCount]),
            turnCount: optionalIntValue(record[FieldKeys.turnCount]),
            projectCounts: counts(from: record[FieldKeys.projectCounts]),
            modelCounts: counts(from: record[FieldKeys.modelCounts])
        )

        return try ActivitySyncRecord(
            deviceID: deviceID,
            daily: aggregate,
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

    static func counts(from value: CKRecordValue?) throws -> [String: Int] {
        guard let data = value as? Data else { throw StorageCompatibilityError.incompleteSource }
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        guard counts.values.allSatisfy({ $0 >= 0 }) else { throw StorageCompatibilityError.incompleteSource }
        return counts
    }

    static func countsData(_ counts: [String: Int]) -> Data {
        (try? JSONLines.stableEncoder.encode(counts)) ?? Data("{}".utf8)
    }
}
