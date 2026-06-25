import Combine
import Darwin
import Foundation

actor WorkflowStatsService {
    private let eventsDirectoryURL: URL
    private let dailyLogURL: URL
    private static let eventReadChunkSize = 64 * 1024

    init(
        eventsDirectoryURL: URL = WorkflowStatsStorage.eventsDirectoryURL(),
        dailyLogURL: URL = WorkflowStatsStorage.dailyURL()
    ) {
        self.eventsDirectoryURL = eventsDirectoryURL
        self.dailyLogURL = dailyLogURL
    }

    func loadSnapshot(performMaintenance: Bool = false) -> WorkflowStatsSnapshot {
        if performMaintenance {
            performMaintenanceIfNeeded()
        }

        if let aggregates = loadDailyAggregates(), !aggregates.isEmpty {
            return WorkflowStatsSnapshot(dailyAggregates: aggregates)
        }

        return .empty
    }

    private func loadDailyAggregates() -> [WorkflowDailyAggregate]? {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return nil
        }

        let aggregates = WorkflowDailyAggregate.decodeJSONLines(from: data)
        guard !aggregates.isEmpty else {
            return nil
        }

        return WorkflowDailyAggregate.normalized(aggregates: aggregates)
    }

    private func performMaintenanceIfNeeded() {
        do {
            let tasks = try prepareMaintenanceTasks()
            guard !tasks.isEmpty else {
                return
            }

            for task in tasks {
                do {
                    let result = try buildDailyAggregate(for: task)
                    try commit(result)
                } catch {
                    markDirty(task.dateKey)
                }
            }

            try pruneExpiredEventFiles()
        } catch {
            return
        }
    }

    private func prepareMaintenanceTasks() throws -> [WorkflowStatsMaintenanceTask] {
        let eventDateKeys = eventDateKeys()
        let dailyDecodeResult = loadDailyAggregatesWithFailures()

        return try WorkflowStatsStorage.withExclusiveLock {
            var state = WorkflowStatsStorage.loadMaintenanceState()
            var changedState = state.normalize()
            let dailyByDate = dailyDecodeResult.values.reduce(into: [String: WorkflowDailyAggregate]()) { result, aggregate in
                result[aggregate.date] = aggregate
            }

            let changedByRebuild = markRebuildDates(
                eventDateKeys: eventDateKeys,
                dailyDecodeResult: dailyDecodeResult,
                dailyByDate: dailyByDate,
                state: &state
            )
            let changedByReconcile = reconcileEventFiles(eventDateKeys: eventDateKeys, state: &state)
            changedState = changedState || changedByRebuild || changedByReconcile

            let tasks = makeMaintenanceTasks(
                state: &state,
                dailyByDate: dailyByDate,
                changedState: &changedState
            )

            if changedState {
                try WorkflowStatsStorage.saveMaintenanceState(state)
            }

            return tasks
        }
    }

    private func markRebuildDates(
        eventDateKeys: [String],
        dailyDecodeResult: JSONLinesDecodeResult<WorkflowDailyAggregate>,
        dailyByDate: [String: WorkflowDailyAggregate],
        state: inout WorkflowStatsMaintenanceState
    ) -> Bool {
        var changed = false

        if state.schema != WorkflowStatsMaintenanceState.currentSchema {
            changed = markDirty(eventDateKeys, in: &state) || changed
            state.schema = WorkflowStatsMaintenanceState.currentSchema
            changed = true
        }

        if dailyDecodeResult.failedLineCount > 0 || (dailyDecodeResult.values.isEmpty && !eventDateKeys.isEmpty) {
            changed = markDirty(eventDateKeys, in: &state) || changed
        }

        changed = markDirty(eventDateKeys.filter { dailyByDate[$0] == nil }, in: &state) || changed
        changed = markDirty(state.pending.filter { dailyByDate[$0] == nil }, in: &state) || changed

        return changed
    }

    private func reconcileEventFiles(
        eventDateKeys: [String],
        state: inout WorkflowStatsMaintenanceState
    ) -> Bool {
        var changed = markDirty(eventDateKeys.filter { state.days[$0] == nil }, in: &state)

        for (dateKey, day) in state.days {
            let actualSize = eventLogSize(for: dateKey)
            if actualSize < day.offset || day.offset != day.size {
                state.markDirty(dateKey)
                changed = true
            } else if actualSize > day.offset,
                      !state.pending.contains(dateKey),
                      !state.dirty.contains(dateKey) {
                state.markPending(dateKey)
                changed = true
            }
        }

        return changed
    }

    private func makeMaintenanceTasks(
        state: inout WorkflowStatsMaintenanceState,
        dailyByDate: [String: WorkflowDailyAggregate],
        changedState: inout Bool
    ) -> [WorkflowStatsMaintenanceTask] {
        let dirty = Set(state.dirty)
        var tasks = state.dirty.map { dirtyTask(for: $0) }

        for dateKey in state.pending where !dirty.contains(dateKey) {
            let day = state.days[dateKey] ?? WorkflowStatsDayMaintenanceState()
            let size = eventLogSize(for: dateKey)
            guard size > day.offset else {
                state.removePending(dateKey)
                changedState = true
                continue
            }

            guard let baseAggregate = dailyByDate[dateKey] else {
                state.markDirty(dateKey)
                changedState = true
                tasks.append(dirtyTask(for: dateKey, size: size))
                continue
            }

            tasks.append(
                pendingTask(
                    for: dateKey,
                    day: day,
                    size: size,
                    baseAggregate: baseAggregate
                )
            )
        }

        return tasks
    }

    private func markDirty(
        _ dateKeys: [String],
        in state: inout WorkflowStatsMaintenanceState
    ) -> Bool {
        let previousDirty = state.dirty
        let previousDays = state.days

        for dateKey in dateKeys {
            state.markDirty(dateKey)
        }

        return previousDirty != state.dirty || previousDays != state.days
    }

    private func dirtyTask(for dateKey: String, size: UInt64? = nil) -> WorkflowStatsMaintenanceTask {
        WorkflowStatsMaintenanceTask(
            dateKey: dateKey,
            startOffset: 0,
            size: size ?? eventLogSize(for: dateKey),
            baseAggregate: nil,
            existingCorrupt: 0
        )
    }

    private func pendingTask(
        for dateKey: String,
        day: WorkflowStatsDayMaintenanceState,
        size: UInt64,
        baseAggregate: WorkflowDailyAggregate
    ) -> WorkflowStatsMaintenanceTask {
        WorkflowStatsMaintenanceTask(
            dateKey: dateKey,
            startOffset: day.offset,
            size: size,
            baseAggregate: baseAggregate,
            existingCorrupt: day.corrupt
        )
    }

    private func eventLogURL(for dateKey: String) -> URL {
        eventsDirectoryURL.appendingPathComponent("\(dateKey).jsonl", isDirectory: false)
    }

    private func eventLogSize(for dateKey: String) -> UInt64 {
        WorkflowStatsStorage.fileSize(at: eventLogURL(for: dateKey))
    }

    private func loadDailyAggregatesWithFailures() -> JSONLinesDecodeResult<WorkflowDailyAggregate> {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return JSONLinesDecodeResult(values: [], failedLineCount: 0)
        }

        return JSONLines.decodeWithFailures(from: data)
    }

    private func eventDateKeys() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: eventsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { WorkflowStatsStorage.isValidDateKey($0) }
            .sorted()
    }

    private func buildDailyAggregate(
        for task: WorkflowStatsMaintenanceTask
    ) throws -> WorkflowStatsMaintenanceResult {
        var aggregate = task.baseAggregate ?? WorkflowDailyAggregate(date: task.dateKey)
        var corrupt = task.existingCorrupt
        var identifierCache = WorkflowDailyIdentifierCache(aggregate: aggregate)
        let keepsIdentifiers = keepsIdentifiers(for: task.dateKey)

        corrupt += try readEvents(
            at: eventLogURL(for: task.dateKey),
            from: task.startOffset,
            upTo: task.size
        ) { event in
            aggregate.record(
                event,
                keepsIdentifiers: keepsIdentifiers,
                identifierCache: &identifierCache
            )
        }

        aggregate.compactIdentifiersIfNeeded(keepsIdentifiers: keepsIdentifiers)
        return WorkflowStatsMaintenanceResult(
            dateKey: task.dateKey,
            aggregate: aggregate,
            size: task.size,
            corrupt: corrupt
        )
    }

    private func readEvents(
        at url: URL,
        from startOffset: UInt64,
        upTo size: UInt64,
        record: (WorkflowHookEvent) -> Void
    ) throws -> Int {
        guard size > startOffset else {
            return 0
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer {
            try? fileHandle.close()
        }

        try fileHandle.seek(toOffset: startOffset)

        let decoder = JSONDecoder()
        var remainingBytes = size - startOffset
        var buffer = Data()
        var corrupt = 0

        while remainingBytes > 0 {
            let readSize = min(Int(remainingBytes), Self.eventReadChunkSize)
            guard let chunk = try fileHandle.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }

            remainingBytes -= UInt64(chunk.count)
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIndex]
                corrupt += decode(lineData, using: decoder, record: record)
                buffer.removeSubrange(...newlineIndex)
            }
        }

        if !buffer.isEmpty {
            corrupt += decode(buffer, using: decoder, record: record)
        }

        return corrupt
    }

    private func decode(
        _ lineData: Data.SubSequence,
        using decoder: JSONDecoder,
        record: (WorkflowHookEvent) -> Void
    ) -> Int {
        guard let line = String(bytes: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return 1
        }

        guard !line.isEmpty else {
            return 0
        }

        guard let data = line.data(using: .utf8),
              let event = try? decoder.decode(WorkflowHookEvent.self, from: data) else {
            return 1
        }

        record(event)
        return 0
    }

    private func commit(_ result: WorkflowStatsMaintenanceResult) throws {
        guard try eventLogHasNotShrunk(for: result) else {
            return
        }

        try writeDailyAggregate(result.aggregate)
        try commitMaintenanceState(result)
    }

    private func eventLogHasNotShrunk(for result: WorkflowStatsMaintenanceResult) throws -> Bool {
        try WorkflowStatsStorage.withExclusiveLock {
            let currentSize = WorkflowStatsStorage.fileSize(at: eventLogURL(for: result.dateKey))
            var state = WorkflowStatsStorage.loadMaintenanceState()

            guard currentSize >= result.size else {
                state.markDirty(result.dateKey)
                try WorkflowStatsStorage.saveMaintenanceState(state)
                return false
            }

            return true
        }
    }

    private func writeDailyAggregate(_ aggregate: WorkflowDailyAggregate) throws {
        try FileManager.default.createDirectory(
            at: dailyLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var aggregates = loadDailyAggregates() ?? []
        upsert(aggregate, into: &aggregates)
        aggregates = WorkflowDailyAggregate.normalized(aggregates: aggregates)
        let data = try WorkflowDailyAggregate.encodeJSONLines(aggregates)
        try data.write(to: dailyLogURL, options: .atomic)
    }

    private func commitMaintenanceState(_ result: WorkflowStatsMaintenanceResult) throws {
        try WorkflowStatsStorage.withExclusiveLock {
            let currentSize = WorkflowStatsStorage.fileSize(at: eventLogURL(for: result.dateKey))
            var state = WorkflowStatsStorage.loadMaintenanceState()

            guard currentSize >= result.size else {
                state.markDirty(result.dateKey)
                try WorkflowStatsStorage.saveMaintenanceState(state)
                return
            }

            state.days[result.dateKey] = WorkflowStatsDayMaintenanceState(
                offset: result.size,
                size: result.size,
                corrupt: result.corrupt
            )
            state.removeDirty(result.dateKey)

            if currentSize == result.size {
                state.removePending(result.dateKey)
            } else {
                state.markPending(result.dateKey)
            }

            try WorkflowStatsStorage.saveMaintenanceState(state)
        }
    }

    private func upsert(_ aggregate: WorkflowDailyAggregate, into aggregates: inout [WorkflowDailyAggregate]) {
        if let index = aggregates.firstIndex(where: { $0.date == aggregate.date }) {
            aggregates[index] = aggregate
        } else {
            aggregates.append(aggregate)
        }
    }

    private func markDirty(_ dateKey: String) {
        try? WorkflowStatsStorage.withExclusiveLock {
            var state = WorkflowStatsStorage.loadMaintenanceState()
            state.markDirty(dateKey)
            try WorkflowStatsStorage.saveMaintenanceState(state)
        }
    }

    private func pruneExpiredEventFiles() throws {
        let cutoffDate = WorkflowStatsStorage.retentionCutoffDate()
        let expiredDateKeys = eventDateKeys().filter { dateKey in
            guard let date = CodexDateFormat.dayDate(from: dateKey) else {
                return false
            }

            return date < cutoffDate
        }

        guard !expiredDateKeys.isEmpty else {
            return
        }

        try WorkflowStatsStorage.withExclusiveLock {
            var state = WorkflowStatsStorage.loadMaintenanceState()
            for dateKey in expiredDateKeys {
                try? FileManager.default.removeItem(at: eventLogURL(for: dateKey))
                state.remove(dateKey)
            }

            try WorkflowStatsStorage.saveMaintenanceState(state)
        }
    }

    private func keepsIdentifiers(for dateKey: String) -> Bool {
        guard let date = CodexDateFormat.dayDate(from: dateKey) else {
            return true
        }

        return date >= WorkflowStatsStorage.identifierRetentionCutoffDate()
    }
}

