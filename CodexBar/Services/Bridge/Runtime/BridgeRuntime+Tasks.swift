import Foundation

extension BridgeRuntime {
    func resolveProject(_ input: String) throws -> String {
        guard input.hasPrefix("/"), !input.utf8.contains(0) else { throw BridgeFailure("project_required", "Pass the absolute path to the project directory.") }
        let path = CodexPaths.canonicalPath(input)
        guard (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw BridgeFailure("project_required", "Pass an existing project directory.")
        }
        return path
    }

    func attach(_ record: BridgeTaskRecord) throws {
        if connection == nil || subscriptions[record.id]?.isTrackingTask != true {
            try restore(record)
        }
    }

    func restoreForObservation(_ record: BridgeTaskRecord) throws {
        do {
            try attach(record)
        } catch let failure as BridgeFailure where ["project_changed", "project_required"].contains(failure.code) {
            try refreshLatestTurnStatus(for: record.id)
        }
    }

    func restore(_ record: BridgeTaskRecord) throws {
        let configuration = try requireConfiguration(record.configurationID)
        guard try resolveProject(record.project) == record.project else { throw BridgeFailure("project_changed") }
        var params = configuration.permissions.threadOptions(project: record.project, bridgeDirectory: directory)
        params["threadId"] = .string(record.id)
        params["excludeTurns"] = .bool(true)
        let result = try call("thread/resume", .object(params))
        guard result["thread"]["id"].text == record.id else { throw BridgeFailure("invalid_thread") }
        // 已加载线程可能忽略恢复参数, 在下一轮开始前重新加载并验证
        let policyMatches = (try? configuration.permissions.validate(result, project: record.project)) != nil
        try refreshLatestTurnStatus(for: record.id)
        try applyActiveFlags(result["thread"]["status"], to: record.id)
        subscriptions[record.id] = policyMatches ? .verified(configuration.permissions) : .unverified
    }

    private func prepareNextTurn(_ task: BridgeTaskRecord) throws {
        let permissions = try requireConfiguration(task.configurationID).permissions
        guard subscriptions[task.id] != .verified(permissions) else { return }
        _ = try call("thread/unsubscribe", ["threadId": .string(task.id)])
        subscriptions[task.id] = nil
        try restore(task)
        guard subscriptions[task.id] == .verified(permissions) else {
            throw BridgeFailure("policy_mismatch", "Codex has not applied the updated permissions to this thread. Start a new task to use them.")
        }
        guard try taskRecord(for: task.id)?.status.isActive != true else { throw BridgeFailure("turn_active") }
    }

    func refreshLatestTurnStatus(for taskID: String) throws {
        if let turn = try readTurn(in: taskID), let latestTurnID = turn["id"].text {
            if let previous = try taskRecord(for: taskID), let old = previous.latestTurnID, old != latestTurnID,
               previous.status == .completed, try store.hasUnconfirmedQuestionReply(for: previous) {
                try ensureQuestionsRecovered(previous, turn: old)
                guard try taskRecord(for: taskID)?.latestTurnID == latestTurnID else { throw BridgeFailure("outcome_unknown", taskID) }
            }
            try setStatus(BridgeTurnStatus(upstream: turn["status"]), taskID: taskID, turnID: latestTurnID)
        }
    }

    func turnDetails(for turn: String, in record: BridgeTaskRecord) throws -> (status: BridgeTurnStatus, entry: BridgeJSON?) {
        if record.latestTurnID == turn {
            return (record.status, nil)
        }
        guard let entry = try readTurn(in: record.id, .matching(turn)) else { throw BridgeFailure("turn_not_found") }
        return (BridgeTurnStatus(upstream: entry["status"]), entry)
    }

    enum TurnLookup {
        case latest, matching(String), following(String)
    }

    func readTurn(in thread: String, _ lookup: TurnLookup = .latest) throws -> BridgeJSON? {
        let deadline = Date().addingTimeInterval(5)
        let budget = AppServerRequestBudget.current?.constrained(to: deadline) ?? AppServerRequestBudget(deadline: deadline)
        return try AppServerRequestBudget.$current.withValue(budget) {
            let limit = if case .latest = lookup {
                1
            } else {
                100
            }
            var newer: BridgeJSON?
            var params: [String: BridgeJSON] = ["threadId": .string(thread), "limit": .integer(limit), "sortDirection": "desc", "itemsView": "notLoaded"]
            var visited = Set<String>()
            repeat {
                try budget.check()
                let page = try call("thread/turns/list", .object(params))
                let turns = page["data"].elements
                switch lookup {
                case .latest: return turns.first
                case let .matching(id):
                    if let match = turns.first(where: { $0["id"].text == id }) {
                        return match
                    }
                case let .following(id):
                    for entry in turns {
                        if entry["id"].text == id {
                            return newer
                        }
                        newer = entry
                    }
                }
                guard let next = page["nextCursor"].text else { return nil }
                guard visited.insert(next).inserted else { throw BridgeFailure("invalid_history_cursor") }
                params["cursor"] = .string(next)
            } while true
        }
    }

