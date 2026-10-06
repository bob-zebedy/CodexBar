import CloudKit
import Foundation

// MARK: - CloudKit 记录编解码

nonisolated enum ActivityRecordCodec {
    static let version = 1

    enum RecordTypes {
        static let metadata = "Metadata"
        static let activity = "Activity"
    }

    enum FieldKeys {
        static let salt = "salt"
        static let version = "version"
        static let deviceID = "deviceID"
        static let date = "date"
        static let generationID = "generationID"
        static let eventCount = "eventCount"
        static let sessionStartedCount = "sessionStartedCount"
        static let sessionEndedCount = "sessionEndedCount"
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
        static let sessionCount = "sessionCount"
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
        record[FieldKeys.deviceID] = deviceID as CKRecordValue
        record[FieldKeys.date] = aggregate.date as CKRecordValue
        record[FieldKeys.generationID] = aggregate.generationID as CKRecordValue?
        record[FieldKeys.eventCount] = aggregate.eventCount as CKRecordValue?
        record[FieldKeys.sessionStartedCount] = aggregate.sessionStartedCount as CKRecordValue?
        record[FieldKeys.sessionEndedCount] = aggregate.sessionEndedCount as CKRecordValue?
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
        record[FieldKeys.sessionCount] = aggregate.sessionCount as CKRecordValue?
        record[FieldKeys.turnCount] = aggregate.turnCount as CKRecordValue?
        record[FieldKeys.projectCounts] = countsData(aggregate.projectCounts) as CKRecordValue
        record[FieldKeys.modelCounts] = countsData(aggregate.modelCounts) as CKRecordValue
        record[FieldKeys.updatedAt] = Date() as CKRecordValue
    }

    static func remoteDailyRecord(from record: CKRecord) throws -> ActivitySyncRecord? {
        guard record.recordType == RecordTypes.activity,
              let deviceID = record[FieldKeys.deviceID] as? String,
              let date = record[FieldKeys.date] as? String,
              HistoryStorage.isValidDateKey(date) else {
            return nil
        }

        let aggregate = SyncedActivity(
            date: date,
            generationID: record[FieldKeys.generationID] as? String,
            eventCount: optionalIntValue(record[FieldKeys.eventCount]),
            sessionStartedCount: optionalIntValue(record[FieldKeys.sessionStartedCount]),
            sessionEndedCount: optionalIntValue(record[FieldKeys.sessionEndedCount]),
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
            sessionCount: optionalIntValue(record[FieldKeys.sessionCount]),
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

    static func counts(from value: CKRecordValue?) -> [String: Int] {
        guard let data = value as? Data,
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return counts
    }

    static func countsData(_ counts: [String: Int]) -> Data {
        (try? JSONLines.stableEncoder.encode(counts)) ?? Data("{}".utf8)
    }
}