nonisolated enum WorkflowStatsStorage {
    private static let retentionDayCount = 210
    private static let identifierRetentionDayCount = 3

    static func eventsDirectoryURL() -> URL {
        directoryURL()
            .appendingPathComponent("events", isDirectory: true)
    }

    static func eventLogURL(for dateKey: String) -> URL {
        eventsDirectoryURL()
            .appendingPathComponent("\(dateKey).jsonl", isDirectory: false)
    }

    static func dailyURL() -> URL {
        directoryURL()
            .appendingPathComponent("daily.jsonl", isDirectory: false)
    }

    static func lockURL() -> URL {
        directoryURL()
            .appendingPathComponent("stats.lock", isDirectory: false)
    }

    static func maintenanceURL() -> URL {
        directoryURL()
            .appendingPathComponent("maintenance.json", isDirectory: false)
    }

    static func directoryURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        return applicationSupportURL
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("HookEvents", isDirectory: true)
    }

    static func withExclusiveLock<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: directoryURL(),
            withIntermediateDirectories: true
        )

        let lockURL = lockURL()
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }

        let lockHandle = try FileHandle(forUpdating: lockURL)
        defer {
            try? lockHandle.close()
        }

        if flock(lockHandle.fileDescriptor, LOCK_EX) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        defer {
            flock(lockHandle.fileDescriptor, LOCK_UN)
        }

        return try work()
    }

    static func loadMaintenanceState() -> WorkflowStatsMaintenanceState {
        let url = maintenanceURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let state = try? JSONDecoder().decode(WorkflowStatsMaintenanceState.self, from: data) else {
            return WorkflowStatsMaintenanceState()
        }

        return state
    }

    static func saveMaintenanceState(_ state: WorkflowStatsMaintenanceState) throws {
        try FileManager.default.createDirectory(
            at: directoryURL(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        try data.write(to: maintenanceURL(), options: .atomic)
    }

    static func fileSize(at url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return 0
        }

        return fileSize.uint64Value
    }

    static func retentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: retentionDayCount, today: today, calendar: calendar)
    }

    static func identifierRetentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        cutoffDate(dayCount: identifierRetentionDayCount, today: today, calendar: calendar)
    }

    private static func cutoffDate(dayCount: Int, today: Date, calendar: Calendar) -> Date {
        let todayStart = calendar.startOfDay(for: today)
        return calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: todayStart
        ) ?? todayStart
    }

    static func dateKey(for date: Date) -> String {
        CodexDateFormat.dayString(from: date)
    }

    static func isValidDateKey(_ dateKey: String) -> Bool {
        CodexDateFormat.dayDate(from: dateKey) != nil
    }
}

