import Foundation

extension BridgeRuntime {
    func ensureBuffer(_ turn: String, task: String) -> BridgeTurnEvents {
        if let buffer = buffers[turn] {
            return buffer
        }
        if buffers.count >= 64, let oldest = buffers.min(by: { $0.value.updated < $1.value.updated })?.key {
            buffers.removeValue(forKey: oldest)
        }
        let buffer = BridgeTurnEvents(task: task)
        buffers[turn] = buffer
        return buffer
    }

    func receive(_ message: BridgeJSON) throws {
        let params = message["params"]
        guard let method = message["method"].text, let taskID = params["threadId"].text,
              let subscription = subscriptions[taskID] else { return }
        if case let .retiring(retiring) = subscription {
            try handleRetiredTask(taskID, turn: retiring, method: method, message: message)
            return
        }
        guard let record = try taskRecord(for: taskID) else { return }
        if method == "serverRequest/resolved" {
            if let request = requests.resolveRPC(task: taskID, id: params["requestId"]) {
                append(task: taskID, turn: request.turn, event: ["type": "request_closed", "requestId": .string(request.id)])
            }
            return
        }
        let threadTurn = method == "thread/status/changed" ? record.latestTurnID : nil
        guard let turn = params["turnId"].text ?? params["turn"]["id"].text ?? threadTurn else {
            if method == BridgeRPCRequest.Method.elicitation.rawValue, message["id"].rpcID != nil {
                try connection?.answer(.elicitation, id: message["id"], result: ["action": "cancel", "content": .null, "_meta": .null])
            }
            return
        }
        let isDelta = method == "item/agentMessage/delta" || method == "item/commandExecution/outputDelta"
        if !isDelta {
            flushDelta(turn)
        }
        if message["id"].rpcID != nil {
            try receiveRequest(method, rpcID: message["id"], params: params, record: record, turn: turn, subscription: subscription)
            return
        }
        let item = params["item"]
        var event: BridgeJSON
        switch method {
        case "turn/started":
            try receiveTurnStart(record, turn: turn)
            event = ["type": "turn_started"]
        case "turn/completed":
            let status = BridgeTurnStatus(upstream: params["turn"]["status"])
            try setStatus(status, taskID: taskID, turnID: turn, canReplaceLatestTurn: record.latestTurnID == turn || record.latestTurnID == nil)
            requests.endTurn(BridgeTurnKey(task: taskID, turn: turn), status: status)
            _ = ensureBuffer(turn, task: taskID)
            for item in params["turn"]["items"].elements {
                try receiveCompletedItem(item, record: record, turn: turn, acceptsQuestions: status == .completed)
            }
            event = ["type": .string(status.rawValue)]
            if let error = params["turn"]["error"]["message"].text {
                let message = String(error.prefix(1024))
                buffers[turn]?.failureMessage = message
                event = ["type": .string(status.rawValue), "message": .string(message)]
            }
        case "item/started", "item/completed":
            try receiveItem(item, method: method, record: record, turn: turn)
            event = ["type": .string(method), "itemType": item["type"], "itemId": item["id"]]
        case "turn/plan/updated":
            let steps = params["plan"].elements.prefix(32).map { step -> BridgeJSON in
                ["step": .string(String((step["step"].text ?? "").prefix(160))), "status": step["status"]]
            }
            event = ["type": "plan_updated", "steps": .array(steps)]
        case "item/agentMessage/delta", "item/commandExecution/outputDelta":
            guard let delta = params["delta"].text, !delta.isEmpty else { return }
            let previous = ensureBuffer(turn, task: taskID).delta
            let itemID = params["itemId"]
            if let previous, previous.kind == method, previous.item == itemID {
                let sample = (previous.text + String(delta.prefix(512))).suffix(1024)
                buffers[turn]?.delta = .init(kind: method, item: itemID, text: String(sample), since: previous.since)
            } else {
                flushDelta(turn)
                buffers[turn]?.delta = .init(kind: method, item: itemID, text: String(delta.prefix(1024)), since: Date())
            }
            return
        case "thread/status/changed":
            try applyActiveFlags(params["status"], to: taskID)
            event = ["type": "thread_status", "state": params["status"]["type"]]
        default: return
        }
        append(task: taskID, turn: turn, event: event)
    }

