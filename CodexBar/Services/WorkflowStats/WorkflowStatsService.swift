import Combine
import Darwin
import Foundation

nonisolated final class WorkflowStatsService: @unchecked Sendable {
    private static let maxEventLogReadSize: UInt64 = 5 * 1024 * 1024
    
    private let queue = DispatchQueue(label: "CodexBar.workflow-stats", qos: .utility)
    private let eventLogURL: URL
    private let dailyLogURL: URL
    
    init(
        eventLogURL: URL = WorkflowStatsStorage.eventsURL(),
        dailyLogURL: URL = WorkflowStatsStorage.dailyURL()
    ) {
        self.eventLogURL = eventLogURL
        self.dailyLogURL = dailyLogURL
    }
    
    func loadSnapshot() async -> WorkflowStatsSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.loadSnapshotOnQueue())
            }
        }
    }
    
    private func loadSnapshotOnQueue() -> WorkflowStatsSnapshot {
        if let repairedSnapshot = repairDailyCacheIfNeededOnQueue() {
            return repairedSnapshot
        }
        
        if let aggregates = loadDailyAggregatesOnQueue(), !aggregates.isEmpty {
            return WorkflowStatsSnapshot(dailyAggregates: aggregates)
        }
        
        guard let data = loadEventLogDataOnQueue(), !data.isEmpty else {
            return .empty
        }
        
        return WorkflowStatsSnapshot(events: WorkflowHookEvent.decodeJSONLines(from: data))
    }
    
    private func repairDailyCacheIfNeededOnQueue() -> WorkflowStatsSnapshot? {
        guard dailyCacheNeedsRebuildOnQueue() else {
            return nil
        }
        
        do {
            let eventLogData = try loadEventLogDataForRebuildOnQueue()
            let eventLogStateAfterRead = WorkflowStatsStorage.fileState(at: eventLogURL)
            guard eventLogStateAfterRead.size == UInt64(eventLogData.count) else {
                throw WorkflowStatsRebuildError.eventsChangedDuringRebuild
            }
            
            let decodedEvents = WorkflowHookEvent.decodeJSONLinesWithFailures(from: eventLogData)
            if eventLogStateAfterRead.size > 0,
               decodedEvents.values.isEmpty,
               decodedEvents.failedLineCount > 0 {
                throw WorkflowStatsRebuildError.noReadableEvents(corruptLineCount: decodedEvents.failedLineCount)
            }
            
            let aggregates = WorkflowDailyAggregate.aggregates(from: decodedEvents.values)
            
            return try WorkflowStatsStorage.withExclusiveLock {
                let currentEventLogState = WorkflowStatsStorage.fileState(at: eventLogURL)
                guard currentEventLogState == eventLogStateAfterRead else {
                    throw WorkflowStatsRebuildError.eventsChangedDuringRebuild
                }
                
                var state = WorkflowStatsStorage.loadMaintenanceState()
                guard state.needsDailyRebuild(
                    eventLogSize: currentEventLogState.size,
                    dailyLogURL: dailyLogURL
                ) else {
                    return loadDailyAggregatesOnQueue().map { WorkflowStatsSnapshot(dailyAggregates: $0) } ?? .empty
                }
                
                let data = try WorkflowDailyAggregate.encodeJSONLines(aggregates)
                try data.write(to: dailyLogURL, options: .atomic)
                
                state.markDailyRebuildSucceeded(
                    eventLogSize: currentEventLogState.size,
                    corruptEventLineCount: decodedEvents.failedLineCount
                )
                try WorkflowStatsStorage.saveMaintenanceState(state)
                
                return WorkflowStatsSnapshot(dailyAggregates: aggregates)
            }
        } catch {
            recordDailyRebuildFailureOnQueue(error)
            return nil
        }
    }
    
    private func dailyCacheNeedsRebuildOnQueue() -> Bool {
        WorkflowStatsStorage.loadMaintenanceState().needsDailyRebuild(
            eventLogSize: WorkflowStatsStorage.fileSize(at: eventLogURL),
            dailyLogURL: dailyLogURL
        )
    }
    
    private func loadEventLogDataForRebuildOnQueue() throws -> Data {
        guard FileManager.default.fileExists(atPath: eventLogURL.path) else {
            return Data()
        }
        
        return try Data(contentsOf: eventLogURL)
    }
    
    private func recordDailyRebuildFailureOnQueue(_ error: Error) {
        try? WorkflowStatsStorage.withExclusiveLock {
            var state = WorkflowStatsStorage.loadMaintenanceState()
            state.markDailyRebuildNeeded(error: error)
            try WorkflowStatsStorage.saveMaintenanceState(state)
        }
    }
    
    private func loadDailyAggregatesOnQueue() -> [WorkflowDailyAggregate]? {
        guard let data = try? Data(contentsOf: dailyLogURL), !data.isEmpty else {
            return nil
        }
        
        let aggregates = WorkflowDailyAggregate.decodeJSONLines(from: data)
        guard !aggregates.isEmpty else {
            return nil
        }
        
        return WorkflowDailyAggregate.normalized(aggregates: aggregates)
    }
    
    private func loadEventLogDataOnQueue() -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: eventLogURL.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return try? Data(contentsOf: eventLogURL)
        }
        
        let size = fileSize.uint64Value
        guard size > Self.maxEventLogReadSize else {
            return try? Data(contentsOf: eventLogURL)
        }
        
        guard let fileHandle = try? FileHandle(forReadingFrom: eventLogURL) else {
            return nil
        }
        defer {
            try? fileHandle.close()
        }
        
        guard (try? fileHandle.seek(toOffset: size - Self.maxEventLogReadSize)) != nil,
              let tailData = try? fileHandle.readToEnd() else {
            return nil
        }
        
        return Self.droppingPartialFirstLine(from: tailData)
    }
    
    private static func droppingPartialFirstLine(from data: Data) -> Data {
        guard let newlineIndex = data.firstIndex(of: 0x0A),
              newlineIndex < data.endIndex else {
            return data
        }
        
        return Data(data[data.index(after: newlineIndex)...])
    }
    
}