    func applyActiveFlags(_ status: BridgeJSON, to id: String) throws {
        guard status["type"] == "active", let record = try taskRecord(for: id), let turn = record.latestTurnID,
              record.status.isActive else { return }
        let waiting = status["activeFlags"].elements.contains { $0 == "waitingOnApproval" || $0 == "waitingOnUserInput" }
        try setStatus(waiting ? .waiting : .running, taskID: id, turnID: turn)
    }

    func setStatus(_ status: BridgeTurnStatus, taskID: String, turnID: String, canReplaceLatestTurn: Bool = true) throws {
        guard var task = try taskRecord(for: taskID), canReplaceLatestTurn || task.latestTurnID == turnID, task.latestTurnID != turnID || task.status != status else { return }
        task.latestTurnID = turnID
        task.status = status
        task.updated = Date()
        try store.updateTask(task)
        rememberStatus(task)
    }

    private func rememberStatus(_ task: BridgeTaskRecord) {
        activeTasks[task.id] = task.status.isActive ? task : nil
        requests.discardQuestionsOutsideLatestTurn(task: task.id, turn: task.latestTurnID)
    }

    private enum InputMode {
        case first
        case followUp
        case answer(BridgePendingRequest, startsTurn: Bool)
        case steer(String)

        var startsFirstTurn: Bool {
            if case .first = self {
                return true
            }
            return false
        }

        var question: BridgePendingRequest? {
            if case let .answer(request, _) = self {
                return request
            }
            return nil
        }

        var target: String? {
            switch self {
            case let .steer(turn): turn
            case let .answer(request, startsTurn): startsTurn ? nil : request.turn
            default: nil
            }
        }
    }

    func submit(_ submission: BridgeSubmission, configuration: BridgeConfiguration) throws -> BridgeJSON {
        let tool: BridgeTool = switch submission.target {
        case .project: .start
        case .task: .reply
        }
        let key = BridgeOperationKey(configurationID: configuration.id, tool: tool, id: "client/" + submission.operationID)
        let fingerprint = BridgeStore.digest(submission.arguments)
        try pruneIfNeeded()
        let previous = try store.replay(key, digest: fingerprint)
        if case let .receipt(value) = previous {
            return value
        }

        let id: String
        let mode: InputMode
        switch submission.target {
        case let .project(path):
            let project = try resolveProject(path)
            mode = .first
            if case let .firstTurnPending(createdThread) = previous {
                let original = try requireTask(createdThread, configurationID: configuration.id)
                guard original.project == project else { throw BridgeFailure("project_changed") }
                try attach(original)
                id = createdThread
            } else {
                var options = configuration.permissions.threadOptions(project: project, bridgeDirectory: directory)
                options["threadSource"] = "codexbar_bridge"
                try open()
                try Task.checkCancellation()
                if let receipt = try store.reserve(key, digest: fingerprint, task: nil) {
                    return receipt
                }
                let response = try deliver("thread/start", .object(options), key: key, task: nil)
                guard let created = response["thread"]["id"].text, !created.isEmpty else { throw BridgeFailure("outcome_unknown") }
                id = created
                BridgeLogPrivacy.shared.register(id)
                let task = BridgeTaskRecord(id: id, configurationID: configuration.id, project: project, title: String(submission.message.prefix(64)))
                do { try store.recordThread(task, for: key) } catch { throw BridgeFailure("outcome_unknown", id) }
                try configuration.permissions.validate(response, project: project)
                subscriptions[id] = .verified(configuration.permissions)
            }
        case let .task(taskID, turn):
            let record = try requireTask(taskID, configurationID: configuration.id)
            guard try resolveProject(record.project) == record.project else { throw BridgeFailure("project_changed") }
            try attach(record)
            id = taskID
            mode = turn.map(InputMode.steer) ?? .followUp
        }
        return try sendInput(id, message: submission.message, mode: mode, operation: key, digest: fingerprint)
    }