    private func receiveTurnStart(_ record: BridgeTaskRecord, turn: String) throws {
        guard let previous = record.latestTurnID else {
            try setStatus(.running, taskID: record.id, turnID: turn)
            return
        }
        if previous == turn {
            if !record.status.isTerminal {
                try setStatus(.running, taskID: record.id, turnID: turn)
            }
            return
        }
        guard try readTurn(in: record.id)?["id"].text == turn else { return }
        if record.status == .completed, try store.hasUnconfirmedQuestionReply(for: record) {
            try ensureQuestionsRecovered(record, turn: previous)
        } else {
            try setStatus(.running, taskID: record.id, turnID: turn)
        }
    }

    private func handleRetiredTask(_ taskID: String, turn retiring: String, method: String, message: BridgeJSON) throws {
        if message["id"].rpcID != nil {
            if let known = BridgeRPCRequest.Method(rawValue: method) {
                try connection?.answer(known, id: message["id"], result: known.declinedResult)
            } else {
                try connection?.reject(method, id: message["id"])
            }
        } else if method == "turn/completed", message["params"]["turn"]["id"].text == retiring {
            subscriptions[taskID] = nil
            _ = try call("thread/unsubscribe", ["threadId": .string(taskID)])
        }
    }

    private func receiveItem(_ item: BridgeJSON, method: String, record: BridgeTaskRecord, turn: String) throws {
        if item["type"] == "fileChange", let itemID = item["id"].text {
            let paths = method == "item/started" ? BridgeRPCRequest.changedPaths(in: item, project: record.project) : nil
            requests.recordFiles(paths, item: itemID, in: BridgeTurnKey(task: record.id, turn: turn))
        }
        if method == "item/completed" {
            _ = ensureBuffer(turn, task: record.id)
            try receiveCompletedItem(item, record: record, turn: turn, acceptsQuestions: true)
        }
    }

    private func receiveCompletedItem(_ item: BridgeJSON, record: BridgeTaskRecord, turn: String, acceptsQuestions: Bool) throws {
        buffers[turn]?.captureAnswer(item)
        guard acceptsQuestions, record.latestTurnID == turn else { return }
        for (itemID, indices) in BridgeAsyncQuestions.replyIndices(in: item) {
            if buffers[turn]?.liveReplies[itemID] == nil, buffers[turn]?.liveReplies.count == 64,
               let evicted = buffers[turn]?.liveReplies.keys.first {
                buffers[turn]?.liveReplies[evicted] = nil
                buffers[turn]?.needsHistory = true
            }
            buffers[turn]?.liveReplies[itemID, default: []].formUnion(indices)
            if let pending = requests.question(task: record.id, item: itemID), pending.turn == turn,
               case let .message(group, origin) = pending.source, group.isAnswered(by: requests.includeAnswers(buffers[turn]?.liveReplies[itemID] ?? [], for: pending.id)) {
                try closeAnsweredQuestion(group, record: record, turn: turn, origin: origin)
            }
        }
        guard let group = BridgeAsyncQuestions(item), try !store.isQuestionClosed(task: record.id, item: group.itemID, turn: turn) else { return }
        if group.isAnswered(by: buffers[turn]?.liveReplies[group.itemID]) {
            try closeAnsweredQuestion(group, record: record, turn: turn, origin: turn)
        } else {
            try receiveQuestions(group, record: record, turn: turn, origin: turn, answered: buffers[turn]?.liveReplies[group.itemID] ?? [])
        }
    }

    func closeAnsweredQuestion(_ group: BridgeAsyncQuestions, record: BridgeTaskRecord, turn: String, origin: String) throws {
        let task = record.id
        let key = try BridgeOperationKey.question(record.configurationID, task: task, origin: origin, item: group.itemID)
        let store = try store
        do {
            try store.db.transaction {
                try store.markQuestionClosed(task: task, item: group.itemID, turn: turn)
                try store.release(key)
            }
            if let request = requests.question(task: task, item: group.itemID), request.turn == turn {
                requests.close(request.id)
                append(task: task, turn: turn, event: ["type": "request_closed", "requestId": .string(request.id)])
            }
            buffers[turn]?.liveReplies[group.itemID] = nil
        } catch {
            buffers[turn]?.needsHistory = true
            throw error
        }
    }

    func receiveQuestions(_ questions: BridgeAsyncQuestions, record: BridgeTaskRecord, turn: String, origin: String, answered: Set<Int>) throws {
        guard record.latestTurnID == turn, record.status.isActive || record.status == .completed,
              requests.question(task: record.id, item: questions.itemID) == nil else { return }
        var request = BridgePendingRequest(id: UUID().uuidString, source: .message(questions, origin: origin), task: record.id, turn: turn)
        let key = try BridgeOperationKey.question(record.configurationID, task: record.id, origin: origin, item: questions.itemID)
        request.answered = answered
        request.submissionUncertain = try store.isPending(key)
        guard requests.insert(request) else {
            buffers[turn]?.hasDeferredQuestions = true
            try store.carryQuestion(task: record.id, item: questions.itemID, from: origin, to: turn)
            return
        }
        append(task: record.id, turn: turn, event: ["type": "input_requested", "requestId": .string(request.id)])
    }

