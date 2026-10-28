import CloudKit
import Foundation

enum SyncTestFixtures {
    static let zone = CKRecordZone.ID(zoneName: SyncCloudKit.zoneName, ownerName: CKCurrentUserDefaultName)

    static func activityDataEventCount(_ record: CKRecord?) throws -> Int? {
        guard let record else { return nil }
        return try ActivityDataRecordCodec.remoteDailyRecord(from: record)?.activityData.eventCount
    }

    static func counts(_ input: Int64) -> TokenUsage {
        TokenUsage(inputTokens: input, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: input)
    }

    static func tokenUsageRecord(_ daily: TokenUsageSyncRecord) throws -> CKRecord {
        let record = CKRecord(recordType: TokenUsageSync.recordType, recordID: TokenUsageSync.recordID(daily.id, zoneID: zone))
        try TokenUsageSync.apply(daily, to: record)
        return record
    }
}

actor SyncDatabaseFixture: SyncDatabase {
    private var stored: [CKRecord.ID: CKRecord] = [:]
    private var nextChangesError: CKError.Code?
    private let changesFail: Bool
    private var changesRecordFails = false
    private var changesPages: [Result<SyncChanges, Error>] = []

    private var failingName: String?
    private var failingDate: String?
    private var omittedReadName: String?
    private let readFailure: Bool
    private let uploadFailure: CKError.Code
    private(set) var queryCount = 0
    private(set) var changesSinceNil: [Bool] = []
    private(set) var savedTypes: [String] = []
    private(set) var requestedIDs: [CKRecord.ID] = []
    private(set) var deletedIDs: [CKRecord.ID] = []
    private var changesRecord: CKRecord?
    private var deletionFails = false

    var remainingChangesPages: Int {
        changesPages.count
    }

    func setChangesPages(_ pages: [Result<SyncChanges, Error>]) {
        changesPages = pages
    }

    func failNextDeletion() {
        deletionFails = true
    }

    func failActivityDataUpload(on date: String) {
        failingDate = date
    }

    func activityDataRecords() -> [CKRecord] {
        stored.values.filter { $0.recordType == "ActivityData" }.map(Self.copy)
    }

    func removeRecord(_ id: CKRecord.ID) {
        stored[id] = nil
    }

    func storeRecord(_ record: CKRecord) {
        stored[record.recordID] = Self.copy(record)
    }

    func injectChangesRecord(_ record: CKRecord) {
        changesRecord = Self.copy(record)
    }

    init(nextChangesError: CKError.Code? = nil, changesFail: Bool = false, failingName: String? = nil, failingDate: String? = nil, readFailure: Bool = false, uploadFailure: CKError.Code = .constraintViolation) {
        self.nextChangesError = nextChangesError
        self.changesFail = changesFail
        self.failingName = failingName
        self.failingDate = failingDate
        self.readFailure = readFailure
        self.uploadFailure = uploadFailure
    }

    private nonisolated static func copy(_ record: CKRecord) -> CKRecord {
        record.copy() as? CKRecord ?? record
    }

    func failChangesRecord() {
        changesRecordFails = true
    }

    func omitReadResult(named name: String) {
        omittedReadName = name
    }

    func repair() {
        failingName = nil
        failingDate = nil
        omittedReadName = nil
    }

    func records(for ids: [CKRecord.ID], desiredKeys _: [CKRecord.FieldKey]?) async throws -> Records {
        requestedIDs.append(contentsOf: ids)
        return Dictionary(uniqueKeysWithValues: ids.filter { $0.recordName != omittedReadName }.map { id in
            if readFailure, id.recordName == failingName {
                return (id, .failure(CKError(.constraintViolation)))
            }
            return (id, stored[id].map { .success(Self.copy($0)) } ?? .failure(CKError(.unknownItem)))
        })
    }

    func modifyRecords(
        saving records: [CKRecord],
        deleting ids: [CKRecord.ID],
        savePolicy _: CKModifyRecordsOperation.RecordSavePolicy,
        atomically _: Bool
    ) async throws -> Modification {
        var saved: Records = [:]
        for record in records {
            if record.recordID.recordName == failingName || (record.recordType == "ActivityData" && failingDate != nil && record["date"] as? String == failingDate) {
                saved[record.recordID] = .failure(CKError(uploadFailure))
            } else {
                stored[record.recordID] = record.copy() as? CKRecord
                saved[record.recordID] = .success(record)
                savedTypes.append(record.recordType)
            }
        }
        deletedIDs.append(contentsOf: ids)
        for id in ids {
            stored[id] = nil
            if deletionFails {
                deletionFails = false
                throw CKError(.networkFailure)
            }
        }
        return (saved, Dictionary(uniqueKeysWithValues: ids.map { ($0, .success(())) }))
    }

    func records(matching query: CKQuery, inZoneWith _: CKRecordZone.ID?, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        queryCount += 1
        return (stored.values.filter { $0.recordType == query.recordType }.map { ($0.recordID, .success(Self.copy($0))) }, nil)
    }

    func records(continuingMatchFrom _: CKQueryOperation.Cursor, desiredKeys _: [CKRecord.FieldKey]?, resultsLimit _: Int) async throws -> QueryPage {
        ([], nil)
    }

    func recordZone(for id: CKRecordZone.ID) async throws -> CKRecordZone {
        CKRecordZone(zoneID: id)
    }

    func modifyRecordZones(saving zones: [CKRecordZone], deleting _: [CKRecordZone.ID]) async throws -> ZoneModification {
        (Dictionary(uniqueKeysWithValues: zones.map { ($0.zoneID, .success($0)) }), [:])
    }

    func fetchChanges(inZoneWith _: CKRecordZone.ID, since token: CKServerChangeToken?, resultsLimit _: Int) async throws -> SyncChanges {
        changesSinceNil.append(token == nil)
        if !changesPages.isEmpty {
            return try changesPages.removeFirst().get()
        }
        if let error = nextChangesError {
            nextChangesError = nil
            throw CKError(error)
        }
        if changesFail {
            throw CKError(.networkFailure)
        }
        var records = stored.mapValues { Result<CKRecord, Error>.success(Self.copy($0)) }
        if let changesRecord {
            records[changesRecord.recordID] = .success(Self.copy(changesRecord))
        }
        if changesRecordFails {
            records[CKRecord.ID(recordName: "failed-record")] = .failure(CKError(.constraintViolation))
        }
        return SyncChanges(records: records, deletions: [], token: nil, moreComing: false)
    }
}