nonisolated enum WorkflowStatsStorage {
    private static let retentionDayCount = 210
    private static let identifierRetentionDayCount = 7
    
    static func eventsURL() -> URL {
        directoryURL()
            .appendingPathComponent("events.jsonl", isDirectory: false)
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
        fileState(at: url).size
    }
    
    static func fileState(at url: URL) -> WorkflowStatsFileState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber else {
            return WorkflowStatsFileState(size: 0, modifiedAt: nil)
        }
        
        return WorkflowStatsFileState(
            size: fileSize.uint64Value,
            modifiedAt: attributes[.modificationDate] as? Date
        )
    }
    
    static func retentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        let todayStart = calendar.startOfDay(for: today)
        return calendar.date(
            byAdding: .day,
            value: -(retentionDayCount - 1),
            to: todayStart
        ) ?? todayStart
    }
    
    static func identifierRetentionCutoffDate(today: Date = Date(), calendar: Calendar = .current) -> Date {
        let todayStart = calendar.startOfDay(for: today)
        return calendar.date(
            byAdding: .day,
            value: -(identifierRetentionDayCount - 1),
            to: todayStart
        ) ?? todayStart
    }
}

nonisolated struct WorkflowStatsFileState: Equatable {
    let size: UInt64
    let modifiedAt: Date?
}