    func flushDelta(_ turn: String) {
        guard let buffer = buffers[turn], let delta = buffer.delta else { return }
        buffers[turn]?.delta = nil
        append(task: buffer.task, turn: turn, event: ["type": .string(delta.kind), "itemId": delta.item, "summary": .string(delta.text)])
    }

    private func receiveRequest(_ method: String, rpcID: BridgeJSON, params: BridgeJSON, record: BridgeTaskRecord, turn: String, subscription: ThreadSubscription) throws {
        guard let method = BridgeRPCRequest.Method(rawValue: method) else {
            try connection?.reject(method, id: rpcID)
            append(task: record.id, turn: turn, event: ["type": "request_declined", "reason": "unsupported_capability"])
            return
        }
        guard let configuration = configurations.first(where: { $0.id == record.configurationID }) else {
            try connection?.reject(method.rawValue, id: rpcID)
            return
        }
        let rpc = BridgeRPCRequest(
            id: rpcID, method: method, params: params, permissions: configuration.permissions,
            project: record.project,
            changedPaths: requests.changedPaths(item: params["itemId"].text, in: BridgeTurnKey(task: record.id, turn: turn))
        )
        let request = BridgePendingRequest(id: UUID().uuidString, source: .rpc(rpc), task: record.id, turn: turn)
        guard try params.data().count <= 32 * 1024, subscription.permits(rpc), requests.insert(request) else {
            try sendRPCResponse(method.declinedResult, to: rpc)
            append(task: record.id, turn: turn, event: ["type": "request_declined", "reason": "unsupported_or_unauthorized_request"])
            return
        }
        append(task: record.id, turn: turn, event: ["type": .string(method.isApproval ? "approval_requested" : "input_requested"), "requestId": .string(request.id)])
    }

    func append(task: String, turn: String, event: BridgeJSON) {
        _ = ensureBuffer(turn, task: task)
        buffers[turn]?.append(event)
        for (id, waiter) in waiters where waiter.turn == turn {
            wake(id)
        }
    }

