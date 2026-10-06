import Foundation

/// State/aggregation.json 的全局状态, pending 表示可增量, dirty 表示需全量重建
nonisolated struct HistoryMaintenanceState: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case version
        case pending
        case dirty
        case days
    }

    /// 原始事件到每日聚合的算法版本, 变化时统一从原始 JSONL 重建
    static let currentVersion = 2

    var version: Int
    var pending: [String]
    var dirty: [String]
    var days: [String: HistoryDayMaintenanceState]

    init(
        version: Int = Self.currentVersion,
        pending: [String] = [],
        dirty: [String] = [],
        days: [String: HistoryDayMaintenanceState] = [:]
    ) {
        self.version = version
        self.pending = Self.normalizedDates(pending)
        self.dirty = Self.normalizedDates(dirty)
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 缺少版本只能说明来源更旧, 不能乐观视为当前算法
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        pending = try Self.normalizedDates(container.decodeIfPresent([String].self, forKey: .pending) ?? [])
        dirty = try Self.normalizedDates(container.decodeIfPresent([String].self, forKey: .dirty) ?? [])
        days = try container.decodeIfPresent([String: HistoryDayMaintenanceState].self, forKey: .days) ?? [:]
    }

    /// 返回状态是否有实际变化, 便于调用方跳过无谓的落盘
    @discardableResult
    mutating func markPending(_ dateKey: String) -> Bool {
        let newPending = Self.inserting(dateKey, into: pending)
        let changed = newPending != pending || days[dateKey] == nil
        pending = newPending
        ensureDayState(for: dateKey)
        return changed
    }

    @discardableResult
    mutating func markDirty(_ dateKey: String) -> Bool {
        markDirty(contentsOf: [dateKey])
    }

    /// 批量标脏一次性归一化, 避免逐个插入的重复排序与校验
    @discardableResult
    mutating func markDirty(contentsOf dateKeys: [String]) -> Bool {
        guard !dateKeys.isEmpty else {
            return false
        }

        let newDirty = Self.normalizedDates(dirty + dateKeys)
        var changed = newDirty != dirty
        dirty = newDirty

        for dateKey in dateKeys where days[dateKey] == nil {
            days[dateKey] = HistoryDayMaintenanceState()
            changed = true
        }

        return changed
    }

    mutating func removePending(_ dateKey: String) {
        pending.removeAll { $0 == dateKey }
    }

    mutating func removeDirty(_ dateKey: String) {
        dirty.removeAll { $0 == dateKey }
    }

    mutating func remove(_ dateKey: String) {
        removePending(dateKey)
        removeDirty(dateKey)
        days.removeValue(forKey: dateKey)
    }

    @discardableResult
    mutating func ensureGenerationID(
        for dateKey: String,
        fileIdentifier: UInt64?
    ) -> Bool {
        var day = days[dateKey] ?? HistoryDayMaintenanceState()
        var changed = false

        if day.generationID == nil {
            day.generationID = Self.makeGenerationID()
            day.generationStartedEmpty = false
            changed = true
        }
        if day.fileIdentifier == nil, let fileIdentifier {
            day.fileIdentifier = fileIdentifier
            changed = true
        }

        days[dateKey] = day
        return changed
    }

    mutating func startNewGeneration(
        for dateKey: String,
        startedEmpty: Bool,
        fileIdentifier: UInt64?
    ) {
        days[dateKey] = HistoryDayMaintenanceState(
            generationID: Self.makeGenerationID(),
            generationStartedEmpty: startedEmpty,
            fileIdentifier: fileIdentifier
        )
        markDirty(dateKey)
    }

    mutating func normalize() -> Bool {
        let previousPending = pending
        let previousDirty = dirty
        let previousDays = days

        pending = Self.normalizedDates(pending)
        dirty = Self.normalizedDates(dirty)
        days = days.filter { HistoryStorage.isValidDateKey($0.key) }

        return previousPending != pending || previousDirty != dirty || previousDays != days
    }

    private mutating func ensureDayState(for dateKey: String) {
        if days[dateKey] == nil {
            days[dateKey] = HistoryDayMaintenanceState()
        }
    }

    private static func inserting(_ dateKey: String, into dates: [String]) -> [String] {
        normalizedDates(dates + [dateKey])
    }

    private static func normalizedDates(_ dates: [String]) -> [String] {
        Set(dates.filter(HistoryStorage.isValidDateKey)).sorted()
    }

    private static func makeGenerationID() -> String {
        UUID().uuidString.lowercased()
    }
}

nonisolated struct HistoryDayMaintenanceState: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case offset
        case size
        case corrupt
        case generationID
        case generationStartedEmpty
        case fileIdentifier
        case boundaryHash
    }

    var offset: UInt64
    var size: UInt64
    var corrupt: Int
    var generationID: String?
    var generationStartedEmpty: Bool
    var fileIdentifier: UInt64?
    var boundaryHash: String?

    init(
        offset: UInt64 = 0,
        size: UInt64 = 0,
        corrupt: Int = 0,
        generationID: String? = nil,
        generationStartedEmpty: Bool = false,
        fileIdentifier: UInt64? = nil,
        boundaryHash: String? = nil
    ) {
        self.offset = offset
        self.size = size
        self.corrupt = corrupt
        self.generationID = generationID
        self.generationStartedEmpty = generationStartedEmpty
        self.fileIdentifier = fileIdentifier
        self.boundaryHash = boundaryHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
        size = try container.decodeIfPresent(UInt64.self, forKey: .size) ?? 0
        corrupt = try container.decodeIfPresent(Int.self, forKey: .corrupt) ?? 0
        generationID = try container.decodeIfPresent(String.self, forKey: .generationID)
        generationStartedEmpty = try container.decodeIfPresent(Bool.self, forKey: .generationStartedEmpty) ?? false
        fileIdentifier = try container.decodeIfPresent(UInt64.self, forKey: .fileIdentifier)
        boundaryHash = try container.decodeIfPresent(String.self, forKey: .boundaryHash)
    }
}
