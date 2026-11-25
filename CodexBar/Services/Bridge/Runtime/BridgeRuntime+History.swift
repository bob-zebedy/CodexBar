import Foundation

/// 先读当前轮次的答复, 再回到原轮次读取随追问保留下来的题目
nonisolated struct BridgeHistoryScan {
    var turns: [String]
    var cursor: String?
    var pageSize = 8
    var checkpoint: String?
    var interval = 1
    var distance = 0
    var answer: BridgeTurnEvents.CapturedAnswer?
    let answerRevision: Int
    var successor: BridgeJSON?
    var confirmed: (item: String, key: BridgeOperationKey)?
    var answered: [String: Set<Int>] = [:]

    mutating func advance(to next: String?) throws {
        guard let next else {
            turns.removeLast()
            cursor = nil
            checkpoint = nil
            interval = 1
            distance = 0
            return
        }
        guard next != cursor, next != checkpoint else { throw BridgeFailure("invalid_history_cursor") }
        distance += 1
        if distance == interval {
            // 递增检查间隔, 用一个游标检测跨页循环
            checkpoint = next
            distance = 0
            interval *= 2
        }
        cursor = next
    }
}

nonisolated enum BridgeHistoryStatus: Equatable {
    case ready, more, retry(at: ContinuousClock.Instant), unavailable
}

nonisolated struct BridgeHistoryRetry {
    private static let limit = 3
    private let attempt: Int
    let deadline: ContinuousClock.Instant

    init(after previous: Self?, minimumDelay: TimeInterval) {
        attempt = (previous?.attempt ?? 0) % Self.limit + 1
        deadline = ContinuousClock.now.advanced(by: .seconds(max(minimumDelay, Double(1 << (attempt - 1)))))
    }

    var status: BridgeHistoryStatus {
        attempt == Self.limit ? .unavailable : .retry(at: deadline)
    }
}

extension BridgeRuntime {
    func recoverHistoryIfNeeded(record: BridgeTaskRecord, turn: String, state: BridgeTurnStatus, knownEntry: BridgeJSON?) throws -> BridgeHistoryStatus {
        var buffer = ensureBuffer(turn, task: record.id)
        if buffer.historyUnavailable {
            return .unavailable
        }
        if buffer.hasDeferredQuestions, requests.hasQuestionCapacity {
            buffer.hasDeferredQuestions = false
            buffer.historyScan = nil
            buffer.needsHistory = true
            buffers[turn] = buffer
        }
        if let retry = buffer.historyRetry, retry.deadline > .now {
            return retry.status
        }
        do {
            let history = try readHistory(record: record, turn: turn, state: state, knownEntry: knownEntry, buffer: buffer)
            buffers[turn]?.historyRetry = nil
            return history
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as BridgeFailure where failure.code != "bridge_reconnecting" {
            if ["invalid_history_cursor", "history_item_too_large"].contains(failure.code) {
                buffers[turn]?.historyUnavailable = true
                buffers[turn]?.historyScan = nil
            }
            return .unavailable
        } catch {
            let retry = BridgeHistoryRetry(after: buffer.historyRetry, minimumDelay: retrySeconds)
            buffers[turn]?.historyRetry = retry
            return retry.status
        }
    }

    func ensureQuestionsRecovered(_ record: BridgeTaskRecord, turn: String) throws {
        let history = try recoverHistoryIfNeeded(record: record, turn: turn, state: record.status, knownEntry: nil)
        guard history == .ready else { throw BridgeFailure("history_reconciling", "Continue codex_wait before submitting this form.") }
    }

    private func readHistory(record: BridgeTaskRecord, turn: String, state: BridgeTurnStatus, knownEntry: BridgeJSON?, buffer: BridgeTurnEvents) throws -> BridgeHistoryStatus {
        if state == .failed {
            if buffer.failureMessage == nil, !buffer.terminalHistoryRead {
                guard let entry = try knownEntry ?? readTurn(in: record.id, .matching(turn)) else { return .unavailable }
                buffers[turn]?.failureMessage = entry["error"]["message"].text.map { String($0.prefix(1024)) }
                buffers[turn]?.terminalHistoryRead = true
            }
            return .ready
        }
        let pending = requests.forTurn(.init(task: record.id, turn: turn))
        let unconfirmed = pending.contains(where: \.submissionUncertain)
        let completedForms = state == .completed && !buffer.terminalHistoryRead && pending.contains(where: \.isMessageQuestion)
        let questions = record.latestTurnID == turn && (state.isActive || state == .completed) && (buffer.needsHistory || unconfirmed || completedForms)
        let result = state == .completed && !buffer.terminalHistoryRead && (buffer.answer == nil || buffer.needsHistory)
        guard questions || result || buffer.historyScan != nil else { return .ready }
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(5))
        return try AppServerRequestBudget.$current.withValue(budget) {
            let saved = questions ? try store.questionState(task: record.id, turn: turn) : nil
            var scan = try buffer.historyScan ?? beginHistoryScan(record: record, turn: turn, carried: saved?.carried, state: state)
            var reader: (any BridgeUpstream)?
            defer { reader?.close() }
            for _ in 0 ..< 16 {
                guard let origin = scan.turns.last else { break }
                let page = try historyPage(task: record.id, turn: turn, origin: origin, scan: &scan, reader: &reader, budget: budget)
                for entry in page["data"].elements where entry["turnId"].text == origin {
                    let item = entry["item"]
                    if origin == turn {
                        BridgeTurnEvents.selectAnswer(item, newestFirst: true, into: &scan.answer)
                    }
                    guard let saved else { continue }
                    try recoverQuestion(item, in: origin, for: record, turn: turn, saved: saved, scan: &scan)
                }
                if !questions, scan.answer?.isExplicit == true {
                    scan.turns.removeAll()
                    break
                }
                try scan.advance(to: page["nextCursor"].text)
                buffers[turn]?.historyScan = scan
            }
            guard scan.turns.isEmpty else { return .more }
            try commitConfirmedReply(scan, record: record, turn: turn)
            buffers[turn]?.finishHistoryAnswer(scan.answer, since: scan.answerRevision)
            buffers[turn]?.historyScan = nil
            buffers[turn]?.needsHistory = scan.successor != nil && scan.confirmed == nil
            if state == .completed {
                buffers[turn]?.terminalHistoryRead = true
            }
            return .ready
        }
    }