    func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume()
    }

    func waitForTurnUpdate(task: String, turn: String, seconds: Int) async throws {
        guard waiters.count < 128 else { throw BridgeFailure("capacity_reached") }
        let id = UUID()
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            wake(id)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiters[id] = Waiter(task: task, turn: turn, continuation: continuation) }
        } onCancel: { Task { await self.wake(id) } }
        try Task.checkCancellation()
    }

    func wait(task taskID: String, turn requestedTurn: String?, after: String?, seconds: Int, configurationID: UUID, supportsForms: Bool) async throws -> BridgeJSON {
        var record = try requireTask(taskID, configurationID: configurationID)
        if record.latestTurnID == nil {
            try refreshLatestTurnStatus(for: taskID)
            record = try requireTask(taskID, configurationID: configurationID)
        }
        let supplied = try after.map(BridgeCursor.decode)
        guard let turn = requestedTurn ?? supplied?.turn ?? record.latestTurnID else { throw BridgeFailure("turn_not_found") }
        if let supplied, supplied.task != taskID || supplied.turn != turn {
            throw BridgeFailure("invalid_cursor")
        }
        var details = try turnDetails(for: turn, in: record)
        let buffer = ensureBuffer(turn, task: taskID)
        var cursor = supplied ?? BridgeCursor(epoch: buffer.epoch, task: taskID, turn: turn, sequence: buffer.sequence)
        let expired = cursor.epoch != buffer.epoch || !(buffer.sequence - buffer.events.count ... buffer.sequence).contains(cursor.sequence)
        if expired {
            cursor = BridgeCursor(epoch: buffer.epoch, task: taskID, turn: turn, sequence: buffer.sequence)
        }
        let key = BridgeTurnKey(task: taskID, turn: turn)
        if !details.status.isTerminal, subscriptions[taskID]?.isTrackingTask != true {
            do {
                try restoreForObservation(record)
            } catch is CancellationError { throw CancellationError() } catch {}
            record = try requireTask(taskID, configurationID: configurationID)
            details = try turnDetails(for: turn, in: record)
        }
        var history = try recoverHistoryIfNeeded(record: record, turn: turn, state: details.status, knownEntry: details.entry)
        let caughtUp = supplied != nil && !expired && cursor.sequence == buffers[turn]?.sequence && !requests.hasPending(in: key)
        if case let .retry(at) = history, caughtUp, seconds == 0, let previous = buffer.historyRetry, previous.deadline > .now {
            throw BridgeFailure("history_retry_later", "Retry codex_wait with the same cursor after \(Self.retrySeconds(until: at)) seconds.")
        }
        let delay = switch history {
        case let .retry(at): min(seconds, Self.retrySeconds(until: at))
        case .ready where buffers[turn]?.hasDeferredQuestions == true: min(seconds, 1)
        case .ready where !details.status.isTerminal: seconds
        default: 0
        }
        if caughtUp, delay > 0 {
            try await waitForTurnUpdate(task: taskID, turn: turn, seconds: delay)
            record = try requireTask(taskID, configurationID: configurationID)
            details = try turnDetails(for: turn, in: record)
            history = try recoverHistoryIfNeeded(record: record, turn: turn, state: details.status, knownEntry: details.entry)
        }
        if requestedTurn == nil, supplied == nil, let latest = try taskRecord(for: taskID)?.latestTurnID, latest != turn {
            return try await wait(task: taskID, turn: latest, after: nil, seconds: 0, configurationID: configurationID, supportsForms: supportsForms)
        }
        return snapshot(key, state: details.status, cursor: cursor, expired: expired, history: history, supportsForms: supportsForms)
    }

    private static func retrySeconds(until at: ContinuousClock.Instant) -> Int {
        max(1, Int(ceil(TimeInterval(ContinuousClock.now.duration(to: at)))))
    }

    private func snapshot(_ key: BridgeTurnKey, state: BridgeTurnStatus, cursor: BridgeCursor, expired: Bool, history: BridgeHistoryStatus, supportsForms: Bool) -> BridgeJSON {
        let (taskID, turn) = (key.task, key.turn)
        var cursor = cursor
        let buffer = ensureBuffer(turn, task: taskID)
        var lost = expired
        if cursor.epoch != buffer.epoch {
            cursor = BridgeCursor(epoch: buffer.epoch, task: taskID, turn: turn, sequence: buffer.sequence)
            lost = true
        }
        if cursor.sequence < buffer.sequence - buffer.events.count {
            cursor.sequence = buffer.sequence - buffer.events.count
            lost = true
        }
        let (events, moreEvents) = buffer.page(from: &cursor)
        let (result, moreText) = state == .completed && history == .ready ? buffer.result(from: &cursor) : (.null, false)
        let pending = requests.forTurn(key)
        var fields: [String: BridgeJSON] = [
            "taskId": .string(taskID),
            "turnId": .string(turn),
            "status": .string(pending.contains(where: \.blocking) ? BridgeTurnStatus.waiting.rawValue : state.rawValue),
            "events": .array(events),
            "nextCursor": cursor.encoded,
            "hasMore": .bool(moreEvents || moreText || history == .more),
            "pendingRequests": .array(pending.map(\.info))
        ]
        if history == .ready, state.isTerminal || subscriptions[taskID]?.isTrackingTask == true {
            fields["freshness"] = "current"
        } else {
            fields["freshness"] = "reconciling"
        }
        if case let .retry(at) = history {
            fields["hasMore"] = .bool(true)
            fields["retryAfterSeconds"] = .integer(Self.retrySeconds(until: at))
        } else if history == .unavailable {
            fields["resultWarning"] = "history_unavailable"
        }
        if buffer.hasDeferredQuestions {
            fields["pendingRequestWarning"] = "question_capacity_reached"
            if history == .ready {
                fields["hasMore"] = .bool(true)
                fields["retryAfterSeconds"] = .integer(1)
            }
        }
        if lost {
            fields["warning"] = "cursor_expired"
        }
        if state == .completed {
            fields["result"] = result
            fields["resultAvailable"] = .bool(history == .ready && buffer.answer?.text != nil)
            if history == .ready, let answer = buffer.answer, answer.text == nil {
                fields["resultWarning"] = "result_too_large"
            }
        }
        if let failure = buffer.failureMessage, state == .failed {
            fields["failureMessage"] = .string(failure)
        }
        let actionable = pending.filter { !$0.submissionUncertain && (!($0.isMessageQuestion && state == .completed) || history == .ready) }
        if let first = actionable.first, supportsForms {
            fields["nextAction"] = ["tool": "codex_respond", "arguments": ["taskId": .string(taskID), "requestId": .string(first.id)]]
        }
        if !supportsForms, !actionable.isEmpty {
            fields["formRequired"] = .string(Self.formRequiredMessage(canInterrupt: state.isActive))
        }
        return .object(fields)
    }
}
