import Foundation

nonisolated struct ActivityUpdate {
    enum Phase {
        case bootstrapStart
        case snapshotEvents
        case bootstrapEnd
        case live
        case sourceUnavailable
        case lifecycleChanged
    }

    let readerID: UUID
    let revision: UInt64
    let phase: Phase
    let graph: ActivityTaskGraph
    let transitions: [ActivityTransition]
    let terminalEvents: [ActivityTerminalEvent]
    let backfilledTasks: Set<ActivityTaskKey>
    var isComplete = true
    let recoveryID: UUID
}

nonisolated enum ActivityEventDrainResult: Sendable {
    case update(ActivityUpdate)
    case sourceUnavailable
    case cancelled
}

/// actor 独占连接与解析状态, UI 仅消费任务图和本次状态变化
actor AppServerActivityReader {
    /// 只排除已确认无需采集的来源, 缺失或未知来源继续正常处理
    private static let ignoredThreadSources: Set<String> = ["thread_title"]

    nonisolated static var defaultSocketURL: URL {
        CodexPaths.codexHomeDirectory().appendingPathComponent("app-server-control/app-server-control.sock")
    }

    private var taskGraph = ActivityTaskGraph()
    private let readerID = UUID()
    private var revision: UInt64 = 0
    private var latestUpdate: ActivityUpdate?
    private var isReconciliationComplete = false
    private let onAccountChange: @MainActor @Sendable (AccountChange) -> Void
    private var pendingAccountChange: AccountChange?
    private let onBatch: @MainActor @Sendable (ActivityUpdate) -> Void
    private let socketURL: URL
    private let logStorage: AppServerLogStore?
    private let tokenUsageHistory: TokenUsageHistoryStore
    private let activityDataRecorder: ActivityDataRecorder
    private var session: AppServerSession?
    private var connectedAt = Date.distantFuture
    private var reducer = AppServerActivityReducer()
    private var subscribed = Set<String>()
    private var ignoredThreads = Set<String>()
    private var loop: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?
    private var tokenUsageRefreshTask: Task<[TokenUsageAggregate], Error>?
    private var generation = 0
    private var reconciledAt = Date.distantPast
    private var lastTokenUsageRefresh = Date.distantPast
    private var isRunning = false
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var stateChanged = false
    private var lastPublished = Date.distantPast
    private var isTokenUsageWriter = false
    private var writerRetryAfter = Date.distantPast
    private var drainWaiters: [DrainWaiter] = []
    private var recoveryID = UUID()
    private var pendingEvents: [(event: ActivityDataRecord, bytes: Int)] = []
    private var pendingPublication: [ActivityDataRecord] = []
    private var pendingSamples: [(sample: TokenUsageSample, bytes: Int)] = []
    private var pendingStorageBytes = 0
    private var deferredNotifications: [ActivityInput] = []
    private var verifiedTurns: [ActivityTurnReference: Date] = [:]
    private var turnScans: [String: TurnScan] = [:]
    private var turnRevisions: [ActivityTurnReference: Int] = [:]
    private let backfill: AppServerActivityBackfill
    private var backfillTask: Task<Void, Never>?
    private var backfillEpoch = UUID()
    private var backfillScans: [ActivityTurnReference: BackfillScan] = [:]
    private var backfillRoots = Set<ActivityTurnReference>()
    private var backfillThreads: [String: Date] = [:]
    private var liveStartedTurns = Set<ActivityTurnReference>()
    private var tokenUsageRestorations: [String: Task<Void, Never>] = [:]

    private struct TurnScan {
        var targets: Set<String>
        var cursor: String?
        var exhausted = false
        var visitedCursors = Set<String>()
    }

    private struct ReadCheckpoint {
        let started = Date()
        let threadRevision: Int
        let turns: [ActivityTurnReference: Int]
    }

    private struct DrainWaiter {
        let recoveryID: UUID
        let continuation: CheckedContinuation<ActivityEventDrainResult, Never>
    }

    private struct ThreadCheck {
        var checkedAt: ContinuousClock.Instant
        var verifiedRevision: Int?
        var recoveryID: UUID?
        var failures = 0
        var failureStartedAt: ContinuousClock.Instant?
        var retryAfter: ContinuousClock.Instant?

        mutating func record(verifiedRevision: Int?, failed: Bool, recoveryID: UUID, now: ContinuousClock.Instant) {
            checkedAt = now
            self.verifiedRevision = verifiedRevision
            if self.recoveryID != recoveryID {
                failures = 0
                failureStartedAt = nil
            }
            self.recoveryID = recoveryID
            guard failed else {
                failures = 0
                failureStartedAt = nil
                retryAfter = verifiedRevision == nil ? now.advanced(by: .seconds(5)) : nil
                return
            }
            failures = min(failures + 1, 4)
            let started = failureStartedAt ?? now
            failureStartedAt = started
            // 快速重试同时受次数和时间限制, 随后保留低频探测以发现延迟落盘的线程
            let delays: [Duration] = [.seconds(5), .seconds(15), .seconds(30), .seconds(60)]
            let delay = now - started < .seconds(60) ? delays[failures - 1] : .seconds(60)
            retryAfter = now.advanced(by: delay)
        }

        mutating func expedite(at now: ContinuousClock.Instant) {
            guard let retryAfter else { return }
            self.retryAfter = min(retryAfter, max(now, checkedAt.advanced(by: .seconds(5))))
        }
    }

    private struct BackfillScan {
        var completed = false
        let createdAt = Date()
        var cursor: String?
        var limit = 20
        var visitedCursors = Set<String>()
        var failures = 0
        var retryAfter = Date.distantPast
        var checkedAt = Date.distantPast
    }

    private var threadChecks: [String: ThreadCheck] = [:]
    private var revisions: [String: Int] = [:]
    private var preparingThread: String?
    private var invalidThreads = Set<String>()
    private var storageRetryAfter = Date.distantPast
    private var isHistoryRecordingPaused = false
    private var tokenUsageRetryAfter = Date.distantPast
    private let maximumPendingEvents: Int
    private let maximumPendingBytes: Int
    private let maximumLoadedPages: Int
    private let reconciliationTimeout: TimeInterval
    private let discoveryInterval: TimeInterval
    private let reconciliationClock: @Sendable () -> ContinuousClock.Instant

    init(
        socketURL: URL = AppServerActivityReader.defaultSocketURL,
        logStorage: AppServerLogStore?,
        tokenUsageHistory: TokenUsageHistoryStore = TokenUsageHistoryStore(),
        activityDataRecorder: ActivityDataRecorder = ActivityDataRecorder(),
        maximumPendingEvents: Int = 4096,
        maximumPendingBytes: Int = 8 * 1024 * 1024,
        maximumLoadedPages: Int = 100,
        reconciliationTimeout: TimeInterval = 30,
        discoveryInterval: TimeInterval = 2,
        reconciliationClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        onAccountChange: @escaping @MainActor @Sendable (AccountChange) -> Void = { _ in },
        onBatch: @escaping @MainActor @Sendable (ActivityUpdate) -> Void
    ) {
        self.socketURL = socketURL
        backfill = AppServerActivityBackfill(socketURL: socketURL, logStorage: logStorage)
        self.logStorage = logStorage
        self.tokenUsageHistory = tokenUsageHistory
        self.activityDataRecorder = activityDataRecorder
        self.maximumPendingEvents = maximumPendingEvents
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumLoadedPages = maximumLoadedPages
        self.reconciliationTimeout = reconciliationTimeout
        self.discoveryInterval = discoveryInterval
        self.reconciliationClock = reconciliationClock
        self.onAccountChange = onAccountChange
        self.onBatch = onBatch
    }

    func start() {
        guard !isRunning, !isStopping else { return }
        isRunning = true
        generation += 1
        let current = generation
        startStorageWorker()
        loop = Task { [weak self] in await self?.run(generation: current) }
    }

    @discardableResult
    func stop() async -> Bool {
        if isStopping {
            return await withCheckedContinuation { stopWaiters.append($0) }
        }
        isStopping = true
        var saved = false
        defer {
            isStopping = false
            let waiters = stopWaiters
            stopWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: saved)
            }
        }
        isRunning = false
        generation += 1
        tokenUsageRefreshTask?.cancel()
        let previous = loop
        previous?.cancel()
        loop = nil
        session?.close()
        session = nil
        subscribed.removeAll()
        await previous?.value
        ignoredThreads.removeAll()
        pendingAccountChange = nil
        pendingPublication.removeAll()
        deferredNotifications.removeAll()
        verifiedTurns.removeAll()
        turnScans.removeAll()
        turnRevisions.removeAll()
        cancelBackfill()
        threadChecks.removeAll()
        invalidThreads.removeAll()
        if storageTask == nil, !pendingEvents.isEmpty || !pendingSamples.isEmpty {
            startStorageWorker()
        }
        // 退出只给已接收记录有限的排空时间, 慢文件操作不能卡住 App 退出
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while storageTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        saved = storageTask == nil && pendingEvents.isEmpty && pendingSamples.isEmpty
        storageTask?.cancel()
        completeDrains(.cancelled)
        return saved
    }

    /// 每次调用执行本次请求之后的查询, 不复用正在进行的旧快照
    /// 同一轮恢复只补读未核对成功的线程, 新一轮恢复仍执行完整读取屏障
    func drainForRecovery(generation: UUID) async -> ActivityEventDrainResult {
        guard isRunning, !Task.isCancelled else { return .cancelled }
        guard session != nil else { return .sourceUnavailable }
        let result = await withCheckedContinuation {
            drainWaiters.append(DrainWaiter(recoveryID: generation, continuation: $0))
        }
        return Task.isCancelled ? .cancelled : result
    }

    private func run(generation current: Int) async {
        while isRunning, generation == current, !Task.isCancelled {
            do {
                if session == nil {
                    try await connect(generation: current)
                }
                try await consumeAvailable(generation: current)
                if !drainWaiters.isEmpty || Date().timeIntervalSince(reconciledAt) >= discoveryInterval {
                    let waiters = drainWaiters
                    drainWaiters.removeAll()
                    let requestedRecovery = waiters.last?.recoveryID
                    let forced = requestedRecovery != nil && requestedRecovery != recoveryID
                    if forced, let requestedRecovery {
                        recoveryID = requestedRecovery
                    }
                    do {
                        try await reconcile(bootstrap: false, forced: forced, recovering: requestedRecovery != nil, generation: current)
                        try await consumeAvailable(generation: current)
                        let result: ActivityEventDrainResult = if !isRunning || generation != current || Task.isCancelled {
                            .cancelled
                        } else if let latestUpdate {
                            .update(latestUpdate)
                        } else {
                            .sourceUnavailable
                        }
                        for waiter in waiters {
                            waiter.continuation.resume(returning: result)
                        }
                    } catch {
                        for waiter in waiters {
                            waiter.continuation.resume(returning: .sourceUnavailable)
                        }
                        throw error
                    }
                }
                scheduleBackfill(generation: current)
                try await Task.sleep(for: .milliseconds(100))
            } catch is CancellationError {
                completeDrains(.cancelled)
                return
            } catch {
                await recover(from: error, generation: current)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func connect(generation current: Int) async throws {
        // 首批通知到达前确认采集租约, 避免连接和存储任务的启动顺序决定是否记账
        try acquireTokenUsageWriter(generation: current)
        isReconciliationComplete = false
        recoveryID = UUID()
        reducer.reconnect()
        reducer.setTokenUsageRecordingEnabled(isTokenUsageWriter && !isHistoryRecordingPaused)
        try checkGeneration(current)
        await publish(.bootstrapStart)
        try checkGeneration(current)
        let connection = try AppServerSession(socketURL: socketURL, logStorage: logStorage)
        do {
            try connection.initialize(clientName: "codex_bar_activity", minimumVersion: CodexVersionReader.minimumAppServerVersion)
        } catch {
            connection.close()
            throw error
        }
        session = connection
        connectedAt = Date()
        try await reconcile(bootstrap: true, forced: true, generation: current)
        try checkGeneration(current)
        await publish(.bootstrapEnd)
    }

    private func acquireTokenUsageWriter(generation current: Int) throws {
        guard !isTokenUsageWriter, Date() >= writerRetryAfter else { return }
        do {
            if try tokenUsageHistory.acquireRecordingLease() {
                try checkGeneration(current)
                isTokenUsageWriter = true
                writerRetryAfter = .distantPast
                reducer.setTokenUsageRecordingEnabled(!isHistoryRecordingPaused)
            } else {
                writerRetryAfter = Date().addingTimeInterval(1)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if writerRetryAfter == .distantPast {
                logStorage?.recordFailure(method: "activity/storage", message: error.localizedDescription, connection: "activity")
            }
            writerRetryAfter = Date().addingTimeInterval(1)
        }
    }

    private func recover(from error: Error, generation current: Int) async {
        guard generation == current, isRunning else { return }
        logStorage?.recordFailure(method: "activity/connection", message: error.localizedDescription, connection: "activity")
        // 后续协议错误不能丢掉前面已取得的有效结果, 存储失败时保留队列供下一轮重试
        try? await flushPending(generation: current)
        guard generation == current, isRunning else { return }
        await disconnected()
    }

    private func completeDrains(_ result: ActivityEventDrainResult) {
        let pending = drainWaiters
        drainWaiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: result)
        }
    }

    private func disconnected() async {
        completeDrains(.sourceUnavailable)
        session?.close()
        session = nil
        subscribed.removeAll()
        ignoredThreads.removeAll()
        deferredNotifications.removeAll()
        pendingAccountChange = nil
        verifiedTurns.removeAll()
        turnScans.removeAll()
        turnRevisions.removeAll()
        cancelBackfill()
        invalidThreads.removeAll()
        threadChecks.removeAll()
        await publish(.sourceUnavailable)
    }

    private func reconcile(bootstrap: Bool, forced: Bool, recovering: Bool = false, generation current: Int) async throws {
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(reconciliationTimeout))
        try await AppServerRequestBudget.$current.withValue(budget) {
            try await reconcileWithinBudget(bootstrap: bootstrap, forced: forced, recovering: recovering, generation: current)
        }
    }

    private func loadThreads(generation current: Int) async throws -> Set<String> {
        var loaded = Set<String>()
        var cursor: String?
        var cursors = Set<String>()
        for _ in 0 ..< maximumLoadedPages {
            let page = try await request(ActivityRequests.loadedThreads(cursor: cursor), generation: current)
            loaded.formUnion(page.data)
            guard loaded.count <= 10000 else { throw CodexStatusError.invalidServerResponse }
            guard let next = page.nextCursor else { return loaded }
            guard cursors.insert(next).inserted else { throw CodexStatusError.invalidServerResponse }
            cursor = next
        }
        // 不发布截断列表, 否则未读取的会话会被错误地当作已经卸载
        throw CodexStatusError.invalidServerResponse
    }

    private func reconcileWithinBudget(bootstrap: Bool, forced: Bool, recovering: Bool, generation current: Int) async throws {
        let loaded = try await loadThreads(generation: current)
        pruneBackfill(now: Date())
        ignoredThreads.formIntersection(loaded)
        let knownActive = Set(reducer.states.keys.filter {
            reducer.states[$0]?.terminal == nil && reducer.threads[$0.threadID]?.status?.type != .notLoaded
        }.map(\.threadID))
        let now = reconciliationClock()
        let dependencies = Set(reducer.missingRootTurns(liveOnly: forced || recovering).keys)
            .union(reducer.missingSubagentParents(liveOnly: forced || recovering)).union(backfillThreads.keys)
        // 历史关联保留补读资格, 只有实时依赖需要快速核对
        let liveDependencies = Set(reducer.missingRootTurns(liveOnly: true).keys)
            .union(reducer.missingSubagentParents(liveOnly: true))
        let required = loaded.union(knownActive).union(liveDependencies)
        let candidates = loaded.union(knownActive).union(dependencies).subtracting(ignoredThreads).filter { id in
            let interval: TimeInterval = invalidThreads.contains(id) || knownActive.contains(id)
                || liveDependencies.contains(id) || reducer.threads[id]?.status?.type == .active ? 5 : 60
            guard !forced, let check = threadChecks[id] else { return true }
            if let retryAfter = check.retryAfter {
                return now >= retryAfter
            }
            if recovering, !isThreadVerified(id) {
                return true
            }
            return now - check.checkedAt >= .seconds(interval)
        }.sorted {
            if required.contains($0) != required.contains($1) {
                return required.contains($0)
            }
            if (threadChecks[$0] == nil) != (threadChecks[$1] == nil) {
                return threadChecks[$0] == nil
            }
            return (threadChecks[$0]?.checkedAt ?? now, $0) < (threadChecks[$1]?.checkedAt ?? now, $1)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        for id in candidates {
            try checkGeneration(current)
            try await reconcileThread(id, loaded: loaded, bootstrap: bootstrap, forced: forced || (recovering && !isThreadVerified(id)), generation: current)
            // 日常核对分轮执行, 强制排空则等待本轮完整覆盖
            if !forced, ContinuousClock.now >= deadline {
                break
            }
        }
        reducer.maintain(loadedThreads: loaded.subtracting(ignoredThreads), now: Date())
        pruneBackfill(now: Date())
        subscribed.formIntersection(loaded)
        let retained = loaded.union(knownActive).union(dependencies).subtracting(ignoredThreads)
        threadChecks = threadChecks.filter { retained.contains($0.key) }
        revisions = revisions.filter { retained.contains($0.key) }
        verifiedTurns = verifiedTurns.filter { reducer.states[$0.key] != nil && retained.contains($0.key.threadID) }
        turnScans = turnScans.filter { retained.contains($0.key) }
        turnRevisions = turnRevisions.filter { reducer.states[$0.key] != nil && retained.contains($0.key.threadID) }
        liveStartedTurns = liveStartedTurns.filter { reducer.states[$0] != nil }
        invalidThreads.formIntersection(retained)
        reconciledAt = Date()
        try checkGeneration(current)
        isReconciliationComplete = loaded.union(knownActive).subtracting(ignoredThreads).allSatisfy(isThreadVerified)
            && !reducer.states.values.contains {
                $0.terminal == nil && ($0.rootThreadID == nil || $0.rootTurnID == nil)
            }
        if !bootstrap {
            await publish(.lifecycleChanged)
        }
    }

    private func isThreadVerified(_ id: String) -> Bool {
        guard let check = threadChecks[id] else { return false }
        return check.verifiedRevision == revisions[id, default: 0] && check.recoveryID == recoveryID
    }

    private func reconcileThread(_ id: String, loaded: Set<String>, bootstrap: Bool, forced: Bool, generation current: Int) async throws {
        guard !ignoredThreads.contains(id) else { return }
        let checkpoint = ReadCheckpoint(threadRevision: revisions[id, default: 0], turns: turnRevisions)
        let active = Set(reducer.states.keys.filter { $0.threadID == id && reducer.states[$0]?.terminal == nil }.map(\.turnID))
        var remaining = active.union(reducer.missingRootTurns(liveOnly: forced)[id] ?? [])
        let newSubscription = !subscribed.contains(id)
        if newSubscription {
            preparingThread = id
        }
        defer { preparingThread = nil }
        var covered = false
        var failed = true
        do {
            let read: ActivityThreadRead = try await request(ActivityRequests.thread(id), generation: current)
            var thread = read.thread
            if ignoreIfNeeded(thread) {
                return
            }
            if loaded.contains(id), newSubscription, thread.status?.type != .notLoaded {
                let joined: ActivityThreadResume = try await request(ActivityRequests.subscribe(id), generation: current)
                thread = joined.thread
                if ignoreIfNeeded(thread) {
                    return
                }
                subscribed.insert(id)
            }
            if newSubscription {
                reducer.threads[id] = thread
            }
            let first = try await request(ActivityRequests.turns(id, limit: 10), generation: current)
            await applySnapshot(thread: thread, turns: first.data, checkpoint: checkpoint, bootstrap: bootstrap || newSubscription)
            remaining.subtract(first.data.map(\.id))
            // 首个小页建立轮次身份后立即处理通知, 避免后续分页查询延迟实时事件
            preparingThread = nil
            consumeDeferred(for: id)
            if newSubscription {
                restoreTokenUsage(threadID: id, generation: current)
            }
            scheduleHistoryTargets(threadID: id, turns: first.data, joined: newSubscription)
            try await flushPending(generation: current)
            let result = try await readRemainingTurns(
                thread: thread, remaining: remaining, firstCursor: first.nextCursor, checkpoint: checkpoint,
                bootstrap: bootstrap || newSubscription, forced: forced, generation: current
            )
            remaining = result.remaining
            for turnID in remaining.intersection(active) {
                let key = ActivityTurnReference(threadID: id, turnID: turnID)
                guard checkpoint.turns[key, default: 0] == turnRevisions[key, default: 0], reducer.states[key]?.terminal == nil else { continue }
                verifiedTurns[key] = nil
                reducer.states[key]?.readStatus = result.exhausted ? .notFound : .unavailable
            }
            let unchanged = checkpoint.threadRevision == revisions[id, default: 0]
            if unchanged {
                invalidThreads.remove(id)
                finishBackfillDiscovery(threadID: id, turns: first.data, remaining: remaining)
            }
            if invalidThreads.contains(id) {
                reducer.invalidateThread(id)
            }
            covered = unchanged && remaining.isDisjoint(with: active) && thread.status?.type != .notLoaded
            failed = thread.status?.type == .notLoaded || (result.exhausted && !remaining.isDisjoint(with: active))
            try await flushPending(generation: current)
        } catch CodexStatusError.invalidResponsePayload {
            consumeDeferred(for: id)
            invalidateThread(id, method: "activity/thread")
        } catch let error as CodexStatusError where error.isMissingRollout(for: id)
            || (!error.isTransportFailure && !error.isProtocolOrParameterFailure) {
            reducer.invalidateThread(id)
            verifiedTurns = verifiedTurns.filter { $0.key.threadID != id }
            turnScans[id] = nil
            subscribed.remove(id)
            consumeDeferred(for: id)
        } catch {
            consumeDeferred(for: id)
            throw error
        }
        try checkGeneration(current)
        let now = reconciliationClock()
        var check = threadChecks[id] ?? ThreadCheck(checkedAt: now)
        check.record(verifiedRevision: covered ? checkpoint.threadRevision : nil, failed: failed, recoveryID: recoveryID, now: now)
        threadChecks[id] = check
    }

    private func readRemainingTurns(
        thread: ActivityThread, remaining initial: Set<String>, firstCursor: String?, checkpoint: ReadCheckpoint,
        bootstrap: Bool, forced: Bool, generation current: Int
    ) async throws -> (remaining: Set<String>, exhausted: Bool) {
        let id = thread.id
        var remaining = initial
        var scan = turnScans[id] ?? TurnScan(targets: remaining, cursor: firstCursor)
        if !remaining.isSubset(of: scan.targets), scan.exhausted {
            scan = TurnScan(targets: remaining, cursor: firstCursor)
        }
        // 扫描期间新增的目标留给后续一轮, 不将正在推进的游标退回首页
        let pendingTargets = remaining.subtracting(scan.targets)
        turnScans[id] = scan
        for _ in 0 ..< (forced ? 8 : 1) {
            guard !remaining.isEmpty, !scan.exhausted, let cursor = scan.cursor else { break }
            let pageCheckpoint = ReadCheckpoint(threadRevision: checkpoint.threadRevision, turns: turnRevisions)
            let page = try await request(ActivityRequests.turns(id, limit: 100, cursor: cursor), generation: current)
            guard page.nextCursor != cursor, page.nextCursor.map({ !scan.visitedCursors.contains($0) }) ?? true else {
                throw CodexStatusError.invalidServerResponse
            }
            scan.visitedCursors.insert(cursor)
            await applySnapshot(thread: thread, turns: page.data, checkpoint: pageCheckpoint, bootstrap: bootstrap)
            scheduleHistoryTargets(threadID: id, turns: page.data, joined: false)
            remaining.subtract(page.data.map(\.id))
            scan.cursor = page.nextCursor
            scan.exhausted = page.nextCursor == nil
            turnScans[id] = scan
            try await flushPending(generation: current)
        }
        if scan.cursor == nil {
            scan.exhausted = true
        }
        if scan.exhausted, !pendingTargets.isDisjoint(with: remaining) {
            scan = TurnScan(targets: remaining, cursor: firstCursor)
        }
        turnScans[id] = remaining.isEmpty ? nil : scan
        return (remaining, scan.exhausted)
    }

    private func applySnapshot(thread: ActivityThread, turns: [ActivityTurn], checkpoint: ReadCheckpoint, bootstrap: Bool) async {
        let threadChanged = checkpoint.threadRevision != revisions[thread.id, default: 0]
        let changedTurns = Set(turns.filter { turn in
            let key = ActivityTurnReference(threadID: thread.id, turnID: turn.id)
            return checkpoint.turns[key, default: 0] != turnRevisions[key, default: 0]
        }.map(\.id))
        let events = reducer.reconcile(
            thread: thread, turns: turns, now: Date(), bootstrap: bootstrap,
            preservingThreadState: threadChanged, preservingTurns: changedTurns
        )
        if !threadChanged {
            for turn in turns where !changedTurns.contains(turn.id) {
                verifiedTurns[ActivityTurnReference(threadID: thread.id, turnID: turn.id)] = checkpoint.started
            }
        }
        if !events.isEmpty {
            await publish(.snapshotEvents, events: events)
        }
    }

    private func finishBackfillDiscovery(threadID: String, turns: [ActivityTurn], remaining: Set<String>) {
        guard !turns.isEmpty, remaining.isEmpty, turns.allSatisfy({
            reducer.states[ActivityTurnReference(threadID: threadID, turnID: $0.id)]?.readStatus == .complete
        }) else { return }
        // 轮次身份已交给 reducer 和补查队列, 不再为历史发现单独轮询会话
        backfillThreads[threadID] = nil
    }

    private func pruneBackfill(now: Date) {
        let cutoff = now.addingTimeInterval(-ActivityRetention.window)
        backfillScans = backfillScans.filter {
            reducer.states[$0.key] != nil || (!$0.value.completed && $0.value.createdAt > cutoff)
        }
        backfillRoots = backfillRoots.filter { reducer.states[$0] != nil || backfillScans[$0] != nil }
        backfillThreads = backfillThreads.filter { $0.value > cutoff }
    }

    private func cancelBackfill() {
        backfillEpoch = UUID()
        backfillTask?.cancel()
        backfillTask = nil
        backfillScans.removeAll()
        backfillRoots.removeAll()
        backfillThreads.removeAll()
        liveStartedTurns.removeAll()
        for task in tokenUsageRestorations.values {
            task.cancel()
        }
        tokenUsageRestorations.removeAll()
    }

    private func restoreTokenUsage(threadID: String, generation current: Int) {
        guard tokenUsageRestorations[threadID] == nil else { return }
        let epoch = backfillEpoch
        tokenUsageRestorations[threadID] = Task { [weak self, tokenUsageHistory] in
            let result = try? await tokenUsageHistory.snapshot(threadID: threadID)
            guard let self else { return }
            await finishTokenUsageRestoration(result, threadID: threadID, epoch: epoch, generation: current)
        }
    }

    private func finishTokenUsageRestoration(_ snapshot: TokenUsageThreadSnapshot?, threadID: String, epoch: UUID, generation current: Int) {
        guard generation == current, backfillEpoch == epoch, isRunning else { return }
        tokenUsageRestorations[threadID] = nil
        if let snapshot {
            reducer.applyTokenUsage(snapshot)
            stateChanged = true
        }
    }

    private func scheduleHistoryTargets(threadID: String, turns: [ActivityTurn], joined: Bool) {
        for turn in turns {
            let reference = ActivityTurnReference(threadID: threadID, turnID: turn.id)
            let state = reducer.states[reference]
            let root = state.flatMap { state -> ActivityTurnReference? in
                guard let thread = state.rootThreadID, let turn = state.rootTurnID else { return nil }
                return ActivityTurnReference(threadID: thread, turnID: turn)
            }
            let existedBeforeConnection = !liveStartedTurns.contains(reference) && (turn.startedAt.map { $0 < connectedAt } ?? true)
            let midTurn = joined && turn.status == .running && existedBeforeConnection
            guard existedBeforeConnection, midTurn || root.map({ backfillRoots.contains($0) }) == true else { continue }
            if midTurn, let root {
                backfillRoots.insert(root)
            }
            guard backfillScans[reference] == nil, backfillScans.count < 10000 else { continue }
            backfillScans[reference] = BackfillScan()
        }
    }

    private func scheduleBackfill(generation current: Int) {
        guard backfillTask == nil, session != nil else { return }
        for reference in backfillScans.keys {
            if let state = reducer.states[reference], let thread = state.rootThreadID, let turn = state.rootTurnID {
                backfillRoots.insert(ActivityTurnReference(threadID: thread, turnID: turn))
            }
        }
        for (reference, state) in reducer.states where backfillScans[reference] == nil && backfillScans.count < 10000 {
            guard !liveStartedTurns.contains(reference), state.startedAt.map({ $0 < connectedAt }) ?? true,
                  let thread = state.rootThreadID, let turn = state.rootTurnID,
                  backfillRoots.contains(ActivityTurnReference(threadID: thread, turnID: turn)) else { continue }
            backfillScans[reference] = BackfillScan()
        }
        guard let reference = backfillScans.keys.filter({
            guard let scan = backfillScans[$0] else { return false }
            return !scan.completed && scan.retryAfter <= Date()
        }).min(by: {
            (backfillScans[$0]!.checkedAt, backfillRoots.contains($0) ? 0 : 1, $0.threadID, $0.turnID)
                < (backfillScans[$1]!.checkedAt, backfillRoots.contains($1) ? 0 : 1, $1.threadID, $1.turnID)
        }), let scan = backfillScans[reference] else { return }
        backfillScans[reference]?.checkedAt = Date()
        let epoch = backfillEpoch
        backfillTask = Task { [weak self, backfill, reconciliationTimeout] in
            let result: Result<AppServerActivityBackfill.Page, Error>
            do {
                result = try await .success(backfill.readPage(
                    reference: reference, cursor: scan.cursor, limit: scan.limit, timeout: reconciliationTimeout
                ))
            } catch {
                result = .failure(error)
            }
            await self?.finishBackfill(result, reference: reference, epoch: epoch, generation: current)
        }
    }

    private func finishBackfill(_ result: Result<AppServerActivityBackfill.Page, Error>, reference: ActivityTurnReference, epoch: UUID, generation current: Int) async {
        guard isRunning, generation == current, backfillEpoch == epoch else { return }
        defer {
            if backfillEpoch == epoch {
                backfillTask = nil
            }
        }
        guard !Task.isCancelled, var scan = backfillScans[reference] else { return }
        do {
            let page = try result.get()
            guard page.nextCursor.map({ !scan.visitedCursors.contains($0) }) ?? true else { throw CodexStatusError.invalidServerResponse }
            let events = reducer.historicalEvents(page.items, reference: reference, now: Date())
                + reducer.historicalTurnEvents(reference)
            try await activityDataRecorder.record(events: events)
            guard isRunning, generation == current, backfillEpoch == epoch, !Task.isCancelled, backfillScans[reference] != nil else { return }
            for entry in page.items where entry.item.type == .subAgentActivity && entry.item.kind == "started" {
                if let child = entry.item.agentThreadId, backfillThreads.count < 10000 {
                    backfillThreads[child] = backfillThreads[child] ?? Date()
                }
            }
            scan.limit = page.limit
            if let cursor = scan.cursor {
                scan.visitedCursors.insert(cursor)
            }
            scan.cursor = page.nextCursor
            scan.failures = 0
            scan.completed = page.nextCursor == nil
            backfillScans[reference] = scan.completed ? BackfillScan(completed: true) : scan
            await publish(.lifecycleChanged)
        } catch {
            guard isRunning, generation == current, backfillEpoch == epoch, !Task.isCancelled, backfillScans[reference] != nil else { return }
            scan.failures += 1
            scan.retryAfter = Date().addingTimeInterval(scan.failures == 1 ? 5 : 15)
            let status = error as? CodexStatusError
            let oversized = if case .messageTooLarge = status {
                true
            } else {
                false
            }
            scan.completed = scan.failures >= 3 || status?.isProtocolOrParameterFailure == true || oversized
            backfillScans[reference] = scan.completed ? BackfillScan(completed: true) : scan
            logStorage?.recordFailure(method: "activity/backfill", message: error.localizedDescription, connection: "activity/backfill")
        }
    }

    private func consumeDeferred(for id: String) {
        guard reducer.threads[id] != nil else { return }
        let pending = deferredNotifications.filter { ($0.params.threadId ?? $0.params.thread?.id) == id }
        deferredNotifications.removeAll { ($0.params.threadId ?? $0.params.thread?.id) == id }
        for notification in pending {
            consume(notification)
        }
    }

    private func request<Response>(_ request: AppServerRequest<Response>, generation current: Int) async throws -> Response {
        try checkGeneration(current)
        guard let connection = session else { throw CodexStatusError.serverConnectionClosed }
        let pending = try connection.beginRequest(request.method, params: request.params ?? [:])
        var received = false
        do {
            while true {
                try checkGeneration(current)
                switch try connection.poll(pending) {
                case .waiting:
                    try await Task.sleep(for: .milliseconds(10))
                case let .event(data):
                    try consume(data)
                    try await flushPending(generation: current, force: false)
                    await Task.yield()
                case let .response(data):
                    received = true
                    return try AppServerRPC.decode(data, as: Response.self)
                }
            }
        } catch {
            if !received {
                connection.fail(pending, error: error)
            }
            throw error
        }
    }

    private func checkGeneration(_ current: Int) throws {
        try AppServerRequestBudget.checkCurrent()
        guard generation == current, isRunning else { throw CancellationError() }
    }

    private func consume(_ data: Data) throws {
        let method = try JSONDecoder().decode(MethodEnvelope.self, from: data).method
        if let change = AccountChange(method: method) {
            pendingAccountChange = change.merging(pendingAccountChange)
            return
        }
        guard AppServerActivityProtocol.kind(for: method).category != .ignored else { return }
        let notification: ActivityInput
        do {
            notification = try JSONDecoder().decode(ActivityInput.self, from: data)
        } catch is DecodingError {
            guard let threadID = AppServerActivityProtocol.recoveryThreadID(from: data) else { throw CodexStatusError.invalidServerResponse }
            guard !ignoredThreads.contains(threadID) else { return }
            invalidateThread(threadID, method: method)
            return
        }
        let id = notification.params.threadId ?? notification.params.thread?.id
        if let thread = notification.params.thread, ignoreIfNeeded(thread) {
            return
        }
        if let id, ignoredThreads.contains(id) {
            return
        }
        if let id, preparingThread != id {
            expediteRetry(for: notification, threadID: id)
        }
        if let id, preparingThread == id || (reducer.threads[id] == nil && notification.params.thread == nil) {
            guard deferredNotifications.count < 4096 else { throw CodexStatusError.invalidServerResponse }
            deferredNotifications.append(notification)
            return
        }
        consume(notification)
    }

    private func expediteRetry(for notification: ActivityInput, threadID: String) {
        guard threadChecks[threadID]?.retryAfter != nil else { return }
        let hasActivity: Bool = switch notification.kind {
        case .threadDiscovered: notification.params.thread?.status?.type == .active
        case .threadStatusChanged: notification.params.status?.type == .active
        case .turnStarted, .turnFinished: notification.params.turn?.id.isEmpty == false
        case .itemStarted, .itemFinished, .usageUpdated, .replyProgress, .reasoningProgress, .reasoningSummaryProgress, .commandProgress:
            notification.params.turnId?.isEmpty == false
        default: false
        }
        guard hasActivity else { return }
        let now = reconciliationClock()
        // 有效活动可提前触发单线程探测, 重复通知不重置失败预算且重试至少间隔 5 秒
        threadChecks[threadID]?.expedite(at: now)
        if let retryAfter = threadChecks[threadID]?.retryAfter, retryAfter <= now {
            reconciledAt = .distantPast
        }
    }

    private func ignoreIfNeeded(_ thread: ActivityThread) -> Bool {
        guard let source = thread.threadSource, Self.ignoredThreadSources.contains(source) else { return ignoredThreads.contains(thread.id) }
        ignoredThreads.insert(thread.id)
        invalidThreads.remove(thread.id)
        deferredNotifications.removeAll { ($0.params.threadId ?? $0.params.thread?.id) == thread.id }
        return true
    }

    private func consume(_ notification: ActivityInput) {
        stateChanged = true
        recordStateChange(notification)
        let events = reducer.consume(notification, now: Date())
        pendingPublication += events
        if let id = notification.params.threadId ?? notification.params.thread?.id, invalidThreads.contains(id) {
            reducer.invalidateThread(id)
        }
        let samples = reducer.takeTokenUsageSamples()
        enqueueHistory(events: events, samples: samples)
    }

    private func recordStateChange(_ notification: ActivityInput) {
        guard let id = notification.params.threadId ?? notification.params.thread?.id else { return }
        let previousRevision = revisions[id, default: 0]
        switch notification.kind {
        case .threadDiscovered, .threadStatusChanged, .turnStarted, .turnFinished,
             .commandApprovalRequested, .fileApprovalRequested, .permissionsRequested, .inputRequested, .userInputRequested, .requestResolved:
            revisions[id, default: 0] += 1
        case .itemStarted, .itemFinished:
            if notification.params.item?.affectsInputWait == true {
                revisions[id, default: 0] += 1
            }
        default: break
        }
        if previousRevision != revisions[id, default: 0] {
            isReconciliationComplete = false
        }
        if notification.kind == .turnStarted, let turn = notification.params.turn, turn.startedAt.map({ $0 >= connectedAt }) ?? true {
            liveStartedTurns.insert(ActivityTurnReference(threadID: id, turnID: turn.id))
        }
        if notification.kind == .turnStarted || notification.kind == .turnFinished, let turn = notification.params.turn {
            turnRevisions[ActivityTurnReference(threadID: id, turnID: turn.id), default: 0] += 1
        }
    }

    private func consumeAvailable(generation current: Int) async throws {
        try await flushPending(generation: current)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        for _ in 0 ..< 256 {
            try checkGeneration(current)
            guard let data = try session?.nextEvent() else { break }
            try consume(data)
            try await flushPending(generation: current, force: false)
            if ContinuousClock.now >= deadline {
                break
            }
        }
        try await flushPending(generation: current)
    }

    private func startStorageWorker() {
        guard storageTask == nil else { return }
        let current = generation
        storageTask = Task { [weak self] in await self?.runStorage(generation: current) }
    }

    private func runStorage(generation current: Int) async {
        while isRunning, generation == current, !Task.isCancelled {
            do {
                try acquireTokenUsageWriter(generation: current)
                await retryStorage()
                try checkGeneration(current)
                await refreshTokenUsageHistory(generation: current)
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        var failures = 0
        while !Task.isCancelled, failures < 3, !pendingEvents.isEmpty || !pendingSamples.isEmpty {
            do {
                try await persistPending()
            } catch {
                failures += 1
                recordStorageFailure(error)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        tokenUsageHistory.releaseRecordingLease()
        isTokenUsageWriter = false
        reducer.setTokenUsageRecordingEnabled(false)
        storageTask = nil
        // 上一次排空尚未结束时重新启用, 必须等旧写入确认后再启动下一轮
        if isRunning {
            startStorageWorker()
        }
    }

    private func persistPending() async throws {
        var failure: Error?
        do {
            for pending in pendingEvents.prefix(64) {
                try Task.checkCancellation()
                try await activityDataRecorder.record(event: pending.event)
                pendingEvents.removeFirst()
                pendingStorageBytes -= pending.bytes
            }
        } catch {
            failure = error
        }
        do {
            for pending in pendingSamples.prefix(64) {
                try Task.checkCancellation()
                let snapshot = try await tokenUsageHistory.record(pending.sample)
                reducer.applyTokenUsage(snapshot)
                stateChanged = true
                pendingSamples.removeFirst()
                pendingStorageBytes -= pending.bytes
            }
        } catch {
            failure = failure ?? error
        }
        if let failure {
            throw failure
        }
    }

    private func refreshTokenUsageHistory(generation current: Int) async {
        guard isTokenUsageWriter, pendingSamples.isEmpty, Date() >= tokenUsageRetryAfter,
              Date().timeIntervalSince(lastTokenUsageRefresh) >= 1 else { return }
        let refresh = Task { try await tokenUsageHistory.refresh() }
        tokenUsageRefreshTask = refresh
        defer { tokenUsageRefreshTask = nil }
        do {
            _ = try await refresh.value
            guard generation == current, isRunning, !Task.isCancelled else { return }
            tokenUsageRetryAfter = .distantPast
            lastTokenUsageRefresh = Date()
        } catch is CancellationError {
            return
        } catch {
            guard generation == current, isRunning else { return }
            if tokenUsageRetryAfter == .distantPast {
                logStorage?.recordFailure(method: "activity/storage", message: error.localizedDescription, connection: "activity")
            }
            tokenUsageRetryAfter = Date().addingTimeInterval(1)
        }
    }

    private func flushPending(generation current: Int, force: Bool = true) async throws {
        try checkGeneration(current)
        if let change = pendingAccountChange {
            pendingAccountChange = nil
            await onAccountChange(change)
            try checkGeneration(current)
        }
        guard stateChanged || !pendingPublication.isEmpty else { return }
        if !force, pendingPublication.isEmpty, Date().timeIntervalSince(lastPublished) < 0.1 {
            return
        }
        try checkGeneration(current)
        stateChanged = false
        lastPublished = Date()
        let events = pendingPublication
        pendingPublication.removeAll()
        if !events.isEmpty {
            await publish(.live, events: events)
        }
        await publish(.lifecycleChanged)
    }

    var lifecycleSnapshot: TurnLifecycleSnapshot {
        TurnLifecycleSnapshot(states: reducer.states, verifiedTurns: verifiedTurns)
    }

    private func publish(_ phase: ActivityUpdate.Phase, events: [ActivityDataRecord] = []) async {
        if case .bootstrapStart = phase {
            taskGraph = ActivityTaskGraph()
        }
        let source: ActivityEventSource = if case .live = phase {
            .live
        } else {
            .bootstrap
        }
        let transitions = taskGraph.update(events: events, source: source, lifecycle: lifecycleSnapshot)
        let terminalEvents = taskGraph.terminalEvents
        let backfilledTasks = taskGraph.backfilledTasks
        taskGraph.terminalEvents.removeAll(keepingCapacity: true)
        taskGraph.backfilledTasks.removeAll(keepingCapacity: true)
        revision &+= 1
        let update = ActivityUpdate(
            readerID: readerID,
            revision: revision,
            phase: phase,
            graph: taskGraph,
            transitions: transitions,
            terminalEvents: terminalEvents,
            backfilledTasks: backfilledTasks,
            isComplete: isReconciliationComplete,
            recoveryID: recoveryID
        )
        latestUpdate = update
        await onBatch(update)
    }

    private func enqueueHistory(events: [ActivityDataRecord], samples: [TokenUsageSample]) {
        do {
            for event in events {
                guard !isHistoryRecordingPaused else { return }
                let bytes = try AppServerEventRecord(activityData: event).jsonLineData().count
                pendingEvents.append((event, bytes))
                pendingStorageBytes += bytes
                enforceStorageLimit()
            }
            for sample in samples where isTokenUsageWriter {
                guard !isHistoryRecordingPaused else { return }
                let bytes = try JSONLines.stableEncoder.encode(sample).count
                pendingSamples.append((sample, bytes))
                pendingStorageBytes += bytes
                enforceStorageLimit()
            }
        } catch {
            recordStorageFailure(error)
            pauseHistoryRecording()
        }
    }

    private func enforceStorageLimit() {
        if pendingEvents.count + pendingSamples.count >= maximumPendingEvents || pendingStorageBytes >= maximumPendingBytes {
            pauseHistoryRecording()
        }
    }

    private func pauseHistoryRecording() {
        isHistoryRecordingPaused = true
        reducer.setTokenUsageRecordingEnabled(false)
    }

    private func invalidateThread(_ id: String, method: String) {
        isReconciliationComplete = false
        let firstFailure = invalidThreads.insert(id).inserted
        verifiedTurns = verifiedTurns.filter { $0.key.threadID != id }
        turnScans[id] = nil
        revisions[id, default: 0] += 1
        stateChanged = true
        reducer.invalidateThread(id)
        if firstFailure {
            logStorage?.recordFailure(method: method, message: "Invalid payload for thread \(id)", connection: "activity")
        }
    }

    private func retryStorage() async {
        guard Date() >= storageRetryAfter else { return }
        do {
            try await persistPending()
            storageRetryAfter = .distantPast
            if isHistoryRecordingPaused, pendingEvents.isEmpty, pendingSamples.isEmpty, isRunning, !Task.isCancelled {
                isHistoryRecordingPaused = false
                reducer.setTokenUsageRecordingEnabled(isTokenUsageWriter)
            }
        } catch {
            recordStorageFailure(error)
        }
    }

    private func recordStorageFailure(_ error: Error) {
        if storageRetryAfter == .distantPast {
            logStorage?.recordFailure(method: "activity/storage", message: error.localizedDescription, connection: "activity")
        }
        storageRetryAfter = Date().addingTimeInterval(1)
    }

    private struct MethodEnvelope: Decodable { let method: String }
}
