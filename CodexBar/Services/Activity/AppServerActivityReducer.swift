import Foundation

/// 将协议事件映射为既有业务阶段, 快照核对与实时统计分别处理
nonisolated struct AppServerActivityReducer {
    var threads: [String: ActivityThread] = [:]
    var states: [ActivityTurnReference: SessionLifecycleState] = [:]
    private struct SubagentContext {
        let parent: ActivityTurnReference
        let model: String?
        let effort: String?
    }

    private var subagentContexts: [String: SubagentContext] = [:]
    private struct PendingUsage {
        var usage: TokenUsage
        var updatedAt: Date
    }

    private var pendingUsage: [ActivityTurnReference: PendingUsage] = [:]
    private var threadTotals: [String: TokenUsage] = [:]
    /// 淘汰内存序列后重新观察时使用新流身份, 防止与磁盘检查点冲突
    private struct TokenStream {
        let id = UUID().uuidString.lowercased()
        var sequence: Int64 = 0
    }

    private var tokenStreams: [String: TokenStream] = [:]
    private var threadLastObserved: [String: Date] = [:]
    private var loadedThreads = Set<String>()
    private var lastHistoryCutoff: Date?
    private var lastTransientPrune = Date.distantPast
    private(set) var tokenObservations: [TokenObservation] = []
    private var seenEvents: [String: Date] = [:]
    private var approvals: [String: ActivityTurnReference] = [:]
    private var waitingSince: [String: Date] = [:]
    private var observingSince = Date.distantPast
    private(set) var tokenTurns: [String: TokenTurn] = [:]
    private var isTokenRecordingEnabled = true

    mutating func setTokenRecordingEnabled(_ enabled: Bool) {
        guard enabled != isTokenRecordingEnabled else { return }
        isTokenRecordingEnabled = enabled
        // 丢弃采集中断前的累计基线与待关联增量, 新观测使用独立流身份
        threadTotals.removeAll()
        tokenStreams.removeAll()
        pendingUsage.removeAll()
        tokenObservations.removeAll()
    }

    mutating func reconnect(now: Date = Date()) {
        // 断线期间的累计变化没有完整轮次归属, 重新建立基线, 不归入重连后的轮次
        threadTotals.removeAll()
        tokenStreams.removeAll()
        pendingUsage.removeAll()
        approvals.removeAll()
        waitingSince.removeAll()
        observingSince = now
        for key in states.keys {
            states[key]?.presentation = nil
            states[key]?.pendingApprovals.removeAll()
        }
    }

    mutating func invalidateThread(_ id: String) {
        threads[id]?.status = ActivityThreadStatus(type: .notLoaded)
        for key in states.keys where key.threadID == id && states[key]?.terminal == nil {
            states[key]?.readStatus = .unavailable
            states[key]?.presentation = nil
        }
    }

    mutating func invalidateTokenBaseline(_ id: String) {
        threadTotals.removeValue(forKey: id)
    }

    mutating func markNewThread(_ id: String) {
        if isTokenRecordingEnabled, threadTotals[id] == nil {
            threadTotals[id] = .zero
        }
    }

    mutating func takeTokenObservations() -> [TokenObservation] {
        defer { tokenObservations.removeAll(keepingCapacity: true) }
        return tokenObservations
    }

    mutating func acceptTokenTurns(_ turns: [TokenTurn], replaying observations: [TokenObservation] = []) throws {
        var records = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        for observation in observations {
            let turn = observation.turn
            records[turn.id] = try observation.applying(to: records[turn.id])
            if turn.rootID != turn.id, records[turn.rootID] == nil {
                records[turn.rootID] = TokenTurn(id: turn.rootID, rootID: turn.rootID, startedAt: observation.rootStartedAt, updatedAt: turn.updatedAt)
            }
        }
        tokenTurns = records
        lastHistoryCutoff = nil
        for key in states.keys {
            states[key]?.tokenUsage = records[TokenTurn.identifier(thread: key.threadID, turn: key.turnID)]?.usage
        }
    }

    mutating func reconcile(thread: ActivityThread, turns: [ActivityTurn], now: Date, bootstrap: Bool = false) -> [ActivityRecord] {
        threads[thread.id] = thread
        threadLastObserved[thread.id] = now
        let previousReferences = Set(states.keys)
        for turn in turns {
            for item in turn.items ?? [] {
                recordSubagentContext(item, threadID: thread.id, turnID: turn.id)
            }
            updateTurn(turn, threadID: thread.id, now: now, historical: true)
        }
        resolveRoots()
        var events: [ActivityRecord] = []
        for turn in turns where turn.status == .running && thread.status?.type == .active {
            let key = reference(thread.id, turn.id)
            guard !previousReferences.contains(key) || bootstrap else { continue }
            let state = states[key]
            var value = event(.turnStarted, threadID: thread.id, turnID: turn.id, at: state?.startedAt ?? now)
            value.context = ActivityContext(
                method: "thread/turns/list", threadID: thread.id, turnID: turn.id,
                parentThreadID: thread.parentID, rootThreadID: state?.rootThreadID,
                rootTurnID: state?.rootTurnID, turnStartedAt: state?.startedAt
            )
            events.append(value)
        }
        updateWaiting(threadID: thread.id, status: thread.status, now: now)
        if let key = activeReference(thread.id) {
            var live = states[key]?.presentation ?? ActivityLivePresentation()
            live.reconcile(status: thread.status)
            states[key]?.presentation = live
        }
        return events
    }

    mutating func consume(_ notification: ActivityInput, now: Date) -> [ActivityRecord] {
        let category = notification.kind.category
        guard category != .ignored else { return [] }
        let params = notification.params
        guard let threadID = params.threadId ?? params.thread?.id else { return [] }
        let wasKnown = threads[threadID] != nil
        if let thread = params.thread {
            threads[threadID] = thread
        }
        guard threads[threadID] != nil else { return [] }
        threadLastObserved[threadID] = now
        let date = (params.completedAt ?? params.startedAt) ?? now
        let turnID = params.turnId ?? params.turn?.id
        var events: [ActivityRecord] = []
        switch notification.kind {
        case .threadDiscovered:
            if !wasKnown, let created = params.thread?.createdAt, created >= Date(timeIntervalSince1970: floor(observingSince.timeIntervalSince1970)) {
                markNewThread(threadID)
            }
        case .threadStatusChanged:
            threads[threadID]?.status = params.status
            updateWaiting(threadID: threadID, status: params.status, now: now)
        case .turnStarted, .turnFinished:
            guard let turn = params.turn, turn.status != .unknown else { break }
            events.append(turnEvent(turn, threadID: threadID, now: now))
        case .itemStarted, .itemFinished:
            if let turnID, let item = params.item, ActivityItem.isObservedType(item.type) {
                events += itemEvents(item, method: notification.kind, threadID: threadID, turnID: turnID, at: date)
            }
        case .commandApprovalRequested, .fileApprovalRequested, .permissionsRequested:
            guard let turnID, let identity = approvalIdentity(notification) else { break }
            let reference = reference(threadID, turnID)
            guard states[reference]?.terminal == nil, states[reference] != nil else { break }
            let item = approvalItem(notification)
            if let id = notification.id {
                approvals[id] = reference
                states[reference]?.pendingApprovals[id] = ActivityApproval(
                    requestedAt: date, toolName: item?.type == .commandExecution ? nil : item?.tool,
                    sequence: 0, itemType: item?.type.rawValue,
                    commandActionTypes: item?.commandActions?.map(\.type)
                )
            }
            events.append(event(
                .approvalRequested,
                threadID: threadID,
                turnID: turnID,
                at: date,
                item: item,
                identity: identity
            ))
            states[reference]?.isWaitingApproval = true
            states[reference]?.approvalChangedAt = waitingSince[threadID] ?? date
        case .requestResolved:
            if let id = params.requestId, let reference = approvals.removeValue(forKey: id) {
                states[reference]?.pendingApprovals.removeValue(forKey: id)
                let isWaiting = !(states[reference]?.pendingApprovals.isEmpty ?? true)
                states[reference]?.isWaitingApproval = isWaiting
                states[reference]?.approvalChangedAt = now
            }
        case .usageUpdated:
            if let turnID, let usage = params.tokenUsage {
                updateUsage(threadID: threadID, turnID: turnID, update: usage, now: now)
            }
        default:
            if category == .progress, let turnID {
                progress(threadID, turnID, at: now)
            }
        }
        updatePresentation(notification, threadID: threadID, turnID: turnID, at: date)
        if params.thread != nil || params.item?.type == .subAgentActivity {
            resolveRoots()
        }
        prune(now: now)
        return finish(events, notification: notification, threadID: threadID, turnID: turnID, now: now)
    }

    private mutating func updatePresentation(_ notification: ActivityInput, threadID: String, turnID: String?, at date: Date) {
        let reference: ActivityTurnReference? = switch notification.kind {
        case .threadStatusChanged:
            activeReference(threadID)
        case .requestResolved:
            // resolved 不携带 turnId, 必须先匹配原请求, 不能误清除新轮次的等待
            notification.params.requestId.flatMap { id in
                states.keys.first { $0.threadID == threadID && states[$0]?.presentation?.requests[id] != nil }
            }
        default:
            turnID.map { self.reference(threadID, $0) }
        }
        guard let key = reference,
              states[key]?.terminal == nil, states[key] != nil else { return }
        var live = states[key]?.presentation ?? ActivityLivePresentation()
        live.consume(notification, at: date)
        states[key]?.presentation = live
    }

    private mutating func finish(
        _ events: [ActivityRecord], notification: ActivityInput,
        threadID: String, turnID: String?, now: Date
    ) -> [ActivityRecord] {
        let context = context(notification, threadID: threadID, turnID: turnID)
        return events.map { value in
            var value = value
            value.context = context
            return value
        }.filter { value in
            guard let id = value.id else { return false }
            guard seenEvents[id] == nil else { return false }
            seenEvents[id] = now
            return true
        }
    }

    private func context(_ notification: ActivityInput, threadID: String, turnID: String?) -> ActivityContext {
        let params = notification.params
        let state = turnID.flatMap { states[reference(threadID, $0)] }
        let item = params.item ?? approvalItem(notification)
        return ActivityContext(
            method: notification.provenanceMethod, threadID: threadID, turnID: turnID,
            parentThreadID: threads[threadID]?.parentID,
            rootThreadID: state?.rootThreadID, rootTurnID: state?.rootTurnID,
            itemID: params.item?.id ?? params.itemId,
            itemType: item?.type.rawValue, itemStatus: params.item?.status,
            agentThreadID: params.item?.agentThreadId, itemKind: params.item?.kind,
            requestID: notification.id ?? params.requestId,
            turnStatus: params.turn?.status,
            turnStartedAt: params.turn?.startedAt,
            turnCompletedAt: params.turn?.completedAt,
            duration: params.turn?.duration
        )
    }

    private mutating func turnEvent(_ turn: ActivityTurn, threadID: String, now: Date) -> ActivityRecord {
        updateTurn(turn, threadID: threadID, now: now, historical: false)
        resolveRoots()
        if turn.status != .running, threadTotals[threadID] == .zero {
            // 未观察到本轮用量就已结束, 零基线不能把漏掉的消耗算到下一轮
            threadTotals.removeValue(forKey: threadID)
        }
        let phase: ActivityEventKind = turn.status == .running ? .turnStarted : turn.status == .completed ? .turnCompleted : .turnAborted
        let timestamp = (turn.status == .running ? turn.startedAt : turn.completedAt) ?? now
        return event(phase, threadID: threadID, turnID: turn.id, at: timestamp)
    }

    mutating func maintain(loadedThreads: Set<String>, now: Date) {
        self.loadedThreads = loadedThreads
        prune(now: now)
    }

    private mutating func prune(now: Date) {
        let retainedDate = HistoryStorage.retentionCutoffDate(today: now)
        if lastHistoryCutoff != retainedDate {
            let retainedRoots = Set(tokenTurns.values.filter { $0.updatedAt >= retainedDate }.map(\.rootID))
            tokenTurns = tokenTurns.filter { $0.value.updatedAt >= retainedDate || retainedRoots.contains($0.key) }
            lastHistoryCutoff = retainedDate
        }
        guard now.timeIntervalSince(lastTransientPrune) >= 60 else { return }
        lastTransientPrune = now
        let cutoff = now.addingTimeInterval(-ActivityRetention.window)
        seenEvents = seenEvents.filter { $0.value > cutoff }
        var retained = Set(states.keys.filter { key in
            guard let state = states[key] else { return false }
            return (state.lastProgressAt ?? .distantPast) > cutoff
                || (state.terminal == nil && state.readStatus != .notFound && (loadedThreads.contains(key.threadID) || state.readStatus == .complete))
        })
        // 子线程仍在使用的祖先状态必须保留, 否则迟到用量会失去根轮次归属
        var changed = true
        while changed {
            let previous = retained
            for key in previous {
                guard let state = states[key] else { continue }
                if let root = state.rootThreadID, let turn = state.rootTurnID {
                    retained.insert(reference(root, turn))
                }
                if let parent = subagentContexts[key.threadID]?.parent {
                    retained.insert(parent)
                }
            }
            changed = previous != retained
        }
        states = states.filter { retained.contains($0.key) }
        pendingUsage = pendingUsage.filter { retained.contains($0.key) }
        let retainedThreads = loadedThreads.union(retained.flatMap { ancestorThreads(of: $0.threadID) })
            .union(threadLastObserved.filter { $0.value > cutoff }.keys)
        threads = threads.filter { retainedThreads.contains($0.key) }
        threadLastObserved = threadLastObserved.filter { retainedThreads.contains($0.key) }
        subagentContexts = subagentContexts.filter { retainedThreads.contains($0.key) || retained.contains($0.value.parent) }
        threadTotals = threadTotals.filter { retainedThreads.contains($0.key) }
        waitingSince = waitingSince.filter { retainedThreads.contains($0.key) }
        approvals = approvals.filter { states[$0.value]?.terminal == nil && states[$0.value] != nil }
        let retainedTokens = Set(retained.map { TokenTurn.identifier(thread: $0.threadID, turn: $0.turnID) })
            .union(tokenObservations.map(\.turn.id))
        tokenStreams = tokenStreams.filter { retainedTokens.contains($0.key) }
    }

    private func approvalIdentity(_ notification: ActivityInput) -> String? {
        let params = notification.params
        guard let item = params.itemId, let started = params.startedAt else { return nil }
        let callback = params.approvalId.map { "callback:" + $0 } ?? "started:\(started.timeIntervalSince1970)"
        return [notification.kind.rawValue, item, callback].joined(separator: ":")
    }

    private mutating func itemEvents(_ item: ActivityItem, method: ActivityInput.Kind, threadID: String, turnID: String, at date: Date) -> [ActivityRecord] {
        var events: [ActivityRecord] = []
        recordSubagentContext(item, threadID: threadID, turnID: turnID)
        progress(threadID, turnID, at: date)
        let starting = method == .itemStarted
        if item.isToolCall {
            events.append(event(starting ? .toolStarted : .toolCompleted, threadID: threadID, turnID: turnID, at: date, item: item))
        } else if item.type == .contextCompaction {
            events.append(event(starting ? .compactionStarted : .compactionCompleted, threadID: threadID, turnID: turnID, at: date, item: item))
        } else if !starting, item.type == .subAgentActivity, ["started", "completed", "interrupted"].contains(item.kind ?? "") {
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

    private func approvalItem(_ notification: ActivityInput) -> ActivityItem? {
        guard let id = notification.params.itemId else { return nil }
        switch notification.kind {
        case .commandApprovalRequested:
            return ActivityItem(id: id, type: .commandExecution, commandActions: notification.params.commandActions)
        case .fileApprovalRequested:
            return ActivityItem(id: id, type: .fileChange)
        default:
            return nil
        }
    }

    private mutating func updateTurn(_ turn: ActivityTurn, threadID: String, now: Date, historical: Bool) {
        let start = turn.startedAt
        let reference = reference(threadID, turn.id)
        let previous = states[reference]
        let terminal: SessionTerminalState?
        let isTerminal = turn.status.isTerminal
        let isLoaded = [.active, .idle].contains(threads[threadID]?.status?.type ?? .unknown)
        if isTerminal, turn.completedAt != nil || !historical || isLoaded {
            let date = turn.completedAt
            if turn.status == .completed {
                var reportedAt = date
                var duration = turn.duration
                if case let .completed(previousAt, previousDuration) = previous?.terminal {
                    reportedAt = reportedAt ?? previousAt
                    duration = duration ?? previousDuration
                }
                terminal = .completed(at: reportedAt, duration: duration)
            } else {
                var reportedAt = date
                var duration = turn.duration
                if case let .aborted(previousAt, previousDuration) = previous?.terminal {
                    reportedAt = reportedAt ?? previousAt
                    duration = duration ?? previousDuration
                }
                terminal = .aborted(at: reportedAt, duration: duration)
            }
        } else {
            terminal = previous?.terminal
        }
        var state = SessionLifecycleState(
            requestedThreadID: threadID, turnID: turn.id, startedAt: start ?? previous?.startedAt,
            effort: threads[threadID]?.reasoningEffort, lastProgressAt: previous?.lastProgressAt ?? start,
            terminal: terminal, readStatus: terminal == nil && (!isLoaded || turn.status != .running) ? .unavailable : .complete,
            contextObservedAt: now, rootTurnID: turn.rootTurnId.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.rootTurnID,
            rootThreadID: nil,
            parentThreadID: threads[threadID]?.parentID,
            tokenUsage: previous?.tokenUsage ?? tokenTurns[TokenTurn.identifier(thread: threadID, turn: turn.id)]?.usage,
            isHistoricalTerminal: previous?.terminal == nil ? historical : previous?.isHistoricalTerminal ?? historical,
            isWaitingApproval: previous?.isWaitingApproval, approvalChangedAt: previous?.approvalChangedAt
        )
        if terminal != nil {
            state.terminalObservedAt = previous?.terminalObservedAt ?? now
            state.lastProgressAt = turn.completedAt ?? state.terminalObservedAt
        }
        state.pendingApprovals = previous?.pendingApprovals ?? [:]
        state.presentation = previous?.presentation
        state.turnStatus = turn.status
        if terminal != nil {
            state.presentation = nil
            state.pendingApprovals.removeAll()
            state.isWaitingApproval = false
            approvals = approvals.filter { $0.value != reference }
        }
        states[reference] = state
    }

    private mutating func updateWaiting(threadID: String, status: ActivityThreadStatus?, now: Date) {
        guard let status, status.type == .active || status.type == .idle else { return }
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
            approvals = approvals.filter { $0.value.threadID != threadID }
            for key in states.keys where key.threadID == threadID {
                states[key]?.pendingApprovals.removeAll()
            }
        }
    }

    private mutating func progress(_ threadID: String, _ turnID: String, at date: Date) {
        let key = reference(threadID, turnID)
        let lastProgress = states[key]?.lastProgressAt ?? .distantPast
        states[key]?.lastProgressAt = max(lastProgress, date)
    }

    /// 只匹配服务端给出的根轮次, 不根据创建时间或父线程当前轮次推断
    private mutating func resolveRoots() {
        let byTurn = Dictionary(grouping: states.keys, by: \.turnID)
        for key in states.keys {
            guard let root = states[key]?.rootTurnID else { continue }
            let candidates = byTurn[root] ?? []
            let ancestors = ancestorThreads(of: key.threadID)
            let related = candidates.filter { ancestors.contains($0.threadID) }
            let matches = related.isEmpty ? candidates : related
            states[key]?.rootThreadID = root == key.turnID ? key.threadID : matches.count == 1 ? matches.first?.threadID : nil
        }
        for key in states.keys {
            let resolvedEffort = effort(for: key)
            states[key]?.effort = resolvedEffort
        }
        for (key, pending) in pendingUsage where states[key]?.rootThreadID != nil {
            recordUsage(key, previous: .zero, current: pending.usage, now: pending.updatedAt)
            pendingUsage.removeValue(forKey: key)
        }
    }

    private func ancestorThreads(of id: String) -> Set<String> {
        var result = Set<String>()
        var current: String? = id
        while let thread = current, result.insert(thread).inserted {
            current = threads[thread]?.parentID ?? subagentContexts[thread]?.parent.threadID
        }
        return result
    }

    /// 缺少根轮次时只沿已知父链补读, 每次读取的时间和分页由 reader 限制
    func missingRootTurns(liveOnly: Bool = false) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for state in states.values where state.rootThreadID == nil && (!liveOnly || state.terminal == nil) {
            guard let root = state.rootTurnID else { continue }
            for thread in ancestorThreads(of: state.requestedThreadID) {
                result[thread, default: []].insert(root)
            }
        }
        return result
    }

    func missingSubagentContexts(in threadID: String, liveOnly: Bool = false) -> Set<String> {
        let liveThreads = Set(states.values.filter { $0.terminal == nil }.map(\.requestedThreadID))
        return Set(threads.values.filter {
            $0.parentID == threadID && subagentContexts[$0.id] == nil && (!liveOnly || liveThreads.contains($0.id))
        }.map(\.id))
    }

    func missingSubagentParents(liveOnly: Bool = false) -> Set<String> {
        let liveThreads = Set(states.values.filter { $0.terminal == nil }.map(\.requestedThreadID))
        return Set(threads.values.filter {
            subagentContexts[$0.id] == nil && (!liveOnly || liveThreads.contains($0.id))
        }.compactMap(\.parentID))
    }

    private mutating func recordSubagentContext(_ item: ActivityItem, threadID: String, turnID: String) {
        guard item.type == .subAgentActivity, item.kind == "started", let agent = item.agentThreadId else { return }
        subagentContexts[agent] = SubagentContext(
            parent: reference(threadID, turnID), model: item.model, effort: item.reasoningEffort
        )
    }

    private func effort(for key: ActivityTurnReference) -> String? {
        let current = threads[key.threadID]?.reasoningEffort
        // 创建参数只属于创建时的根工作, 子线程参与其他根轮次时不能继续带入
        guard let context = subagentContexts[key.threadID], let root = states[key]?.rootTurnID,
              states[context.parent]?.rootTurnID == root else { return current }
        if let created = context.effort, let current, created != current {
            return "mixed"
        }
        return current ?? context.effort
    }

    private func reference(_ threadID: String, _ turnID: String) -> ActivityTurnReference {
        ActivityTurnReference(threadID: threadID, turnID: turnID)
    }

    private func activeReference(_ threadID: String) -> ActivityTurnReference? {
        states.filter { $0.key.threadID == threadID && $0.value.terminal == nil }.max {
            ($0.value.startedAt ?? .distantPast) < ($1.value.startedAt ?? .distantPast)
        }?.key
    }

    private func event(
        _ phase: ActivityEventKind, threadID: String, turnID: String, at date: Date,
        item: ActivityItem? = nil, identity: String? = nil
    ) -> ActivityRecord {
        let thread = threads[threadID]
        let state = states[reference(threadID, turnID)]
        let isChild = thread?.parentID != nil
        let agentID = item?.agentThreadId ?? (isChild ? threadID : nil)
        let isAgentActivity = item?.type == .subAgentActivity
        let agentThread = agentID.flatMap { threads[$0] }
        let context = agentID.flatMap { subagentContexts[$0] }
        let agentModel = item?.kind == "started" ? item?.model : agentThread?.model ?? context?.model
        let agentEffort = item?.kind == "started" ? item?.reasoningEffort : agentThread?.reasoningEffort ?? context?.effort
        return ActivityRecord(
            timestamp: date, name: phase.rawValue, origin: thread?.origin ?? .unknown,
            cwd: thread?.cwd, toolName: item?.type == .commandExecution ? nil : item?.tool,
            commandActionTypes: item?.type == .commandExecution ? item?.commandActions?.map(\.type) : nil,
            model: isAgentActivity ? agentModel : thread?.model,
            effort: isAgentActivity ? agentEffort : thread?.reasoningEffort,
            threadID: isChild ? state?.rootThreadID : threadID, turnID: isAgentActivity ? nil : turnID, agentID: agentID,
            id: [threadID, turnID, identity ?? item?.id ?? "turn", phase.rawValue].joined(separator: ":")
        )
    }

    private mutating func updateUsage(threadID: String, turnID: String, update: ActivityTokenUpdate, now: Date) {
        guard isTokenRecordingEnabled else { return }
        let total = update.total
        guard total.isValid else { return }
        defer { threadTotals[threadID] = total }
        guard let previous = threadTotals[threadID], let delta = total.subtracting(previous), delta != .zero else { return }
        let key = reference(threadID, turnID)
        guard let state = states[key] else { return }
        guard state.rootThreadID != nil, state.rootTurnID != nil else {
            if let usage = (pendingUsage[key]?.usage ?? .zero).adding(delta), usage.isValid {
                pendingUsage[key] = PendingUsage(usage: usage, updatedAt: now)
            }
            return
        }
        recordUsage(key, previous: previous, current: total, now: now)
    }

    private mutating func recordUsage(_ key: ActivityTurnReference, previous: TokenUsage, current: TokenUsage, now: Date) {
        guard let state = states[key], let rootThread = state.rootThreadID, let rootTurn = state.rootTurnID else { return }
        let id = TokenTurn.identifier(thread: key.threadID, turn: key.turnID)
        let existing = tokenTurns[id]
        var stream = tokenStreams[id] ?? TokenStream()
        stream.sequence += 1
        tokenStreams[id] = stream
        let rootKey = reference(rootThread, rootTurn)
        let metadata = TokenTurn(
            id: id,
            rootID: TokenTurn.identifier(thread: rootThread, turn: rootTurn),
            startedAt: state.startedAt,
            updatedAt: now
        )
        let observation = TokenObservation(
            turn: metadata,
            rootStartedAt: states[rootKey]?.startedAt,
            streamID: stream.id,
            sequence: stream.sequence,
            previous: previous,
            current: current
        )
        tokenObservations.append(observation)
        guard let record = try? observation.applying(to: existing) else { return }
        states[key]?.tokenUsage = record.usage
        tokenTurns[id] = record
        if record.rootID != id, tokenTurns[record.rootID] == nil, let root = states[rootKey] {
            tokenTurns[record.rootID] = TokenTurn(id: record.rootID, rootID: record.rootID, startedAt: root.startedAt, updatedAt: now, usage: nil)
        }
    }
}