    private func commitConfirmedReply(_ scan: BridgeHistoryScan, record: BridgeTaskRecord, turn: String) throws {
        guard let successor = scan.successor, let next = successor["id"].text, let confirmed = scan.confirmed,
              try taskRecord(for: record.id)?.latestTurnID == turn, try store.isPending(confirmed.key) else { return }
        var updated = record
        updated.latestTurnID = next
        updated.status = BridgeTurnStatus(upstream: successor["status"])
        updated.updated = Date()
        let cursor = BridgeCursor(epoch: ensureBuffer(next, task: record.id).epoch, task: record.id, turn: next, sequence: 0)
        try commitInput(confirmed.key, cursor: cursor, updatedTask: updated, previous: turn, answered: confirmed.item)
        if let request = requests.question(task: record.id, item: confirmed.item) {
            requests.close(request.id)
        }
    }

    private func historyPage(task: String, turn: String, origin: String, scan: inout BridgeHistoryScan, reader: inout (any BridgeUpstream)?, budget: AppServerRequestBudget) throws -> BridgeJSON {
        var params: [String: BridgeJSON] = ["threadId": .string(task), "turnId": .string(origin), "sortDirection": "desc"]
        if let cursor = scan.cursor {
            params["cursor"] = .string(cursor)
        }
        let initialSize = scan.pageSize
        defer {
            if scan.pageSize != initialSize {
                buffers[turn]?.historyScan = scan
            }
        }
        do {
            return try budget.readPage(limit: &scan.pageSize) {
                reader?.close()
                reader = nil
            } read: { limit in
                params["limit"] = .integer(limit)
                let connection = try reader ?? connect()
                reader = connection
                return try connection.call("thread/items/list", .object(params))
            }
        } catch AppServerError.messageTooLarge {
            throw BridgeFailure("history_item_too_large")
        } catch let AppServerError.serverError(error) {
            throw BridgeFailure("codex_rejected", error.message)
        }
    }

    private func beginHistoryScan(record: BridgeTaskRecord, turn: String, carried: [String: Set<String>]?, state: BridgeTurnStatus) throws -> BridgeHistoryScan {
        var turns = (carried?.keys.filter { $0 != turn }.sorted() ?? []) + [turn]
        // 已结束轮次的表单答复可能落在新轮次, 只读取其回复标识以核对投递
        var successor: BridgeJSON?
        if carried != nil, state == .completed, try store.hasUnconfirmedQuestionReply(for: record),
           let entry = try readTurn(in: record.id, .following(turn)), let latest = entry["id"].text {
            successor = entry
            turns.append(latest)
        }
        return BridgeHistoryScan(turns: turns, answerRevision: buffers[turn]?.answerRevision ?? 0, successor: successor)
    }

    private func recoverQuestion(
        _ item: BridgeJSON, in origin: String, for record: BridgeTaskRecord, turn: String,
        saved: (closed: Set<String>, carried: [String: Set<String>]), scan: inout BridgeHistoryScan
    ) throws {
        for (itemID, indices) in BridgeAsyncQuestions.replyIndices(in: item) {
            if origin == scan.successor?["id"].text {
                let source = saved.carried.first { $0.value.contains(itemID) }?.key ?? turn
                let key = try BridgeOperationKey.question(record.configurationID, task: record.id, origin: source, item: itemID)
                for part in item["content"].elements {
                    if let text = part["text"].text, try store.hasPendingReply(key, message: text) {
                        scan.confirmed = (itemID, key)
                    }
                }
            }
            scan.answered[itemID, default: []].formUnion(indices)
            if scan.confirmed?.item != itemID, let request = requests.question(task: record.id, item: itemID), request.turn == turn,
               case let .message(group, questionOrigin) = request.source, origin == turn || questionOrigin == origin,
               group.isAnswered(by: requests.includeAnswers(indices, for: request.id)) {
                try closeAnsweredQuestion(group, record: record, turn: turn, origin: questionOrigin)
            }
        }
        guard let group = BridgeAsyncQuestions(item), !saved.closed.contains(group.itemID),
              origin == turn || saved.carried[origin]?.contains(group.itemID) == true else { return }
        let answered = (scan.answered[group.itemID] ?? []).union(buffers[turn]?.liveReplies[group.itemID] ?? [])
        if scan.confirmed?.item == group.itemID {
            return
        }
        let combined = requests.question(task: record.id, item: group.itemID).map { requests.includeAnswers(answered, for: $0.id) } ?? answered
        if group.isAnswered(by: combined) {
            try closeAnsweredQuestion(group, record: record, turn: turn, origin: origin)
        } else {
            try receiveQuestions(group, record: record, turn: turn, origin: origin, answered: combined)
        }
    }
}
