import Foundation

nonisolated struct BridgeSubmission {
    enum Target {
        case project(String)
        case task(String, turn: String?)
    }

    let target: Target
    let message: String
    let operationID: String
    let arguments: Data
}

nonisolated enum BridgeCommand {
    case submit(BridgeSubmission)
    case wait(task: String, turn: String?, after: String?, seconds: Int)
    case respond(task: String, request: String, options: BridgeApprovalOptions)
    case interrupt(task: String, turn: String)
    case list(project: String?, status: String?, cursor: String?)
}

nonisolated enum BridgeTool: String, CaseIterable {
    case start = "codex_start"
    case wait = "codex_wait"
    case reply = "codex_reply"
    case respond = "codex_respond"
    case interrupt = "codex_interrupt"
    case list = "codex_list"

    private var description: String {
        switch self {
        case .start: "Use when the user asks Codex to work on a new task in a project directory. Reuse operationId when retrying. Call codex_wait with the returned cursor."
        case .wait:
            "Read turn progress. Follow nextAction even after completion. Show formRequired instructions to the user. Call again with nextCursor as after while the turn is running or hasMore is true."
                + " Honor retryAfterSeconds. Report history_unavailable or an outcome_unknown submission and check again later."
        case .reply: "Send instructions to the active turn or start a follow-up turn. Reuse operationId on retry. Call codex_wait with the returned cursor."
        case .respond: "Open a pending question or approval in this client's MCP form. Submit the answer through the form. Pass any returned cursor to codex_wait."
        case .interrupt: "Request interruption of one specific turn. Check codex_wait for the confirmed outcome."
        case .list: "Find tasks created with the current Bridge token, optionally filtering by project and latest turn status."
        }
    }

    private var fields: (required: [Field], optional: [Field]) {
        switch self {
        case .start: ([.project, .prompt, .operationID], [])
        case .wait: ([.taskID], [.turnID, .after, .timeoutSeconds])
        case .reply: ([.taskID, .message, .operationID], [.turnID])
        case .respond: ([.taskID, .requestID], [.locale])
        case .interrupt: ([.taskID, .turnID], [])
        case .list: ([], [.project, .status, .cursor])
        }
    }

    var definition: BridgeJSON {
        let (required, optional) = fields
        let properties = Dictionary(uniqueKeysWithValues: (required + optional).map { ($0.rawValue, $0.schema(for: self)) })
        return ["name": .string(rawValue), "description": .string(description), "inputSchema": [
            "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0.rawValue) }), "additionalProperties": .bool(false)
        ]]
    }

    func parse(_ args: BridgeJSON) throws -> BridgeCommand {
        let (required, optional) = fields
        let allowed = Set((required + optional).map(\.rawValue))
        guard let values = args.fields, values.keys.allSatisfy(allowed.contains) else { throw BridgeFailure("invalid_arguments") }
        if let missing = required.first(where: { values[$0.rawValue] == nil }) {
            throw BridgeFailure("invalid_argument", missing.rawValue)
        }
        func text(_ field: Field) throws -> String {
            try args.required(field.rawValue, maxBytes: field.maxBytes)
        }
        func optionalText(_ field: Field) throws -> String? {
            try values[field.rawValue].map { _ in try text(field) }
        }
        switch self {
        case .start:
            return try .submit(BridgeSubmission(target: .project(text(.project)), message: text(.prompt), operationID: text(.operationID), arguments: args.data()))
        case .reply:
            let target = try BridgeSubmission.Target.task(text(.taskID), turn: optionalText(.turnID))
            return try .submit(BridgeSubmission(target: target, message: text(.message), operationID: text(.operationID), arguments: args.data()))
        case .respond:
            let options = try BridgeApprovalOptions(locale: optionalText(.locale))
            return try .respond(task: text(.taskID), request: text(.requestID), options: options)
        case .interrupt: return try .interrupt(task: text(.taskID), turn: text(.turnID))
        case .list: return try .list(project: optionalText(.project), status: optionalText(.status), cursor: optionalText(.cursor))
        case .wait:
            let seconds = try values[Field.timeoutSeconds.rawValue].map { value in
                guard let seconds = value.int, Field.waitRange.contains(seconds) else { throw BridgeFailure("invalid_argument", Field.waitConstraint) }
                return seconds
            }
            return try .wait(task: text(.taskID), turn: optionalText(.turnID), after: optionalText(.after), seconds: seconds ?? Field.waitRange.upperBound)
        }
    }

    private enum Field: String {
        case taskID = "taskId"
        case turnID = "turnId"
        case requestID = "requestId"
        case operationID = "operationId"
        case project, prompt, message, after, cursor, status, timeoutSeconds, locale

        static let waitRange = 0 ... 30
        static var waitConstraint: String {
            "timeoutSeconds must be an integer from \(waitRange.lowerBound) to \(waitRange.upperBound) seconds, inclusive."
        }

        var maxBytes: Int {
            switch self {
            case .taskID, .turnID, .requestID, .operationID: 512
            case .project: Int(PATH_MAX)
            case .prompt, .message: 64 * 1024
            case .after, .cursor, .status: 8192
            case .locale: 128
            case .timeoutSeconds: 0
            }
        }

        func description(for tool: BridgeTool) -> String {
            switch self {
            case .project: "Absolute path to an existing project directory on the Mac running CodexBar. Expand ~ before calling. Paths cannot contain NUL."
            case .prompt: "Initial instructions for the new Codex task."
            case .message: "Instructions for the specified Codex task."
            case .operationID: "Choose a new ID per submission. Retry with the same token, tool and arguments, including this ID. Changed arguments cause operation_conflict."
            case .taskID: "ID of a task created with the current Bridge token. Use the taskId from codex_start or codex_list."
            case .turnID where tool == .wait: "Must match the turn in after if given. Omit to read that cursor's turn, or the latest turn when after is also omitted."
            case .turnID where tool == .reply: "Pass the current running or waiting turnId to steer it. Omit to start a follow-up when task status is known and no turn is active."
            case .turnID: "Exact turnId of the task to interrupt. Use the turnId returned by codex_start, codex_reply or codex_wait."
            case .after: "Use cursor from codex_start, codex_reply or codex_respond, or nextCursor from codex_wait, for the same task and turn. Omit for a snapshot at the current position."
            case .requestID: "Use requestId from this task's codex_wait.pendingRequests while the request is open. The form collects the user's answer."
            case .locale: "BCP 47 tag of the current conversation, such as zh-CN. Simplified Chinese tags select Chinese approval labels. Other or omitted tags use English."
            case .cursor: "Omit for the first page. For the next page, pass nextCursor from codex_list unchanged with the same token and filters. A null nextCursor ends the list."
            case .status: "Match the latest turn status exactly (\(BridgeTurnStatus.allCases.map(\.rawValue).joined(separator: ", "))). Omit for all statuses. Other values match no tasks."
            case .timeoutSeconds: "\(Self.waitConstraint) Defaults to \(Self.waitRange.upperBound). Use 0 to return immediately. For longer waits, call again with nextCursor as after."
            }
        }

        func schema(for tool: BridgeTool) -> BridgeJSON {
            let description = description(for: tool)
            if self == .timeoutSeconds {
                return [
                    "type": "integer",
                    "description": .string(description),
                    "minimum": .integer(Self.waitRange.lowerBound),
                    "maximum": .integer(Self.waitRange.upperBound),
                    "default": .integer(Self.waitRange.upperBound)
                ]
            }
            return ["type": "string", "description": .string("\(description) Use 1 to \(maxBytes) UTF-8 bytes."), "minLength": .integer(1)]
        }
    }
}
