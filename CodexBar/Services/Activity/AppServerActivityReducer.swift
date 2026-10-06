import Foundation

/// 将协议事件映射为既有业务阶段, 快照核对与实时统计分别处理
nonisolated struct AppServerActivityReducer {
    var threads: [String: ActivityThread] = [:]
    var states: [ActivityTurnReference: SessionLifecycleState] = [:]
    private var childRoots: [String: (session: String, turn: String)] = [:]
    private var threadTotals: [String: TokenUsage] = [:]
    private var tokenStreamID = UUID().uuidString.lowercased()
    private var tokenSequences: [String: Int64] = [:]
    private(set) var tokenObservations: [TokenObservation] = []
    private var seenEvents: [String: Date] = [:]
    private var approvals: [String: ActivityTurnReference] = [:]
    private var waitingSince: [String: Date] = [:]
    private var toolItems: [String: (item: ActivityItem, at: Date)] = [:]
    private var observingSince = Date.distantPast
    private(set) var tokenTurns: [TokenTurn] = []

    mutating func reconnect(now: Date = Date()) {
        // 断线期间的累计变化没有完整轮次归属, 重新建立基线, 不归入重连后的轮次
        threadTotals.removeAll()
        tokenStreamID = UUID().uuidString.lowercased()
        tokenSequences.removeAll()
        approvals.removeAll()
        waitingSince.removeAll()
        observingSince = now
    }

    mutating func invalidateThread(_ id: String) {
        threads[id]?.status = ActivityThreadStatus(type: "notLoaded")
        for key in states.keys where key.threadID == id && states[key]?.terminal == nil {
            states[key]?.readStatus = .unavailable
        }
    }

    mutating func invalidateTokenBaseline(_ id: String) {
        threadTotals.removeValue(forKey: id)
    }

    mutating func markNewThread(_ id: String) {
        if threadTotals[id] == nil {
            threadTotals[id] = .zero
        }
    }

    mutating func takeTokenObservations() -> [TokenObservation] {
        defer { tokenObservations.removeAll(keepingCapacity: true) }
        return tokenObservations
    }

    mutating func acceptTokenTurns(_ turns: [TokenTurn]) {
        tokenTurns = turns
        let records = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        for key in states.keys {
            states[key]?.tokenUsage = records[TokenTurn.identifier(thread: key.threadID, turn: key.turnID)]?.usage
        }
    }

    mutating func restoreTokenTurns(_ turns: [TokenTurn]) {
        tokenTurns = turns
        threadTotals.removeAll()
        let records = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        for key in states.keys {
            states[key]?.tokenUsage = records[TokenTurn.identifier(thread: key.threadID, turn: key.turnID)]?.usage
        }
    }

    mutating func reconcile(thread: ActivityThread, turns: [ActivityTurn], reviewer: ApprovalReviewer?, now: Date, bootstrap: Bool = false) -> [ActivityRecord] {
        var thread = thread
        // thread/read 不返回完整配置, 保留 resume 和 settings 通知提供的模型上下文
        thread.model = thread.model ?? threads[thread.id]?.model
        thread.reasoningEffort = thread.reasoningEffort ?? threads[thread.id]?.reasoningEffort
        threads[thread.id] = thread
        var events: [ActivityRecord] = []
        for turn in turns {
            let reference = reference(thread.id, turn.id, at: turn.startedAt.map(Date.init(timeIntervalSince1970:)) ?? now)
            let existed = states[reference] != nil
            updateTurn(turn, threadID: thread.id, reviewer: reviewer, now: now, historical: true)
            if !existed || bootstrap, turn.status == "inProgress", thread.status?.type == "active" {
                events.append(event(.turnStarted, threadID: thread.id, turnID: turn.id, at: reference.startedAt))
            }
        }
        updateWaiting(threadID: thread.id, status: thread.status, now: now)
        resolveRoots()
        return events
    }

    mutating func consume(_ notification: ActivityNotification, now: Date) -> [ActivityRecord] {
        let category = ActivityNotification.category(for: notification.method)
        guard category != .ignored else { return [] }
        let params = notification.params
        guard let threadID = params.threadId ?? params.thread?.id else { return [] }
        let wasKnown = threads[threadID] != nil
        if let thread = params.thread {
            threads[threadID] = thread
        }
        guard threads[threadID] != nil else { return [] }
        let date = (params.completedAtMs ?? params.startedAtMs).map { Date(timeIntervalSince1970: $0 / 1000) } ?? now
        let turnID = params.turnId ?? params.turn?.id ?? activeReference(threadID)?.turnID
        var events: [ActivityRecord] = []
        switch notification.method {
        case "thread/started":
            if !wasKnown, let created = params.thread?.createdAt, created >= floor(observingSince.timeIntervalSince1970) {
                markNewThread(threadID)
            }
        case "thread/settings/updated":
            updateSettings(params.threadSettings, threadID: threadID, now: now)
        case "thread/status/changed":
            threads[threadID]?.status = params.status
            updateWaiting(threadID: threadID, status: params.status, now: now)
        case "turn/started", "turn/completed":
            guard let turn = params.turn, ["inProgress", "completed", "failed", "interrupted"].contains(turn.status) else { break }
            events.append(turnEvent(turn, threadID: threadID, now: now))
        case "item/started", "item/completed":
            if let turnID, let item = params.item {
                events += itemEvents(item, method: notification.method, threadID: threadID, turnID: turnID, at: date)
            }
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            guard let turnID else { break }
            let reference = reference(threadID, turnID, at: date)
            if let id = notification.id?.identifier {
                approvals[id] = reference
            }
            events.append(event(
                .approvalRequested,
                threadID: threadID,
                turnID: turnID,
                at: date,
                item: approvalItem(params.itemId, threadID: threadID, turnID: turnID, method: notification.method),
                identity: params.itemId ?? notification.id?.identifier,
                reviewer: .user
            ))
            states[reference]?.isWaitingApproval = true
            states[reference]?.approvalChangedAt = waitingSince[threadID] ?? date
        case "item/autoApprovalReview/started":
            guard let turnID else { break }
            events.append(event(
                .approvalRequested,
                threadID: threadID,
                turnID: turnID,
                at: date,
                identity: params.targetItemId ?? params.reviewId,
                reviewer: .autoReview
            ))
        case "serverRequest/resolved":
            if let id = params.requestId?.identifier, let reference = approvals.removeValue(forKey: id),
               !approvals.values.contains(reference) {
                states[reference]?.isWaitingApproval = false
                states[reference]?.approvalChangedAt = now
            }
        case "thread/tokenUsage/updated":
            if let turnID, let usage = params.tokenUsage {
                updateUsage(threadID: threadID, turnID: turnID, update: usage, now: now)
            }
        default:
            if category == .progress, let turnID {
                progress(threadID, turnID, at: now)
            }
        }
        resolveRoots()
        prune(now: now)
        return finish(events, notification: notification, threadID: threadID, turnID: turnID, now: now)
    }

    private mutating func finish(
        _ events: [ActivityRecord], notification: ActivityNotification,
        threadID: String, turnID: String?, now: Date
    ) -> [ActivityRecord] {
        let source = source(notification, threadID: threadID, turnID: turnID)
        return events.map { value in
            var value = value
            value.source = source
            return value
        }.filter { value in
            guard let id = value.id else { return false }
            guard seenEvents[id] == nil else { return false }
            seenEvents[id] = now
            return true
        }
    }

    private func source(_ notification: ActivityNotification, threadID: String, turnID: String?) -> AppServerEventSource {
        let params = notification.params
        let state = turnID.flatMap { states[reference(threadID, $0, at: .distantPast)] }
        let item = params.item ?? turnID.flatMap {
            approvalItem(params.itemId, threadID: threadID, turnID: $0, method: notification.method)
        }
        return AppServerEventSource(
            method: notification.method, threadID: threadID, turnID: turnID,
            parentThreadID: threads[threadID]?.parentID,
            rootThreadID: state?.rootSessionID, rootTurnID: state?.rootTurnID,
            itemID: params.item?.id ?? params.itemId ?? params.targetItemId,
            itemType: item?.type, itemStatus: params.item?.status,
            agentThreadID: params.item?.agentThreadId, itemKind: params.item?.kind,
            requestID: notification.id?.identifier ?? params.requestId?.identifier,
            reviewID: params.reviewId, turnStatus: params.turn?.status,
            turnStartedAt: params.turn?.startedAt.map(Date.init(timeIntervalSince1970:)),
            turnCompletedAt: params.turn?.completedAt.map(Date.init(timeIntervalSince1970:)),
            durationMs: params.turn?.durationMs
        )
    }

    private mutating func turnEvent(_ turn: ActivityTurn, threadID: String, now: Date) -> ActivityRecord {
        updateTurn(turn, threadID: threadID, reviewer: nil, now: now, historical: false)
        if turn.status != "inProgress", threadTotals[threadID] == .zero {
            // 未观察到本轮用量就已结束, 零基线不能把漏掉的消耗算到下一轮
            threadTotals.removeValue(forKey: threadID)
        }
        let phase: ActivityEventKind = turn.status == "inProgress" ? .turnStarted : turn.status == "completed" ? .turnCompleted : .turnAborted
        let timestamp = (turn.status == "inProgress" ? turn.startedAt : turn.completedAt).map(Date.init(timeIntervalSince1970:)) ?? now
        return event(phase, threadID: threadID, turnID: turn.id, at: timestamp)
    }

    private mutating func prune(now: Date) {
        let retainedDate = HistoryStorage.retentionCutoffDate(today: now)
        let retainedRoots = Set(tokenTurns.filter { $0.updatedAt >= retainedDate }.map(\.rootID))
        tokenTurns = tokenTurns.filter { $0.updatedAt >= retainedDate || retainedRoots.contains($0.id) }
        let cutoff = now.addingTimeInterval(-ActivityRetention.window)
        seenEvents = seenEvents.filter { $0.value > cutoff }
        toolItems = toolItems.filter { $0.value.at > cutoff }
        states = states.filter { $0.value.terminal == nil || ($0.value.lastProgressAt ?? .distantPast) > cutoff }
    }

    private mutating func updateSettings(_ settings: ActivityNotification.Settings?, threadID: String, now: Date) {
        if let settings, var thread = threads[threadID] {
            thread.model = settings.model ?? thread.model
            thread.reasoningEffort = settings.effort
            thread.cwd = settings.cwd ?? thread.cwd
            threads[threadID] = thread
            for key in states.keys where key.threadID == threadID && states[key]?.terminal == nil {
                states[key]?.effort = settings.effort
                if let reviewer = settings.approvalsReviewer?.value {
                    states[key]?.approvalReviewer = reviewer
                }
                states[key]?.contextObservedAt = now
            }
        }
    }

    private mutating func itemEvents(_ item: ActivityItem, method: String, threadID: String, turnID: String, at date: Date) -> [ActivityRecord] {
        var events: [ActivityRecord] = []
        progress(threadID, turnID, at: date)
        let starting = method == "item/started"
        if item.isToolCall {
            toolItems["\(threadID):\(turnID):\(item.id)"] = (item, date)
            events.append(event(starting ? .toolStarted : .toolCompleted, threadID: threadID, turnID: turnID, at: date, item: item))
        } else if item.type == "contextCompaction" {
            events.append(event(starting ? .compactionStarted : .compactionCompleted, threadID: threadID, turnID: turnID, at: date, item: item))
        } else if !starting, item.type == "subAgentActivity", ["started", "completed", "interrupted"].contains(item.kind ?? "") {
            // interacted 只是活动, 不代表创建或结束子 Agent
            events.append(event(
                item.kind == "started" ? .subagentStarted : .subagentEnded,
                threadID: threadID,
                turnID: turnID,
                at: date,
                item: item
            ))
        }
        return events
    }

    private func approvalItem(_ id: String?, threadID: String, turnID: String, method: String) -> ActivityItem? {
        guard let id else { return nil }
        if let known = toolItems["\(threadID):\(turnID):\(id)"] {
            return known.item
        }
        if method == "item/commandExecution/requestApproval" {
            return ActivityItem(id: id, type: "commandExecution")
        }
        if method == "item/fileChange/requestApproval" {
            return ActivityItem(id: id, type: "fileChange")
        }
        return nil
    }

    private mutating func updateTurn(_ turn: ActivityTurn, threadID: String, reviewer: ApprovalReviewer?, now: Date, historical: Bool) {
        let start = turn.startedAt.map(Date.init(timeIntervalSince1970:))
        let reference = reference(threadID, turn.id, at: start ?? now)
        let previous = states[reference]
        let terminal: SessionTerminalState?
        let isTerminal = ["completed", "failed", "interrupted"].contains(turn.status)
        let isLoaded = ["active", "idle"].contains(threads[threadID]?.status?.type ?? "")
        if isTerminal, turn.completedAt != nil || !historical || isLoaded {
            let date = turn.completedAt.map(Date.init(timeIntervalSince1970:))
            if turn.status == "completed" {
                var reportedAt = date
                var duration = turn.durationMs.map { $0 / 1000 }
                if case let .completed(previousAt, previousDuration) = previous?.terminal {
                    reportedAt = reportedAt ?? previousAt
                    duration = duration ?? previousDuration
                }
                terminal = .completed(at: reportedAt, duration: duration)
            } else if case let .aborted(previousAt) = previous?.terminal {
                terminal = .aborted(at: date ?? previousAt)
            } else {
                terminal = .aborted(at: date)
            }
        } else {
            terminal = previous?.terminal
        }
        var state = SessionLifecycleState(
            requestedThreadID: threadID, turnID: turn.id, startedAt: start,
            approvalReviewer: reviewer ?? previous?.approvalReviewer,
            effort: threads[threadID]?.reasoningEffort, lastProgressAt: previous?.lastProgressAt ?? start,
            terminal: terminal, readStatus: terminal == nil && (!isLoaded || turn.status != "inProgress") ? .unavailable : .complete,
            hasContext: true, contextObservedAt: now, rootTurnID: previous?.rootTurnID,
            recordedThreadID: threadID, rootSessionID: previous?.rootSessionID,
            parentThreadID: threads[threadID]?.parentID,
            lastExecutionProgressAt: previous?.lastExecutionProgressAt,
            tokenUsage: previous?.tokenUsage ?? tokenTurns.first(where: { $0.id == TokenTurn.identifier(thread: threadID, turn: turn.id) })?.usage,
            isHistoricalTerminal: previous?.terminal == nil ? historical : previous?.isHistoricalTerminal ?? historical,
            isWaitingApproval: previous?.isWaitingApproval, approvalChangedAt: previous?.approvalChangedAt
        )
        if terminal != nil {
            state.terminalObservedAt = previous?.terminalObservedAt ?? now
            state.lastProgressAt = turn.completedAt.map(Date.init(timeIntervalSince1970:)) ?? state.terminalObservedAt
        }
        states[reference] = state
    }

    private mutating func updateWaiting(threadID: String, status: ActivityThreadStatus?, now: Date) {
        guard let status, status.type == "active" || status.type == "idle" else { return }
        if status.isWaiting, waitingSince[threadID] == nil {
            waitingSince[threadID] = now
        }
        for key in states.keys where key.threadID == threadID && states[key]?.terminal == nil {
            if states[key]?.isWaitingApproval != status.isWaiting {
                states[key]?.approvalChangedAt = waitingSince[threadID] ?? now
            }
            states[key]?.isWaitingApproval = status.isWaiting
        }
        if !status.isWaiting {
            waitingSince.removeValue(forKey: threadID)
        }
    }

    private mutating func progress(_ threadID: String, _ turnID: String, at date: Date) {
        let key = reference(threadID, turnID, at: date)
        let lastProgress = states[key]?.lastProgressAt ?? .distantPast
        states[key]?.lastProgressAt = max(lastProgress, date)
        // 输出增量是执行进展, 但等待中的其他并发请求仍由服务端状态裁决
        states[key]?.lastExecutionProgressAt = date
    }

    private mutating func resolveRoots() {
        for _ in 0 ..< 16 {
            var changed = false
            for key in states.keys {
                guard var state = states[key], state.rootTurnID == nil else { continue }
                if let parent = threads[key.threadID]?.parentID {
                    if let root = childRoots[key.threadID] {
                        state.rootTurnID = root.turn
                        state.rootSessionID = root.session
                        states[key] = state
                        changed = true
                        continue
                    }
                    guard let start = threads[key.threadID]?.createdAt.map(Date.init(timeIntervalSince1970:)) ?? state.startedAt,
                          let ancestor = states.values.filter({
                              $0.requestedThreadID == parent && ($0.startedAt ?? .distantFuture) <= start
                          }).max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }),
                          let rootTurn = ancestor.rootTurnID, let rootSession = ancestor.rootSessionID else { continue }
                    state.rootTurnID = rootTurn
                    state.rootSessionID = rootSession
                    childRoots[key.threadID] = (rootSession, rootTurn)
                } else if threads[key.threadID]?.origin == .main || threads[key.threadID]?.origin == .autoReview {
                    state.rootTurnID = key.turnID
                    state.rootSessionID = key.threadID
                } else {
                    continue
                }
                states[key] = state
                changed = true
            }
            if !changed {
                break
            }
        }
    }

    private func reference(_ threadID: String, _ turnID: String, at date: Date) -> ActivityTurnReference {
        ActivityTurnReference(threadID: threadID, turnID: turnID, startedAt: date)
    }

    private func activeReference(_ threadID: String) -> ActivityTurnReference? {
        states.keys.filter { $0.threadID == threadID && states[$0]?.terminal == nil }.max { $0.startedAt < $1.startedAt }
    }

    private func event(
        _ phase: ActivityEventKind, threadID: String, turnID: String, at date: Date,
        item: ActivityItem? = nil, identity: String? = nil, reviewer: ApprovalReviewer? = nil
    ) -> ActivityRecord {
        let thread = threads[threadID]
        let state = states[reference(threadID, turnID, at: date)]
        let isChild = thread?.parentID != nil
        let agentID = item?.agentThreadId ?? (isChild ? threadID : nil)
        let eventTurn = item?.agentThreadId.flatMap { activeReference($0)?.turnID } ?? turnID
        return ActivityRecord(
            timestamp: date, name: phase.rawValue, origin: thread?.origin ?? .unknown,
            cwd: thread?.cwd, tool: item?.toolDisplayName, model: thread?.model,
            effort: thread?.reasoningEffort, approvalReviewer: reviewer ?? state?.approvalReviewer,
            sessionID: isChild ? state?.rootSessionID : threadID, turnID: eventTurn, agentID: agentID,
            id: [threadID, turnID, item?.id ?? identity ?? "turn", phase.rawValue].joined(separator: ":")
        )
    }

    private mutating func updateUsage(threadID: String, turnID: String, update: ActivityTokenUpdate, now: Date) {
        let total = update.total.usage
        guard total.isValid else { return }
        defer { threadTotals[threadID] = total }
        guard let previous = threadTotals[threadID], let delta = total.subtracting(previous), delta != .zero else { return }
        let key = reference(threadID, turnID, at: now)
        guard let state = states[key], let rootSession = state.rootSessionID, let rootTurn = state.rootTurnID else { return }
        let id = TokenTurn.identifier(thread: threadID, turn: turnID)
        let existing = tokenTurns.first { $0.id == id }
        let sequence = (tokenSequences[id] ?? 0) + 1
        tokenSequences[id] = sequence
        let rootKey = reference(rootSession, rootTurn, at: now)
        let metadata = TokenTurn(
            id: id,
            rootID: TokenTurn.identifier(thread: rootSession, turn: rootTurn),
            startedAt: state.startedAt,
            updatedAt: now
        )
        let observation = TokenObservation(
            turn: metadata,
            rootStartedAt: states[rootKey]?.startedAt,
            streamID: tokenStreamID,
            sequence: sequence,
            previous: previous,
            current: total
        )
        tokenObservations.append(observation)
        guard let record = try? observation.applying(to: existing) else { return }
        states[key]?.tokenUsage = record.usage
        tokenTurns.removeAll { $0.id == id }
        tokenTurns.append(record)
        if record.rootID != id, !tokenTurns.contains(where: { $0.id == record.rootID }), let root = states[rootKey] {
            tokenTurns.append(TokenTurn(id: record.rootID, rootID: record.rootID, startedAt: root.startedAt, updatedAt: now, usage: nil))
        }
    }
}