    private func deliver(_ method: String, _ params: BridgeJSON, key: BridgeOperationKey, task: String?, question: Bool = false) throws -> BridgeJSON {
        do {
            return try exchange(method, params)
        } catch let failure as BridgeFailure where ["codex_rejected", "unsupported_capability"].contains(failure.code) {
            do {
                if question {
                    try store.release(key)
                } else {
                    try store.fail(key, error: failure)
                }
            } catch { throw BridgeFailure("outcome_unknown", task ?? "") }
            throw failure
        } catch {
            throw BridgeFailure("outcome_unknown", task ?? "")
        }
    }

    private func prepareInput(_ id: String, mode: InputMode) throws -> BridgeTaskRecord {
        if !mode.startsFirstTurn, mode.target == nil {
            try refreshLatestTurnStatus(for: id)
        }
        guard let current = try taskRecord(for: id) else { throw BridgeFailure("task_not_found") }
        if let target = mode.target {
            guard current.latestTurnID == target, current.status.isActive else { throw BridgeFailure("turn_changed") }
            guard case .verified = subscriptions[id] else { throw BridgeFailure("policy_mismatch") }
        } else {
            if case .first = mode, current.latestTurnID != nil {
                throw BridgeFailure("turn_changed")
            }
            if let question = mode.question {
                guard current.latestTurnID == question.turn, current.status == .completed else { throw BridgeFailure("turn_changed") }
                try ensureQuestionsRecovered(current, turn: question.turn)
            }
            guard !current.status.isActive, current.status != .unknown else { throw BridgeFailure("turn_active") }
            try prepareNextTurn(current)
            if let question = mode.question {
                guard try taskRecord(for: id)?.latestTurnID == question.turn else { throw BridgeFailure("turn_changed") }
                _ = try pending(task: id, id: question.id, configurationID: current.configurationID)
            }
        }
        return current
    }

    private func sendInput(_ id: String, message: String, mode: InputMode, operation: BridgeOperationKey, digest: Data) throws -> BridgeJSON {
        var current = try prepareInput(id, mode: mode)
        var params: [String: BridgeJSON] = ["threadId": .string(id), "input": [["type": "text", "text": .string(message), "text_elements": []]]]
        let target = mode.target
        if let target {
            params["expectedTurnId"] = .string(target)
        }
        let question = mode.question
        // 只读检查通过后才预留投递标识, 一旦预留就要等这次请求返回
        try open()
        try Task.checkCancellation()
        if case .first = mode {
            try store.beginFirstTurn(operation)
        } else if let receipt = try store.reserve(operation, digest: digest, task: id) {
            return receipt
        }
        let response = try deliver(target == nil ? "turn/start" : "turn/steer", .object(params), key: operation, task: id, question: question != nil)
        let turn: String
        let cursorPosition: Int
        var updatedTask: BridgeTaskRecord?
        if let target {
            guard response["turnId"].text == target else { throw BridgeFailure("outcome_unknown", id) }
            turn = target
            cursorPosition = buffers[target]?.sequence ?? 0
        } else {
            guard let started = response["turn"]["id"].text, !started.isEmpty else { throw BridgeFailure("outcome_unknown", id) }
            turn = started
            cursorPosition = 0
            current.latestTurnID = turn
            current.status = BridgeTurnStatus(upstream: response["turn"]["status"])
            current.updated = Date()
            updatedTask = current
        }
        let buffer = ensureBuffer(turn, task: id)
        let cursor = BridgeCursor(epoch: buffer.epoch, task: id, turn: turn, sequence: cursorPosition)
        do {
            try commitInput(operation, cursor: cursor, updatedTask: updatedTask, previous: question?.turn, answered: question?.messageID)
        } catch { throw BridgeFailure("outcome_unknown", id) }
        return cursor.receipt
    }

    func commitInput(_ operation: BridgeOperationKey, cursor: BridgeCursor, updatedTask: BridgeTaskRecord?, previous: String?, answered item: String?) throws {
        try store.complete(operation, cursor: cursor, task: updatedTask) {
            if let previous, updatedTask != nil {
                try carryQuestions(task: cursor.task, from: previous, to: cursor.turn)
            }
            if let item {
                try store.markQuestionClosed(task: cursor.task, item: item, turn: cursor.turn)
            }
        }
        if let updatedTask {
            if let previous {
                requests.moveQuestions(task: cursor.task, from: previous, to: cursor.turn)
            }
            buffers[cursor.turn]?.needsHistory = previous != nil
            rememberStatus(updatedTask)
        }
    }

    private func carryQuestions(task: String, from previous: String, to turn: String) throws {
        try store.moveCarriedQuestions(task: task, from: previous, to: turn)
        for request in requests.forTurn(.init(task: task, turn: previous)) {
            if case let .message(questions, origin) = request.source {
                try store.carryQuestion(task: task, item: questions.itemID, from: origin, to: turn)
            }
        }
    }