nonisolated struct WorkflowStatsMaintenanceState: Codable, Equatable {
    private static let maxErrorSummaryLength = 240
    
    var lastMaintenanceDate: String?
    var lastAggregatedEventLogSize: UInt64?
    var needsDailyRebuild: Bool
    var lastDailyRebuildAt: String?
    var lastDailyRebuildFailedAt: String?
    var lastDailyRebuildError: String?
    var corruptEventLineCount: Int
    
    init(
        lastMaintenanceDate: String? = nil,
        lastAggregatedEventLogSize: UInt64? = nil,
        needsDailyRebuild: Bool = false,
        lastDailyRebuildAt: String? = nil,
        lastDailyRebuildFailedAt: String? = nil,
        lastDailyRebuildError: String? = nil,
        corruptEventLineCount: Int = 0
    ) {
        self.lastMaintenanceDate = lastMaintenanceDate
        self.lastAggregatedEventLogSize = lastAggregatedEventLogSize
        self.needsDailyRebuild = needsDailyRebuild
        self.lastDailyRebuildAt = lastDailyRebuildAt
        self.lastDailyRebuildFailedAt = lastDailyRebuildFailedAt
        self.lastDailyRebuildError = lastDailyRebuildError
        self.corruptEventLineCount = corruptEventLineCount
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.lastMaintenanceDate = try container.decodeIfPresent(String.self, forKey: .lastMaintenanceDate)
        self.lastAggregatedEventLogSize = try container.decodeIfPresent(UInt64.self, forKey: .lastAggregatedEventLogSize)
        self.needsDailyRebuild = try container.decodeIfPresent(Bool.self, forKey: .needsDailyRebuild) ?? false
        self.lastDailyRebuildAt = try container.decodeIfPresent(String.self, forKey: .lastDailyRebuildAt)
        self.lastDailyRebuildFailedAt = try container.decodeIfPresent(String.self, forKey: .lastDailyRebuildFailedAt)
        self.lastDailyRebuildError = try container.decodeIfPresent(String.self, forKey: .lastDailyRebuildError)
        self.corruptEventLineCount = try container.decodeIfPresent(Int.self, forKey: .corruptEventLineCount) ?? 0
    }
    
    func needsDailyRebuild(eventLogSize: UInt64, dailyLogURL: URL) -> Bool {
        if needsDailyRebuild {
            return true
        }
        
        guard eventLogSize > 0 else {
            return false
        }
        
        guard let lastAggregatedEventLogSize else {
            return true
        }
        
        if lastAggregatedEventLogSize != eventLogSize {
            return true
        }
        
        return WorkflowStatsStorage.fileSize(at: dailyLogURL) == 0
    }
    
    mutating func markDailyCacheUpdated(eventLogSize: UInt64) {
        needsDailyRebuild = false
        lastAggregatedEventLogSize = eventLogSize
    }
    
    mutating func markDailyRebuildSucceeded(eventLogSize: UInt64, corruptEventLineCount: Int) {
        markDailyCacheUpdated(eventLogSize: eventLogSize)
        lastDailyRebuildAt = Self.timestampString()
        lastDailyRebuildFailedAt = nil
        lastDailyRebuildError = nil
        self.corruptEventLineCount = corruptEventLineCount
    }
    
    mutating func markDailyRebuildNeeded(error: Error? = nil) {
        needsDailyRebuild = true
        
        guard let error else {
            return
        }
        
        lastDailyRebuildFailedAt = Self.timestampString()
        lastDailyRebuildError = Self.errorSummary(error)
    }
    
    static func timestampString(from date: Date = Date()) -> String {
        ISO8601DateFormatter.codexFractional.string(from: date)
    }
    
    private static func errorSummary(_ error: Error) -> String {
        let message = error.localizedDescription
        guard message.count > maxErrorSummaryLength else {
            return message
        }
        
        return String(message.prefix(maxErrorSummaryLength))
    }
}

private nonisolated enum WorkflowStatsRebuildError: LocalizedError {
    case eventsChangedDuringRebuild
    case noReadableEvents(corruptLineCount: Int)
    
    var errorDescription: String? {
        switch self {
        case .eventsChangedDuringRebuild:
            return "events.jsonl changed during daily rebuild"
        case .noReadableEvents(let corruptLineCount):
            return "events.jsonl has no readable events (\(corruptLineCount) corrupt lines)"
        }
    }
}

@MainActor
final class WorkflowStatsViewModel: ObservableObject {
    @Published private(set) var snapshot = WorkflowStatsSnapshot.empty
    
    private static let minimumRefreshInterval: TimeInterval = 5
    
    private let service: WorkflowStatsService
    private var isRefreshing = false
    private var lastRefreshedAt: Date?
    
    init(service: WorkflowStatsService = WorkflowStatsService()) {
        self.service = service
    }
    
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefreshedAt ?? .distantPast) > Self.minimumRefreshInterval else {
            return
        }
        
        refresh()
    }
    
    func refresh() {
        guard !isRefreshing else {
            return
        }
        
        isRefreshing = true
        
        Task {
            snapshot = await service.loadSnapshot()
            lastRefreshedAt = Date()
            isRefreshing = false
        }
    }
}
