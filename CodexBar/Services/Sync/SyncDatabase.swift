import CloudKit

/// 仅封装同步实际使用的操作, 测试可以注入局部失败而不连接 iCloud
nonisolated protocol SyncDatabase: Sendable {
    typealias Records = [CKRecord.ID: Result<CKRecord, Error>]
    typealias Modification = (saveResults: Records, deleteResults: [CKRecord.ID: Result<Void, Error>])
    typealias QueryPage = (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
    typealias ZoneModification = (saveResults: [CKRecordZone.ID: Result<CKRecordZone, Error>], deleteResults: [CKRecordZone.ID: Result<Void, Error>])

    func records(for ids: [CKRecord.ID], desiredKeys: [CKRecord.FieldKey]?) async throws -> Records
    func modifyRecords(saving records: [CKRecord], deleting ids: [CKRecord.ID], savePolicy: CKModifyRecordsOperation.RecordSavePolicy, atomically: Bool) async throws -> Modification
    func records(matching query: CKQuery, inZoneWith zone: CKRecordZone.ID?, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> QueryPage
    func records(continuingMatchFrom cursor: CKQueryOperation.Cursor, desiredKeys: [CKRecord.FieldKey]?, resultsLimit: Int) async throws -> QueryPage
    func recordZone(for id: CKRecordZone.ID) async throws -> CKRecordZone
    func modifyRecordZones(saving zones: [CKRecordZone], deleting ids: [CKRecordZone.ID]) async throws -> ZoneModification
    func fetchChanges(inZoneWith zone: CKRecordZone.ID, since token: CKServerChangeToken?, resultsLimit: Int) async throws -> SyncChanges
}

nonisolated struct SyncChanges: Sendable {
    let records: SyncDatabase.Records
    let deletions: [(id: CKRecord.ID, type: String)]
    let token: CKServerChangeToken?
    let moreComing: Bool
}

extension CKDatabase: SyncDatabase {
    nonisolated func fetchChanges(inZoneWith zone: CKRecordZone.ID, since token: CKServerChangeToken?, resultsLimit: Int) async throws -> SyncChanges {
        let changes = try await recordZoneChanges(inZoneWith: zone, since: token, desiredKeys: nil, resultsLimit: resultsLimit)
        return SyncChanges(
            records: changes.modificationResultsByID.mapValues { $0.map(\.record) },
            deletions: changes.deletions.map { ($0.recordID, $0.recordType) },
            token: changes.changeToken, moreComing: changes.moreComing
        )
    }
}