    private func pending(task taskID: String, id: String, configurationID: UUID) throws -> BridgePendingRequest {
        _ = try requireTask(taskID, configurationID: configurationID)
        let request = try requests.pending(task: taskID, id: id)
        if request.submissionUncertain {
            throw BridgeFailure("outcome_unknown", taskID)
        }
        return request
    }

    static func formRequiredMessage(canInterrupt: Bool) -> String {
        let instruction = "Use the same Bridge token in a session that supports MCP forms"
        return instruction + (canInterrupt ? ", or interrupt the turn." : ".")
    }

    func respond(
        task: String,
        id: String,
        configurationID: UUID,
        approvalOptions: BridgeApprovalOptions,
        presentForm: (@Sendable (BridgeJSON) async throws -> BridgeJSON)?
    ) async throws -> BridgeJSON {
        let first = try pending(task: task, id: id, configurationID: configurationID)
        guard let presentForm, let form = first.form(approvalOptions: approvalOptions) else {
            throw try BridgeFailure("client_form_required", Self.formRequiredMessage(canInterrupt: taskRecord(for: task)?.status.isActive == true))
        }
        let response = try await presentForm(form)
        try Task.checkCancellation()
        // 表单打开期间任务可能已经换轮或被撤权, 回写前重新确认归属和请求
        let request = try pending(task: task, id: id, configurationID: configurationID)
        let requestID = BridgeJSON.string(request.id)
        guard case let .message(questions, origin) = request.source else {
            if try request.disallowsApproval(under: requireConfiguration(configurationID).permissions) {
                try resolve(request, response: ["action": "decline"])
                throw BridgeFailure("request_closed")
            }
            try resolve(request, response: response)
            return ["status": "submitted", "requestId": requestID]
        }
        guard let message = try questions.reply(response) else {
            try store.markQuestionClosed(task: task, item: questions.itemID, turn: request.turn)
            requests.close(request.id)
            append(task: request.task, turn: request.turn, event: ["type": "request_closed", "requestId": requestID])
            return ["status": "dismissed", "requestId": requestID]
        }
        let key = try BridgeOperationKey.question(configurationID, task: task, origin: origin, item: questions.itemID)
        let receipt = try submitQuestionReply(message, request: request, key: key)
        requests.close(request.id)
        append(task: task, turn: request.turn, event: ["type": "response_submitted", "requestId": requestID])
        return ["status": "submitted", "requestId": requestID, "taskId": receipt["taskId"], "turnId": receipt["turnId"], "cursor": receipt["cursor"]]
    }

    private func submitQuestionReply(_ message: String, request: BridgePendingRequest, key: BridgeOperationKey) throws -> BridgeJSON {
        let task = request.task
        guard let original = try taskRecord(for: task), original.latestTurnID == request.turn else { throw BridgeFailure("turn_changed") }
        guard try resolveProject(original.project) == original.project else { throw BridgeFailure("project_changed") }
        try attach(original)
        guard let current = try taskRecord(for: task), current.latestTurnID == request.turn else { throw BridgeFailure("turn_changed") }

        let digest = BridgeStore.digest(Data(message.utf8))
        do {
            if current.status.isActive {
                do {
                    return try sendInput(task, message: message, mode: .answer(request, startsTurn: false), operation: key, digest: digest)
                } catch let failure as BridgeFailure where failure.code == "codex_rejected" {
                    // 上游明确拒绝后才检查原轮次是否结束
                }
            }
            return try sendInput(task, message: message, mode: .answer(request, startsTurn: true), operation: key, digest: digest)
        } catch let failure as BridgeFailure where failure.code == "outcome_unknown" {
            _ = ensureBuffer(request.turn, task: task)
            requests.markSubmissionUncertain(request.id)
            buffers[request.turn]?.needsHistory = true
            throw failure
        }
    }

    func resolve(_ request: BridgePendingRequest, response: BridgeJSON) throws {
        guard case let .rpc(rpc) = request.source else { throw BridgeFailure("request_closed") }
        try sendRPCResponse(rpc.answer(response), to: rpc)
        requests.close(request.id)
        append(task: request.task, turn: request.turn, event: ["type": "response_submitted", "requestId": .string(request.id)])
    }

    func sendRPCResponse(_ result: BridgeJSON, to rpc: BridgeRPCRequest) throws {
        guard let connection else { throw BridgeFailure("request_closed") }
        do {
            try AppServerRequestBudget.$finishesCurrentExchange.withValue(true) {
                try connection.answer(rpc.method, id: rpc.id, result: result)
            }
        } catch {
            disconnect()
            throw BridgeFailure("outcome_unknown")
        }
    }
}
