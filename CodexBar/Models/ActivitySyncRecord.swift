import Foundation

nonisolated struct SyncedActivity: Codable, Equatable {
    let date: String
    var generationID: String?
    var eventCount: Int?
    var sessionStartedCount: Int?
    var sessionEndedCount: Int?
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
    var sessionCount: Int?
    var turnCount: Int?
    var projectCounts: [String: Int]
    var modelCounts: [String: Int]

    var metrics: ActivityMetrics {
        ActivityMetrics(
            startDate: date,
            sessionCount: CountResolution.resolvedCount(
                compactedCount: sessionCount,
                fallback: sessionStartedCount ?? 0
            ),
            turnCount: CountResolution.resolvedCount(
                compactedCount: turnCount,
                fallback: turnCompletedCount ?? 0
            ),
            toolStartedCount: toolStartedCount ?? 0,
            toolCompletedCount: toolCompletedCount ?? 0,
            approvalRequestedCount: approvalRequestedCount ?? 0,
            compactionStartedCount: compactionStartedCount ?? 0,
            compactionCompletedCount: compactionCompletedCount ?? 0,
            subagentStartedCount: subagentStartedCount ?? 0,
            subagentEndedCount: subagentEndedCount ?? 0,
            modelCounts: modelCounts,
            turnAbortedCount: turnAbortedCount
        )
    }

    func jsonLineData() throws -> Data {
        try JSONLines.stableEncoder.encode(self) + Data([JSONLines.newlineByte])
    }

    func requiredGenerationID() throws -> String {
        guard let generationID, !generationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ActivitySyncError.missingGeneration(date)
        }
        return generationID
    }

    func matchesRemoteSource(_ remote: SyncedActivity) -> Bool {
        generationID != nil && generationID == remote.generationID
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case generationID
        case eventCount
        case sessionStartedCount
        case sessionEndedCount
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
        case sessionCount
        case turnCount
        case projectCounts
        case modelCounts
    }
}

extension SyncedActivity {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        generationID = try container.decodeIfPresent(String.self, forKey: .generationID)
        eventCount = try container.decodeIfPresent(Int.self, forKey: .eventCount)
        sessionStartedCount = try container.decodeIfPresent(Int.self, forKey: .sessionStartedCount)
        sessionEndedCount = try container.decodeIfPresent(Int.self, forKey: .sessionEndedCount)
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
        sessionCount = try container.decodeIfPresent(Int.self, forKey: .sessionCount)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount)
        projectCounts = try container.decodeIfPresent([String: Int].self, forKey: .projectCounts) ?? [:]
        modelCounts = try container.decodeIfPresent([String: Int].self, forKey: .modelCounts) ?? [:]
    }
}

nonisolated struct ActivitySyncRecord: Codable, Equatable, Identifiable {
    let deviceID: String
    let daily: SyncedActivity
    var updatedAt: Date?
    let recordName: String

    var id: String {
        recordName
    }

    var date: String {
        daily.date
    }

    init(deviceID: String, daily: SyncedActivity, updatedAt: Date? = nil, recordName: String) throws {
        let generation = try daily.requiredGenerationID()
        guard recordName == Self.recordName(deviceID: deviceID, date: daily.date, generation: generation) else {
            throw ActivitySyncError.invalidRecordIdentity
        }
        self.deviceID = deviceID
        self.daily = daily
        self.updatedAt = updatedAt
        self.recordName = recordName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                deviceID: container.decode(String.self, forKey: .deviceID),
                daily: container.decode(SyncedActivity.self, forKey: .daily),
                updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt),
                recordName: container.decode(String.self, forKey: .recordName)
            )
        } catch let error as ActivitySyncError {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid activity record identity",
                underlyingError: error
            ))
        }
    }

    static func recordName(deviceID: String, date: String, generation: String) -> String {
        "\(deviceID)_\(date)_\(generation)"
    }
}

nonisolated enum ActivitySyncError: LocalizedError {
    case missingGeneration(String)
    case invalidRecordIdentity

    var errorDescription: String? {
        switch self {
        case let .missingGeneration(date):
            String(localized: "sync.error.activity-generation", defaultValue: "\(date)")
        case .invalidRecordIdentity:
            String(localized: "sync.error.activity-identity")
        }
    }
}
