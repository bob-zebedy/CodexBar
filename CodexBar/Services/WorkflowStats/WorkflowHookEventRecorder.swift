import Darwin
import Foundation

nonisolated enum WorkflowHookEventRecorder {
    static func handleIfRequested() -> Bool {
        let payload = stdinPayload()

        guard let eventName = payload.string(for: "hook_event_name") else {
            // 如果 Codex 已经通过 stdin 传了内容但事件名缺失, 吞掉本次 Hook
            // 避免 Hook 子进程继续启动完整菜单栏 App
            return payload.hasInput
        }

        try? record(payload: payload, eventName: eventName)
        return true
    }

    private static func record(payload: WorkflowHookPayload, eventName: String) throws {
        let timestamp = payload.date(for: "timestamp") ?? Date()
        let cwd = payload.string(for: "cwd") ?? FileManager.default.currentDirectoryPath
        let tool = payload.string(for: "tool_name")
        let model = payload.string(for: "model")
        let permission = payload.string(for: "permission_mode")
        let sessionId = payload.string(for: "session_id")
        let turnId = payload.string(for: "turn_id")
        let event = WorkflowHookEvent(
            timestamp: timestamp,
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
            let dateKey = WorkflowStatsStorage.dateKey(for: event.timestamp)
            let eventLogURL = WorkflowStatsStorage.eventLogURL(for: dateKey)
            var maintenanceState = WorkflowStatsStorage.loadMaintenanceState()

            try append(event.jsonLineData(), to: eventLogURL)
            maintenanceState.markPending(dateKey)
            try WorkflowStatsStorage.saveMaintenanceState(maintenanceState)
        }
    }

    private static func append(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

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

    private static func stdinPayload() -> WorkflowHookPayload {
        guard isatty(STDIN_FILENO) == 0 else {
            return WorkflowHookPayload(values: [:], hasInput: false)
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            return WorkflowHookPayload(values: [:], hasInput: false)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any] else {
            return WorkflowHookPayload(values: [:], hasInput: true)
        }

        return WorkflowHookPayload(values: values, hasInput: true)
    }
}

private nonisolated struct WorkflowHookPayload {
    let values: [String: Any]
    let hasInput: Bool

    func string(for key: String) -> String? {
        Self.normalizedString(values[key])
    }

    func date(for key: String) -> Date? {
        Self.normalizedDate(values[key])
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

    private static func normalizedDate(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            return date(from: string)
        case let number as NSNumber:
            let rawValue = number.doubleValue
            let seconds = rawValue > 10000000000 ? rawValue / 1000 : rawValue
            return Date(timeIntervalSince1970: seconds)
        default:
            return nil
        }
    }

    private static func date(from string: String) -> Date? {
        let trimmedString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedString.isEmpty else {
            return nil
        }

        if let date = ISO8601DateFormatter.codexFractional.date(from: trimmedString) {
            return date
        }

        if let date = DateFormatter.codexLocalTimestamp.date(from: trimmedString) {
            return date
        }

        return ISO8601DateFormatter.codexInternetDateTime.date(from: trimmedString)
    }
}
