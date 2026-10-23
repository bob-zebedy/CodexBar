import CloudKit
import Foundation

nonisolated struct ActivityDataSyncStore {
    let directoryURL: URL

    private var cacheURL: URL {
        AppStorage(rootURL: directoryURL).activityDataSyncCacheURL
    }

    private var lockURL: URL {
        AppStorage(rootURL: directoryURL).lockURL(.activityDataSyncCache)
    }

    func load() throws -> ActivityDataSyncCache {
        try JSONFileStorage.withLock(at: lockURL) { try read() }
    }

    func loadState() -> ActivityDataSyncState {
        (try? load().state) ?? ActivityDataSyncState()
    }

    func saveState(_ state: ActivityDataSyncState) throws {
        try update { $0.state = state }
    }

    func saveConfirmedRecords(_ records: [ActivityDataSyncRecord], lastUploadAt: Date?) throws {
        try update { cache in
            for record in records {
                cache.records[record.id] = record
            }
            if let lastUploadAt {
                cache.state.lastUploadAt = lastUploadAt
            }
        }
    }

    /// 数据和对应游标必须一起提交, 不能让新游标指向尚未保存的数据
    func saveFetchedRecords(_ activityData: [String: ActivityDataSyncRecord], cursor: CKServerChangeToken?) throws {
        let data = try cursor.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        try update {
            $0.records = activityData
            $0.cursor = data
        }
    }

    func reset(state: ActivityDataSyncState) throws {
        try update { $0 = ActivityDataSyncCache(state: state) }
    }

    func prune(now: Date) throws {
        try JSONFileStorage.withLock(at: lockURL) {
            var cache = try read()
            if cache.prune(now: now) {
                try JSONFileStorage.save(cache, to: cacheURL)
            }
        }
    }

    private func read() throws -> ActivityDataSyncCache {
        let cache: ActivityDataSyncCache
        do {
            guard let data = try readData() else { return ActivityDataSyncCache(state: ActivityDataSyncState()) }
            cache = try JSONLines.decoder.decode(ActivityDataSyncCache.self, from: data)
        } catch is DecodingError {
            // 损坏时整体失效, 不保留脱离缓存数据的游标
            return ActivityDataSyncCache(state: ActivityDataSyncState())
        }
        guard cache.state.containerIdentifier == SyncCloudKit.containerIdentifier else { return ActivityDataSyncCache(state: ActivityDataSyncState()) }
        return cache
    }

    private func readData() throws -> Data? {
        do {
            return try Data(contentsOf: cacheURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func update(_ body: (inout ActivityDataSyncCache) throws -> Void) throws {
        try JSONFileStorage.withLock(at: lockURL) {
            var cache = try read()
            try body(&cache)
            cache.prune()
            try JSONFileStorage.save(cache, to: cacheURL)
        }
    }
}

typealias ActivityDataSyncCache = SyncCache<ActivityDataSyncRecord, ActivityDataSyncState>

nonisolated extension SyncCache where Record == ActivityDataSyncRecord, State == ActivityDataSyncState {
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let cutoff = HistoryStorage.dateKey(for: HistoryStorage.retentionCutoffDate(today: now))
        let previousCount = records.count
        records = records.filter { $0.value.date >= cutoff }
        return previousCount != records.count
    }
}

nonisolated struct ActivityDataSyncState: Codable, Equatable {
    var containerIdentifier: String?
    var deviceID: String?
    var lastUploadAt: Date?
    var lastPrunedDate: String?

    init(
        containerIdentifier: String? = SyncCloudKit.containerIdentifier,
        deviceID: String? = nil,
        lastUploadAt: Date? = nil,
        lastPrunedDate: String? = nil
    ) {
        self.containerIdentifier = containerIdentifier
        self.deviceID = deviceID
        self.lastUploadAt = lastUploadAt
        self.lastPrunedDate = lastPrunedDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        containerIdentifier = try container.decodeIfPresent(String.self, forKey: .containerIdentifier)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        lastUploadAt = try container.decodeIfPresent(Date.self, forKey: .lastUploadAt)
        lastPrunedDate = try container.decodeIfPresent(String.self, forKey: .lastPrunedDate)
    }

    private enum CodingKeys: String, CodingKey {
        case containerIdentifier
        case deviceID
        case lastUploadAt
        case lastPrunedDate
    }
}
