import Foundation

nonisolated struct SyncedActivityData: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var aggregationVersion = AggregationVersion.activityData

    let date: String
    var eventCount: Int?
    var turnStartedCount: Int?
    var turnCompletedCount: Int?
    var turnAbortedCount: Int?
    var toolStartedCount: Int?
    var toolCompletedCount: Int?
    var approvalRequestedCount: Int?
    var compactionStartedCount: Int?
    var compactionCompletedCount: Int?
    var subagentStartedCount: Int?
    var subagentEndedCount: Int?
    var threadCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var modelCounts: [String: Int]

    var metrics: ActivityDataMetrics {
        ActivityDataMetrics(
            startDate: date,
            threadCount: threadCount,
            turnCount: turnCount,
            toolStartedCount: toolStartedCount ?? 0,
            toolCompletedCount: toolCompletedCount ?? 0,
            approvalRequestedCount: approvalRequestedCount ?? 0,
            compactionStartedCount: compactionStartedCount ?? 0,
            compactionCompletedCount: compactionCompletedCount ?? 0,
            subagentStartedCount: subagentStartedCount ?? 0,
            subagentEndedCount: subagentEndedCount ?? 0,
            modelCounts: modelCounts,
            turnAbortedCount: turnAbortedCount ?? 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, aggregationVersion
        case date
        case eventCount
        case turnStartedCount
        case turnCompletedCount
        case turnAbortedCount
        case toolStartedCount
        case toolCompletedCount
        case approvalRequestedCount
        case compactionStartedCount
        case compactionCompletedCount
        case subagentStartedCount
        case subagentEndedCount
        case threadCount
        case turnCount
        case projectCounts
        case modelCounts
    }
}

extension SyncedActivityData {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            aggregationVersion: container.decode(Int.self, forKey: .aggregationVersion),
            date: container.decode(String.self, forKey: .date), countsFrom: decoder
        )
    }

    nonisolated init(schemaVersion: Int, aggregationVersion: Int, date: String, countsFrom decoder: Decoder) throws {
        self.schemaVersion = schemaVersion
        try StorageVersion.require(schemaVersion, current: Self.schemaVersion, name: "ActivityDataAggregate")
        self.aggregationVersion = aggregationVersion
        try AggregationVersion.require(aggregationVersion, current: AggregationVersion.activityData, name: "activityData")
        self.date = date
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
        turnStartedCount = try container.decodeIfPresent(Int.self, forKey: .turnStartedCount)
        turnCompletedCount = try container.decodeIfPresent(Int.self, forKey: .turnCompletedCount)
        turnAbortedCount = try container.decodeIfPresent(Int.self, forKey: .turnAbortedCount)
        toolStartedCount = try container.decodeIfPresent(Int.self, forKey: .toolStartedCount)
        toolCompletedCount = try container.decodeIfPresent(Int.self, forKey: .toolCompletedCount)
        approvalRequestedCount = try container.decodeIfPresent(Int.self, forKey: .approvalRequestedCount)
        compactionStartedCount = try container.decodeIfPresent(Int.self, forKey: .compactionStartedCount)
        compactionCompletedCount = try container.decodeIfPresent(Int.self, forKey: .compactionCompletedCount)
        subagentStartedCount = try container.decodeIfPresent(Int.self, forKey: .subagentStartedCount)
        subagentEndedCount = try container.decodeIfPresent(Int.self, forKey: .subagentEndedCount)
        threadCount = try container.decodeIfPresent(Int.self, forKey: .threadCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
    }
}

nonisolated extension SyncedActivityData {
    func encodeCounts(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventCount, forKey: .eventCount)
        try container.encode(turnStartedCount, forKey: .turnStartedCount)
        try container.encode(turnCompletedCount, forKey: .turnCompletedCount)
        try container.encode(turnAbortedCount, forKey: .turnAbortedCount)
        try container.encode(toolStartedCount, forKey: .toolStartedCount)
        try container.encode(toolCompletedCount, forKey: .toolCompletedCount)
        try container.encode(approvalRequestedCount, forKey: .approvalRequestedCount)
        try container.encode(compactionStartedCount, forKey: .compactionStartedCount)
        try container.encode(compactionCompletedCount, forKey: .compactionCompletedCount)
        try container.encode(subagentStartedCount, forKey: .subagentStartedCount)
        try container.encode(subagentEndedCount, forKey: .subagentEndedCount)
        try container.encode(threadCount, forKey: .threadCount)
        try container.encode(turnCount, forKey: .turnCount)
        try container.encode(projectCounts, forKey: .projectCounts)
        try container.encode(modelCounts, forKey: .modelCounts)
    }

    var counts: some Encodable {
        Counts(aggregate: self)
    }

    private struct Counts: Encodable {
        let aggregate: SyncedActivityData

        func encode(to encoder: Encoder) throws {
            try aggregate.encodeCounts(to: encoder)
        }
    }
}

nonisolated struct ActivityDataSyncRecord: SyncCacheRecord {
    let deviceID: String
    let activityData: SyncedActivityData
    var updatedAt: Date?
    let recordName: String

    var id: String {
        recordName
    }

    var date: String {
        activityData.date
    }

    init(deviceID: String, activityData: SyncedActivityData, updatedAt: Date? = nil, recordName: String) throws {
        guard !deviceID.isEmpty, HistoryStorage.isValidDateKey(activityData.date),
              recordName == Self.recordName(deviceID: deviceID, date: activityData.date) else {
            throw ActivityDataSyncError.invalidRecordIdentity
        }
        self.deviceID = deviceID
        self.activityData = activityData
        self.updatedAt = updatedAt
        self.recordName = recordName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                deviceID: container.decode(String.self, forKey: .deviceID),
                activityData: SyncedActivityData(
                    schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
                    aggregationVersion: container.decode(Int.self, forKey: .aggregationVersion),
                    date: container.decode(String.self, forKey: .date),
                    countsFrom: container.superDecoder(forKey: .activityData)
                ),
                updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt),
                recordName: container.decode(String.self, forKey: .recordName)
            )
        } catch let error as ActivityDataSyncError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid activity record identity",
                underlyingError: error
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activityData.schemaVersion, forKey: .schemaVersion)
        try container.encode(activityData.aggregationVersion, forKey: .aggregationVersion)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(date, forKey: .date)
        try container.encode(recordName, forKey: .recordName)
        try container.encode(updatedAt, forKey: .updatedAt)
        try activityData.encodeCounts(to: container.superEncoder(forKey: .activityData))
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, aggregationVersion, deviceID, date, recordName, updatedAt, activityData
    }

    static func recordName(deviceID: String, date: String) -> String {
        "activityData_\(deviceID)_\(date)"
    }
}

nonisolated enum ActivityDataSyncError: LocalizedError {
    case invalidRecordIdentity

    var errorDescription: String? {
        switch self {
        case .invalidRecordIdentity:
            String(localized: "sync.error.activity-data-identity")
        }
    }
}
