import Foundation

/// 将协议事件映射为既有业务阶段, 快照核对与实时统计分别处理
nonisolated struct AppServerActivityReducer {
    var threads: [String: ActivityThread] = [:]
    var states: [ActivityTurnReference: TurnLifecycleState] = [:]
    private struct SubagentContext {
        let parentTurn: ActivityTurnReference
        let model: String?
        let effort: String?
    }

    private var subagentContexts: [String: SubagentContext] = [:]
    private var tokenUsagePositions: [String: Int64] = [:]
    private var threadLastObserved: [String: Date] = [:]
    private var loadedThreads = Set<String>()
    private var lastTransientPrune = Date.distantPast
    private(set) var tokenUsageSamples: [TokenUsageSample] = []
    private var seenEvents: [String: Date] = [:]
    private var approvals: [String: ActivityTurnReference] = [:]
    private var waitingSince: [String: Date] = [:]
    private(set) var tokenUsageTurns: [ActivityTurnReference: TokenUsage] = [:]
    private var isTokenUsageRecordingEnabled = true

    mutating func setTokenUsageRecordingEnabled(_ enabled: Bool) {
        guard enabled != isTokenUsageRecordingEnabled else { return }
        isTokenUsageRecordingEnabled = enabled
        tokenUsageSamples.removeAll()
    }

    mutating func reconnect() {
        approvals.removeAll()
        waitingSince.removeAll()
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

    mutating func takeTokenUsageSamples() -> [TokenUsageSample] {
        defer { tokenUsageSamples.removeAll(keepingCapacity: true) }
        return tokenUsageSamples
    }

    mutating func applyTokenUsage(_ snapshot: TokenUsageThreadSnapshot) {
        guard snapshot.position >= tokenUsagePositions[snapshot.threadID, default: 0] else { return }
        tokenUsagePositions[snapshot.threadID] = snapshot.position
        for (turnID, usage) in snapshot.turns {
            let key = reference(snapshot.threadID, turnID)
            tokenUsageTurns[key] = usage
            states[key]?.tokenUsage = usage
        }
    }

    mutating func reconcile(
        thread: ActivityThread, turns: [ActivityTurn], now: Date, bootstrap: Bool = false,
        preservingThreadState: Bool = false, preservingTurns: Set<String> = []
    ) -> [ActivityDataRecord] {
        if preservingThreadState, var current = threads[thread.id] {
            current.cwd = current.cwd ?? thread.cwd
            current.model = current.model ?? thread.model
            current.reasoningEffort = current.reasoningEffort ?? thread.reasoningEffort
            current.parentThreadID = current.parentThreadID ?? thread.parentThreadID
            current.createdAt = current.createdAt ?? thread.createdAt
            threads[thread.id] = current
        } else {
            threads[thread.id] = thread
        }
        threadLastObserved[thread.id] = now
        let previousReferences = Set(states.keys)
        for turn in turns {
            if preservingTurns.contains(turn.id) {
                mergeTurnMetadata(turn, threadID: thread.id)
            } else {
                updateTurn(turn, threadID: thread.id, now: now, historical: true)
            }
        }
        mergeSubagentContexts(threadID: thread.id, turns: turns, now: now)
        var events: [ActivityDataRecord] = []
        for turn in turns where turn.status == .running && threads[thread.id]?.status?.type == .active && !preservingTurns.contains(turn.id) {
            let key = reference(thread.id, turn.id)
            guard !previousReferences.contains(key) || bootstrap else { continue }
            let state = states[key]
            var value = event(.turnStarted, threadID: thread.id, turnID: turn.id, at: state?.startedAt ?? now)
            value.context = ActivityDataContext(
                method: "thread/turns/list", threadID: thread.id, turnID: turn.id,
                parentThreadID: thread.parentThreadID, rootThreadID: state?.rootThreadID,
                rootTurnID: state?.rootTurnID, turnStartedAt: state?.startedAt
            )
            events.append(value)
        }
        if !preservingThreadState {
            updateWaiting(threadID: thread.id, status: thread.status, now: now)
        }
        if !preservingThreadState, let key = activeReference(thread.id) {
            var live = states[key]?.presentation ?? ActivityLivePresentation()
            live.reconcile(status: thread.status)
            states[key]?.presentation = live
        }
        return events
    }

    /// 补查只填缺失资料, 不刷新生命周期验证时间或制造进展事件
    mutating func mergeSubagentContexts(threadID: String, turns: [ActivityTurn], now: Date) {
        for turn in turns {
            mergeTurnMetadata(turn, threadID: threadID)
            for item in turn.items ?? [] where item.agentThreadId.map({ subagentContexts[$0] == nil }) == true {
                recordSubagentContext(item, threadID: threadID, turnID: turn.id)
            }
        }
        resolveRoots(now: now)
    }

    private mutating func mergeTurnMetadata(_ turn: ActivityTurn, threadID: String) {
        let key = reference(threadID, turn.id)
        guard var state = states[key] else { return }
        state.startedAt = state.startedAt ?? turn.startedAt
        state.rootTurnID = state.rootTurnID ?? turn.rootTurnId.flatMap { $0.isEmpty ? nil : $0 }
        state.parentThreadID = state.parentThreadID ?? threads[threadID]?.parentThreadID
        states[key] = state
    }

    mutating func consume(_ notification: ActivityInput, now: Date) -> [ActivityDataRecord] {
        let category = notification.kind.category
        guard category != .ignored else { return [] }
        let params = notification.params
        guard let threadID = params.threadId ?? params.thread?.id else { return [] }
        if let thread = params.thread {
            threads[threadID] = thread
        }
        guard threads[threadID] != nil else { return [] }
        threadLastObserved[threadID] = now
        let date = (params.completedAt ?? params.startedAt) ?? now
        let turnID = params.turnId ?? params.turn?.id
        var events: [ActivityDataRecord] = []
        switch notification.kind {
        case .threadDiscovered:
            break
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
            if let tokenUsage = params.tokenUsage, isTokenUsageRecordingEnabled {
                recordTokenUsage(threadID: threadID, turnID: turnID, update: tokenUsage, now: now)
            }
        default:
            if category == .progress, let turnID {
                progress(threadID, turnID, at: now)
            }
        }
        updatePresentation(notification, threadID: threadID, turnID: turnID, at: date)
        if params.thread != nil || params.item?.type == .subAgentActivity {
            resolveRoots(now: now)
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
        _ events: [ActivityDataRecord], notification: ActivityInput,
        threadID: String, turnID: String?, now: Date
    ) -> [ActivityDataRecord] {
        let context = context(notification, threadID: threadID, turnID: turnID)
        return events.map { value in
            var value = value
            value.context = context
            return value
        }.filter { value in
            guard let id = value.id, seenEvents[id] == nil else { return false }
            seenEvents[id] = now
            return true
        }
    }

    private func context(_ notification: ActivityInput, threadID: String, turnID: String?) -> ActivityDataContext {
        let params = notification.params
        let state = turnID.flatMap { states[reference(threadID, $0)] }
        let item = params.item ?? approvalItem(notification)
        return ActivityDataContext(
            method: notification.provenanceMethod, threadID: threadID, turnID: turnID,
            parentThreadID: threads[threadID]?.parentThreadID,
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

    private mutating func turnEvent(_ turn: ActivityTurn, threadID: String, now: Date) -> ActivityDataRecord {
        updateTurn(turn, threadID: threadID, now: now, historical: false)
        resolveRoots(now: now)
        let phase: ActivityDataEventKind = turn.status == .running ? .turnStarted : turn.status == .completed ? .turnCompleted : .turnAborted
        let timestamp = (turn.status == .running ? turn.startedAt : turn.completedAt) ?? now
        return event(phase, threadID: threadID, turnID: turn.id, at: timestamp)
    }

    mutating func maintain(loadedThreads: Set<String>, now: Date) {
        self.loadedThreads = loadedThreads
        prune(now: now)
    }

    private mutating func prune(now: Date) {
        guard now.timeIntervalSince(lastTransientPrune) >= 60 else { return }
        lastTransientPrune = now
        let cutoff = now.addingTimeInterval(-ActivityRetention.window)
        seenEvents = seenEvents.filter { $0.value > cutoff }
        var retained = Set(states.keys.filter { key in
            guard let state = states[key] else { return false }
            return (state.lastProgressAt ?? .distantPast) > cutoff
                || (state.terminal == nil && state.readStatus != .notFound && (loadedThreads.contains(key.threadID) || state.readStatus == .complete))
        })
        // 子会话仍在使用的祖先状态必须保留, 否则迟到用量会失去根轮次归属
        var changed = true
        while changed {
            let previous = retained
            for key in previous {
                guard let state = states[key] else { continue }
                if let root = state.rootThreadID, let turn = state.rootTurnID {
                    retained.insert(reference(root, turn))
                }
                if let parentTurn = subagentContexts[key.threadID]?.parentTurn {
                    retained.insert(parentTurn)
                }
            }
            changed = previous != retained
        }
        states = states.filter { retained.contains($0.key) }
        let retainedThreads = loadedThreads.union(retained.flatMap { ancestorThreads(of: $0.threadID) })
            .union(threadLastObserved.filter { $0.value > cutoff }.keys)
        threads = threads.filter { retainedThreads.contains($0.key) }
        threadLastObserved = threadLastObserved.filter { retainedThreads.contains($0.key) }
        subagentContexts = subagentContexts.filter { retainedThreads.contains($0.key) || retained.contains($0.value.parentTurn) }
        tokenUsagePositions = tokenUsagePositions.filter { retainedThreads.contains($0.key) }
        tokenUsageTurns = tokenUsageTurns.filter { retained.contains($0.key) }
        waitingSince = waitingSince.filter { retainedThreads.contains($0.key) }
        approvals = approvals.filter { states[$0.value]?.terminal == nil && states[$0.value] != nil }
    }

    private func approvalIdentity(_ notification: ActivityInput) -> String? {
        let params = notification.params
        guard let item = params.itemId, let started = params.startedAt else { return nil }
        let callback = params.approvalId.map { "callback:" + $0 } ?? "started:\(started.timeIntervalSince1970)"
        return [notification.kind.rawValue, item, callback].joined(separator: ":")
    }

    private mutating func itemEvents(_ item: ActivityItem, method: ActivityInput.Kind, threadID: String, turnID: String, at date: Date) -> [ActivityDataRecord] {
        recordSubagentContext(item, threadID: threadID, turnID: turnID)
        progress(threadID, turnID, at: date)
        return itemFacts(item, starting: method == .itemStarted, threadID: threadID, turnID: turnID, at: date)
    }

    private func itemFacts(_ item: ActivityItem, starting: Bool, threadID: String, turnID: String, at date: Date) -> [ActivityDataRecord] {
        var events: [ActivityDataRecord] = []
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

    mutating func historicalEvents(_ entries: [ActivityItemEntry], reference: ActivityTurnReference, now: Date) -> [ActivityDataRecord] {
        let threadID = reference.threadID
        let turnID = reference.turnID
        let turn = ActivityTurn(id: turnID, status: .unknown, items: entries.map(\.item))
        mergeSubagentContexts(threadID: threadID, turns: [turn], now: now)
        let state = states[reference]
        return entries.flatMap { entry -> [ActivityDataRecord] in
            let started = entry.startedAt ?? state?.startedAt ?? now
            let completed = entry.completedAt ?? state?.terminal?.timestamp ?? started
            let item = entry.item
            var events = itemFacts(item, starting: true, threadID: threadID, turnID: turnID, at: started)
            let isCompleted = entry.completedAt != nil || ["completed", "failed", "declined", "interrupted"].contains(item.status ?? "")
                || (item.type == .subAgentActivity && ["started", "completed", "interrupted"].contains(item.kind ?? ""))
            if isCompleted {
                events += itemFacts(item, starting: false, threadID: threadID, turnID: turnID, at: completed)
            }
            return events.map { event in
                var event = event
                event.context = ActivityDataContext(
                    method: "thread/items/list", threadID: threadID, turnID: turnID,
                    parentThreadID: threads[threadID]?.parentThreadID, rootThreadID: state?.rootThreadID, rootTurnID: state?.rootTurnID,
                    itemID: item.id, itemType: item.type.rawValue, itemStatus: item.status,
                    agentThreadID: item.agentThreadId, itemKind: item.kind, turnStartedAt: state?.startedAt
                )
                return event
            }
        }
    }

    func historicalTurnEvents(_ reference: ActivityTurnReference) -> [ActivityDataRecord] {
        guard let state = states[reference] else { return [] }
        var phases: [(ActivityDataEventKind, Date)] = []
        if let started = state.startedAt {
            phases.append((.turnStarted, started))
        }
        if let terminal = state.terminal, let completed = terminal.timestamp {
            phases.append((state.turnStatus == .completed ? .turnCompleted : .turnAborted, completed))
        }
        return phases.map { phase, date in
            var value = event(phase, threadID: reference.threadID, turnID: reference.turnID, at: date)
            value.context = ActivityDataContext(
                method: "thread/turns/list", threadID: reference.threadID, turnID: reference.turnID,
                parentThreadID: threads[reference.threadID]?.parentThreadID,
                rootThreadID: state.rootThreadID, rootTurnID: state.rootTurnID, turnStatus: state.turnStatus,
                turnStartedAt: state.startedAt
            )
            return value
        }
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
        let terminal: TurnTerminalState?
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
        var state = TurnLifecycleState(
            requestedThreadID: threadID, turnID: turn.id, startedAt: start ?? previous?.startedAt,
            effort: threads[threadID]?.reasoningEffort, lastProgressAt: previous?.lastProgressAt ?? start,
            terminal: terminal, readStatus: terminal == nil && (!isLoaded || turn.status != .running) ? .unavailable : .complete,
            contextObservedAt: now, rootTurnID: turn.rootTurnId.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.rootTurnID,
            rootThreadID: nil,
            parentThreadID: threads[threadID]?.parentThreadID,
            tokenUsage: previous?.tokenUsage ?? tokenUsageTurns[reference],
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

    /// 只匹配服务端给出的根轮次, 不根据创建时间或父会话当前轮次推断
    private mutating func resolveRoots(now _: Date) {
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
    }

    private func ancestorThreads(of id: String) -> Set<String> {
        var result = Set<String>()
        var current: String? = id
        while let thread = current, result.insert(thread).inserted {
            current = threads[thread]?.parentThreadID ?? subagentContexts[thread]?.parentTurn.threadID
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

    func missingSubagentParents(liveOnly: Bool = false) -> Set<String> {
        let liveThreads = Set(states.values.filter { $0.terminal == nil }.map(\.requestedThreadID))
        return Set(threads.values.filter {
            subagentContexts[$0.id] == nil && (!liveOnly || liveThreads.contains($0.id))
        }.compactMap(\.parentThreadID))
    }

    private mutating func recordSubagentContext(_ item: ActivityItem, threadID: String, turnID: String) {
        guard item.type == .subAgentActivity, item.kind == "started", let agentThreadID = item.agentThreadId else { return }
        subagentContexts[agentThreadID] = SubagentContext(
            parentTurn: reference(threadID, turnID), model: item.model, effort: item.reasoningEffort
        )
    }

    private func effort(for key: ActivityTurnReference) -> String? {
        let current = threads[key.threadID]?.reasoningEffort
        // 创建参数只属于创建时的根工作, 子会话参与其他根轮次时不能继续带入
        guard let context = subagentContexts[key.threadID], let root = states[key]?.rootTurnID,
              states[context.parentTurn]?.rootTurnID == root else { return current }
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
        _ phase: ActivityDataEventKind, threadID: String, turnID: String, at date: Date,
        item: ActivityItem? = nil, identity: String? = nil
    ) -> ActivityDataRecord {
        let thread = threads[threadID]
        let state = states[reference(threadID, turnID)]
        let isChild = thread?.parentThreadID != nil
        let agentThreadID = item?.agentThreadId ?? (isChild ? threadID : nil)
        let isAgentActivity = item?.type == .subAgentActivity
        let agentThread = agentThreadID.flatMap { threads[$0] }
        let context = agentThreadID.flatMap { subagentContexts[$0] }
        let agentModel = item?.kind == "started" ? item?.model : agentThread?.model ?? context?.model
        let agentEffort = item?.kind == "started" ? item?.reasoningEffort : agentThread?.reasoningEffort ?? context?.effort
        return ActivityDataRecord(
            timestamp: date, name: phase.rawValue, origin: thread?.origin ?? .unknown,
            cwd: thread?.cwd, toolName: item?.type == .commandExecution ? nil : item?.tool,
            commandActionTypes: item?.type == .commandExecution ? item?.commandActions?.map(\.type) : nil,
            model: isAgentActivity ? agentModel : thread?.model,
            effort: isAgentActivity ? agentEffort : thread?.reasoningEffort,
            threadID: isChild ? state?.rootThreadID : threadID, turnID: isAgentActivity ? nil : turnID, agentThreadID: agentThreadID,
            id: [threadID, turnID, identity ?? item?.id ?? "turn", phase.rawValue].joined(separator: ":")
        )
    }

    private mutating func recordTokenUsage(threadID: String, turnID: String?, update: TokenUsageUpdate, now: Date) {
        guard let turnID else { return }
        tokenUsageSamples.append(TokenUsageSample(
            observedAt: now, threadID: threadID, turnID: turnID,
            turnStartedAt: states[reference(threadID, turnID)]?.startedAt, current: update
        ))
    }
}