nonisolated struct WorkflowStatsDayMaintenanceState: Codable, Equatable {
    var offset: UInt64
    var size: UInt64
    var corrupt: Int

    init(offset: UInt64 = 0, size: UInt64 = 0, corrupt: Int = 0) {
        self.offset = offset
        self.size = size
        self.corrupt = corrupt
    }
}

nonisolated struct WorkflowStatsMaintenanceState: Codable, Equatable {
    static let currentSchema = 2

    var schema: Int
    var pending: [String]
    var dirty: [String]
    var days: [String: WorkflowStatsDayMaintenanceState]

    init(
        schema: Int = Self.currentSchema,
        pending: [String] = [],
        dirty: [String] = [],
        days: [String: WorkflowStatsDayMaintenanceState] = [:]
    ) {
        self.schema = schema
        self.pending = Self.normalizedDates(pending)
        self.dirty = Self.normalizedDates(dirty)
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        pending = try Self.normalizedDates(container.decodeIfPresent([String].self, forKey: .pending) ?? [])
        dirty = try Self.normalizedDates(container.decodeIfPresent([String].self, forKey: .dirty) ?? [])
        days = try container.decodeIfPresent([String: WorkflowStatsDayMaintenanceState].self, forKey: .days) ?? [:]
    }

    mutating func markPending(_ dateKey: String) {
        pending = Self.inserting(dateKey, into: pending)
        ensureDayState(for: dateKey)
    }

    mutating func markDirty(_ dateKey: String) {
        dirty = Self.inserting(dateKey, into: dirty)
        ensureDayState(for: dateKey)
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

    mutating func normalize() -> Bool {
        let previousPending = pending
        let previousDirty = dirty
        let previousDays = days

        pending = Self.normalizedDates(pending)
        dirty = Self.normalizedDates(dirty)
        days = days.filter { WorkflowStatsStorage.isValidDateKey($0.key) }

        return previousPending != pending || previousDirty != dirty || previousDays != days
    }

    private mutating func ensureDayState(for dateKey: String) {
        if days[dateKey] == nil {
            days[dateKey] = WorkflowStatsDayMaintenanceState()
        }
    }

    private static func inserting(_ dateKey: String, into dates: [String]) -> [String] {
        normalizedDates(dates + [dateKey])
    }

    private static func normalizedDates(_ dates: [String]) -> [String] {
        Array(Set(dates.filter { WorkflowStatsStorage.isValidDateKey($0) })).sorted()
    }
}

private nonisolated struct WorkflowStatsMaintenanceTask {
    let dateKey: String
    let startOffset: UInt64
    let size: UInt64
    let baseAggregate: WorkflowDailyAggregate?
    let existingCorrupt: Int
}

private nonisolated struct WorkflowStatsMaintenanceResult {
    let dateKey: String
    let aggregate: WorkflowDailyAggregate
    let size: UInt64
    let corrupt: Int
}

@MainActor
final class WorkflowStatsViewModel: ObservableObject {
    @Published private(set) var snapshot = WorkflowStatsSnapshot.empty

    private static let minimumRefreshInterval: TimeInterval = 5

    private let service: WorkflowStatsService
    private var isRefreshing = false
    private let refreshCoordinator = RefreshTaskCoordinator()
    private var lastRefreshedAt: Date?

    init(service: WorkflowStatsService = WorkflowStatsService()) {
        self.service = service
    }

    deinit {
        refreshCoordinator.cancel()
    }

    func refreshIfNeeded(performMaintenance: Bool = false) {
        guard performMaintenance || Date().timeIntervalSince(lastRefreshedAt ?? .distantPast) > Self.minimumRefreshInterval else {
            return
        }

        refresh(performMaintenance: performMaintenance)
    }

    func refresh(performMaintenance: Bool = false) {
        if isRefreshing, !performMaintenance {
            return
        }

        isRefreshing = true

        refreshCoordinator.start { [weak self] generation in
            guard let self else {
                return
            }

            defer {
                self.refreshCoordinator.finish(generation) {
                    self.isRefreshing = false
                }
            }

            let snapshot = await service.loadSnapshot(performMaintenance: performMaintenance)

            guard refreshCoordinator.canCommit(generation) else {
                return
            }

            self.snapshot = snapshot
            lastRefreshedAt = Date()
        }
    }
}
