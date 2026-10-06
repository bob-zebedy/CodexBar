import CloudKit
import Foundation

nonisolated struct ActivitySyncStore {
    let directoryURL: URL

    private var cacheDirectoryURL: URL {
        directoryURL.appendingPathComponent("Activity", isDirectory: true)
    }

    private var cacheURL: URL {
        cacheDirectoryURL.appendingPathComponent("cache.json", isDirectory: false)
    }

    func load() throws -> ActivitySyncCache {
        try JSONFileStorage.withLock(in: cacheDirectoryURL) { try read() }
    }

    func loadState() -> SyncState {
        (try? load().state) ?? SyncState()
    }

    func saveState(_ state: SyncState) throws {
        try update { $0.state = state }
    }

    func loadCachedRecords() -> [ActivitySyncRecord] {
        (try? load().records) ?? []
    }

    func saveCachedRecords(_ records: [ActivitySyncRecord], state: SyncState) throws {
        try update {
            $0.records = Self.sorted(records)
            $0.state = state
        }
    }

    /// 数据和对应游标必须一起提交, 不能让新游标指向尚未保存的数据
    func saveFetchedRecords(_ records: [ActivitySyncRecord], cursor: CKServerChangeToken?) throws {
        let data = try cursor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        try update {
            $0.records = Self.sorted(records)
            $0.cursor = data
        }
    }

    func removeCursorIfPresent() throws {
        try update { $0.cursor = nil }
    }

    func reset(state: SyncState) throws {
        try update { $0 = ActivitySyncCache(state: state) }
    }

    private func read() throws -> ActivitySyncCache {
        let cache: ActivitySyncCache
        do {
            guard let data = try readData() else { return ActivitySyncCache() }
            let header = try JSONLines.decoder.decode(ActivitySyncCacheHeader.self, from: data)
            guard header.version == ActivitySyncCache.currentVersion else { throw SyncRecovery.Failure.unsupportedCacheVersion }
            cache = try JSONLines.decoder.decode(ActivitySyncCache.self, from: data)
        } catch is DecodingError {
            // 损坏时整体失效, 不保留脱离缓存数据的游标或上传摘要
            return ActivitySyncCache()
        }
        guard cache.state.containerIdentifier == SyncCloudKit.containerIdentifier else { return ActivitySyncCache() }
        return cache
    }

    private func readData() throws -> Data? {
        do {
            return try Data(contentsOf: cacheURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func update(_ body: (inout ActivitySyncCache) throws -> Void) throws {
        try JSONFileStorage.withLock(in: cacheDirectoryURL) {
            var cache = try read()
            try body(&cache)
            try JSONFileStorage.save(cache, to: cacheURL)
        }
    }

    private static func sorted(_ records: [ActivitySyncRecord]) -> [ActivitySyncRecord] {
        records.sorted { ($0.deviceID, $0.date, $0.id) < ($1.deviceID, $1.date, $1.id) }
    }
}

private nonisolated struct ActivitySyncCacheHeader: Decodable { let version: Int }

nonisolated struct ActivitySyncCache: Codable, Equatable {
    static let currentVersion = 1
    var version = currentVersion
    var state = SyncState()
    var records: [ActivitySyncRecord] = []
    var cursor: Data?
}

nonisolated struct SyncState: Codable, Equatable {
    var containerIdentifier: String?
    var deviceID: String?
    var hashByDate: [String: String]
    var replacementDates: [String]
    var lastUploadAt: Date?
    var lastPrunedDate: String?

    init(
        containerIdentifier: String? = SyncCloudKit.containerIdentifier,
        deviceID: String? = nil,
        hashByDate: [String: String] = [:],
        replacementDates: [String] = [],
        lastUploadAt: Date? = nil,
        lastPrunedDate: String? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.deviceID = deviceID
        self.hashByDate = hashByDate
        self.replacementDates = replacementDates
        self.lastUploadAt = lastUploadAt
        self.lastPrunedDate = lastPrunedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        containerIdentifier = try container.decodeIfPresent(String.self, forKey: .containerIdentifier)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        hashByDate = try container.decodeIfPresent([String: String].self, forKey: .hashByDate)
            ?? [:]
        let decodedReplacementDates = try container.decodeIfPresent(
            [String].self,
            forKey: .replacementDates
        ) ?? []
        replacementDates = Set(
            decodedReplacementDates.filter(HistoryStorage.isValidDateKey)
        ).sorted()
        lastUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastUploadAt)
        lastPrunedDate = try container.decodeIfPresent(String.self, forKey: .lastPrunedDate)
    }

    private enum CodingKeys: String, CodingKey {
        case containerIdentifier
        case deviceID
        case hashByDate
        case replacementDates
        case lastUploadAt
        case lastPrunedDate
    }
}
