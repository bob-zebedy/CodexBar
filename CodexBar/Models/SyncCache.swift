import Foundation

nonisolated protocol SyncCacheRecord: Codable, Equatable, Identifiable where ID == String {
    var deviceID: String { get }
    var date: String { get }
}

/// 内存按记录 ID 更新, 文件按固定顺序保存数组, 数据与拉取游标共同提交
nonisolated struct SyncCache<Record: SyncCacheRecord, State: Codable & Equatable>: Codable, Equatable {
    static var schemaVersion: Int {
        1
    }

    var schemaVersion = Self.schemaVersion
    var state: State
    var records: [String: Record]
    var cursor: Data?

    init(state: State, records: [String: Record] = [:], cursor: Data? = nil) {
        self.state = state
        self.records = records
        self.cursor = cursor
    }

    var sortedRecords: [Record] {
        records.values.sorted { ($0.deviceID, $0.date, $0.id) < ($1.deviceID, $1.date, $1.id) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else { throw SyncRecovery.Failure.unsupportedCacheVersion }
        state = try container.decode(State.self, forKey: .state)
        let decoded = try container.decode([Record].self, forKey: .records)
        records = [:]
        for record in decoded {
            guard records.updateValue(record, forKey: record.id) == nil else {
                throw DecodingError.dataCorruptedError(forKey: .records, in: container, debugDescription: "Duplicate sync record identity")
            }
        }
        cursor = try container.decodeIfPresent(Data.self, forKey: .cursor)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(state, forKey: .state)
        try container.encode(sortedRecords, forKey: .records)
        try container.encode(cursor, forKey: .cursor)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, state, records, cursor
    }
}
