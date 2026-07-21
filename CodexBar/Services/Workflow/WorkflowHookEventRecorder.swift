import Darwin
import Foundation

/// Hook 子进程入口: 读取 stdin payload, 写入本地 JSONL, 然后立即退出
nonisolated enum WorkflowHookEventRecorder {
    static let hookArgument = "--hook-event"

    static func handleIfRequested() -> Bool {
        guard CommandLine.arguments.contains(hookArgument) else {
            return false
        }

        let payload = stdinPayload()

        guard let eventName = payload.string(for: "hook_event_name") else {
            // 显式 Hook 模式下吞掉无效输入
            // 避免 Hook 子进程继续启动完整菜单栏 App

            return true
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
        let agentId = payload.string(for: "agent_id")
        let turnContext = readTurnContext(
            from: payload,
            eventName: eventName,
            turnId: turnId
        )
        let event = WorkflowHookEvent(
            timestamp: timestamp,
            name: eventName,
            directoryPath: cwd,
            toolName: tool,
            modelName: model,
            effort: turnContext?.effort,
            permissionMode: permission,
            approvalReviewer: turnContext?.approvalReviewer,
            sessionId: sessionId,
            turnId: turnId,
            agentId: agentId
        )

        try recordWorkflowTransaction(event: event)
    }

    private static func readTurnContext(
        from payload: WorkflowHookPayload,
        eventName: String,
        turnId: String?
    ) -> WorkflowTurnContext? {
        guard let hookEvent = CodexHookEvent(eventName: eventName),
              hookEvent == .userPromptSubmit || hookEvent == .permissionRequest,
              let turnId,
              let transcriptPath = payload.string(for: "transcript_path") else {
            return nil
        }
        return WorkflowTurnContextReader.context(
            transcriptPath: transcriptPath,
            turnId: turnId
        )
    }

    private static func recordWorkflowTransaction(event: WorkflowHookEvent) throws {
        try WorkflowStorage.withExclusiveLock {
            let dateKey = WorkflowStorage.dateKey(for: event.timestamp)
            let eventLogURL = WorkflowStorage.eventLogURL(for: dateKey)
            var maintenanceState = WorkflowStorage.loadMaintenanceState()
            let existingStat = WorkflowStorage.fileStat(at: eventLogURL)
            var stateChanged = false

            if let existingStat {
                let day = maintenanceState.days[dateKey]
                let identifierChanged = day?.fileIdentifier != nil
                    && existingStat.identifier != nil
                    && day?.fileIdentifier != existingStat.identifier
                let fileShrank = day.map { existingStat.size < $0.offset } ?? false

                if identifierChanged || fileShrank {
                    maintenanceState.startNewSourceGeneration(
                        for: dateKey,
                        isFresh: existingStat.size == 0,
                        fileIdentifier: existingStat.identifier
                    )
                    stateChanged = true
                } else {
                    stateChanged = maintenanceState.ensureSourceGeneration(
                        for: dateKey,
                        fileIdentifier: existingStat.identifier
                    )
                }
            } else {
                maintenanceState.startNewSourceGeneration(
                    for: dateKey,
                    isFresh: true,
                    fileIdentifier: nil
                )
                stateChanged = true
            }

            try append(event.jsonLineData(), to: eventLogURL)

            if var day = maintenanceState.days[dateKey],
               day.fileIdentifier == nil,
               let identifier = WorkflowStorage.fileStat(at: eventLogURL)?.identifier {
                day.fileIdentifier = identifier
                maintenanceState.days[dateKey] = day
                stateChanged = true
            }

            // 稳态下当天早已 pending, 跳过无变化的全量重写以缩短持锁时间
            if maintenanceState.markPending(dateKey) || stateChanged {
                try WorkflowStorage.saveMaintenanceState(maintenanceState)
            }
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
            return WorkflowHookPayload(values: [:])
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            return WorkflowHookPayload(values: [:])
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any] else {
            return WorkflowHookPayload(values: [:])
        }

        return WorkflowHookPayload(values: values)
    }
}

/// Hook payload 不直接提供 reviewer 和 effort; 从当前 rollout 尾部只提取匹配 turn 的上下文
private nonisolated enum WorkflowTurnContextReader {
    static func context(
        transcriptPath: String,
        turnId: String
    ) -> WorkflowTurnContext? {
        let url = URL(fileURLWithPath: transcriptPath)
        let size = WorkflowStorage.fileSize(at: url)
        guard size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let offset = size > searchByteLimit ? size - searchByteLimit : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty else {
            return nil
        }

        let completeData = offset > 0 ? JSONLines.droppingLeadingPartialLine(data) : data

        for envelope in JSONLines.decode(CodexRolloutLineEnvelope.self, from: completeData)
            .reversed() {
            guard envelope.type == "turn_context",
                  let payload = envelope.payload,
                  payload.turnId == turnId else {
                continue
            }
            return WorkflowTurnContext(
                approvalReviewer: payload.approvalReviewer,
                effort: payload.normalizedEffort
            )
        }
        return nil
    }

    private static let searchByteLimit: UInt64 = 512 * 1024
}

private nonisolated struct WorkflowTurnContext {
    let approvalReviewer: CodexApprovalReviewer?
    let effort: String?
}

/// Codex Hook payload 字段存在版本差异, 这里集中做宽松类型归一化
private nonisolated struct WorkflowHookPayload {
    let values: [String: Any]

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

        if let date = CodexDateFormat.iso8601Date(from: trimmedString) {
            return date
        }

        return CodexDateFormat.localTimestampDate(from: trimmedString)
    }
}
