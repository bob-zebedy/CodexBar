import Darwin
import Foundation

nonisolated enum WorkflowHookEventRecorder {
    static func handleIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard let eventName = hookEventName(from: arguments) else {
            return false
        }
        
        try? record(eventName: eventName)
        return true
    }
    
    private static func hookEventName(from arguments: [String]) -> String? {
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("--hook-event=") {
                let value = String(argument.dropFirst("--hook-event=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        
        if let optionIndex = arguments.firstIndex(of: "--hook-event"),
           arguments.indices.contains(arguments.index(after: optionIndex)) {
            let value = arguments[arguments.index(after: optionIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        
        return nil
    }
    
    private static func record(eventName: String) throws {
        let occurredAt = Date()
        let payload = stdinPayload()
        let cwd = payload.string(for: "cwd") ?? FileManager.default.currentDirectoryPath
        let tool = payload.string(for: "tool_name")
        let model = payload.string(for: "model")
        let permission = payload.string(for: "permission_mode")
        let sessionId = payload.string(for: "session_id")
        let turnId = payload.string(for: "turn_id")
        let event = WorkflowHookEvent(
            occurredAt: occurredAt,
            name: eventName,
            directoryPath: cwd,
            toolName: tool,
            modelName: model,
            permissionMode: permission,
            sessionId: sessionId,
            turnId: turnId
        )
        
        try recordStatsTransaction(event: event)
    }
    
    private static func recordStatsTransaction(event: WorkflowHookEvent) throws {
        try WorkflowStatsStorage.withExclusiveLock {
            let eventLogURL = WorkflowStatsStorage.eventsURL()
            let dailyLogURL = WorkflowStatsStorage.dailyURL()
            var maintenanceState = WorkflowStatsStorage.loadMaintenanceState()
            let eventLogSizeBeforeAppend = WorkflowStatsStorage.fileSize(at: eventLogURL)
            let needsDailyRebuild = maintenanceState.needsDailyRebuild(
                eventLogSize: eventLogSizeBeforeAppend,
                dailyLogURL: dailyLogURL
            )
            let maintenanceDate = DateFormatter.codexDay.string(from: Calendar.current.startOfDay(for: event.occurredAt))
            let shouldRunMaintenance = maintenanceState.lastMaintenanceDate != maintenanceDate
            
            try append(event.jsonLineData(), to: eventLogURL)
            if shouldRunMaintenance {
                try pruneExpiredEventsIfNeeded(at: eventLogURL)
                maintenanceState.lastMaintenanceDate = maintenanceDate
            }
            
            guard !needsDailyRebuild else {
                maintenanceState.markDailyRebuildNeeded()
                try WorkflowStatsStorage.saveMaintenanceState(maintenanceState)
                return
            }
            
            do {
                try updateDailyAggregates(
                    with: event,
                    eventLogURL: eventLogURL,
                    dailyLogURL: dailyLogURL,
                    runsMaintenance: shouldRunMaintenance
                )
                
                maintenanceState.markDailyCacheUpdated(eventLogSize: WorkflowStatsStorage.fileSize(at: eventLogURL))
                try WorkflowStatsStorage.saveMaintenanceState(maintenanceState)
            } catch {
                maintenanceState.markDailyRebuildNeeded(error: error)
                try? WorkflowStatsStorage.saveMaintenanceState(maintenanceState)
                throw error
            }
        }
    }
    
    private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        
        let fileHandle = try FileHandle(forWritingTo: url)
        defer {
            try? fileHandle.close()
        }
        
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
    }
    
    private static func pruneExpiredEventsIfNeeded(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        
        let fileHandle = try FileHandle(forUpdating: url)
        defer {
            try? fileHandle.close()
        }
        
        let cutoffDate = WorkflowStatsStorage.retentionCutoffDate()
        guard try shouldPruneEvents(in: fileHandle, cutoffDate: cutoffDate) else {
            return
        }
        
        try fileHandle.seek(toOffset: 0)
        let currentData = try fileHandle.readToEnd() ?? Data()
        let retainedData = try retainedEventLogData(from: currentData, cutoffDate: cutoffDate)
        
        try fileHandle.truncate(atOffset: 0)
        try fileHandle.seek(toOffset: 0)
        try fileHandle.write(contentsOf: retainedData)
    }
    
    private static func shouldPruneEvents(in fileHandle: FileHandle, cutoffDate: Date) throws -> Bool {
        try fileHandle.seek(toOffset: 0)
        guard let firstChunk = try fileHandle.read(upToCount: 64 * 1024), !firstChunk.isEmpty else {
            return false
        }
        
        let firstLineEnd = firstChunk.firstIndex(of: 0x0A) ?? firstChunk.endIndex
        let firstLine = Data(firstChunk[..<firstLineEnd])
        guard !firstLine.isEmpty else {
            return false
        }
        
        guard let event = try? JSONDecoder().decode(WorkflowHookEvent.self, from: firstLine) else {
            return true
        }
        
        return event.occurredAt < cutoffDate
    }
    
    private static func retainedEventLogData(from data: Data, cutoffDate: Date) throws -> Data {
        var retainedData = Data()
        for event in WorkflowHookEvent.decodeJSONLines(from: data) where event.occurredAt >= cutoffDate {
            retainedData.append(try event.jsonLineData())
        }
        
        return retainedData
    }
    
    private static func updateDailyAggregates(
        with event: WorkflowHookEvent,
        eventLogURL: URL,
        dailyLogURL: URL,
        runsMaintenance: Bool
    ) throws {
        var aggregates = loadDailyAggregates(from: dailyLogURL)
        
        if aggregates.isEmpty {
            aggregates = rebuildDailyAggregates(from: eventLogURL)
        } else {
            aggregates = adding(event, to: aggregates)
            aggregates = runsMaintenance
            ? WorkflowDailyAggregate.normalized(aggregates: aggregates)
            : aggregates.sorted { $0.date < $1.date }
        }
        
        let data = try WorkflowDailyAggregate.encodeJSONLines(aggregates)
        try data.write(to: dailyLogURL, options: .atomic)
    }
    
    private static func adding(
        _ event: WorkflowHookEvent,
        to aggregates: [WorkflowDailyAggregate]
    ) -> [WorkflowDailyAggregate] {
        let calendar = Calendar.current
        let eventStartDate = calendar.startOfDay(for: event.occurredAt)
        guard eventStartDate >= WorkflowStatsStorage.retentionCutoffDate(calendar: calendar) else {
            return WorkflowDailyAggregate.normalized(aggregates: aggregates, calendar: calendar)
        }
        
        let startDate = DateFormatter.codexDay.string(from: eventStartDate)
        let keepsIdentifiers = eventStartDate >= WorkflowStatsStorage.identifierRetentionCutoffDate(calendar: calendar)
        var aggregatesByDate = aggregates.reduce(into: [String: WorkflowDailyAggregate]()) { result, aggregate in
            result[aggregate.date] = aggregate
        }
        aggregatesByDate[startDate, default: WorkflowDailyAggregate(date: startDate)]
            .record(event, keepsIdentifiers: keepsIdentifiers)
        
        return Array(aggregatesByDate.values)
    }
    
    private static func loadDailyAggregates(from url: URL) -> [WorkflowDailyAggregate] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return []
        }
        
        return WorkflowDailyAggregate.decodeJSONLines(from: data)
    }
    
    private static func rebuildDailyAggregates(from url: URL) -> [WorkflowDailyAggregate] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return []
        }
        
        return WorkflowDailyAggregate.aggregates(from: WorkflowHookEvent.decodeJSONLines(from: data))
    }
    
    private static func stdinPayload() -> WorkflowHookPayload {
        guard isatty(STDIN_FILENO) == 0 else {
            return WorkflowHookPayload(values: [:])
        }
        
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any] else {
            return WorkflowHookPayload(values: [:])
        }
        
        return WorkflowHookPayload(values: values)
    }
}

private nonisolated struct WorkflowHookPayload {
    let values: [String: Any]
    
    func string(for key: String) -> String? {
        Self.normalizedString(values[key])
    }
    
    private static func normalizedString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedString.isEmpty ? nil : trimmedString
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}
