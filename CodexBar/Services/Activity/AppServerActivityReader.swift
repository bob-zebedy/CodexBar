import Foundation

nonisolated enum ActivityEventBatch {
    case bootstrapStart
    case snapshotEvents([ActivityRecord])
    case bootstrapEnd
    case live([ActivityRecord])
    case sourceUnavailable
    case lifecycleChanged
}

nonisolated enum ActivityEventDrainResult: Sendable {
    case completed
    case sourceUnavailable
    case cancelled
}

/// actor 独占连接与解析状态, UI 仅消费归一化事件和有覆盖时限的生命周期快照
actor AppServerActivityReader {
    nonisolated static var defaultSocketURL: URL {
        CodexPaths.codexHomeDirectory().appendingPathComponent("app-server-control/app-server-control.sock")
    }

    private let lifecycleCache: SessionLifecycleCache
    private let onAccountChange: @MainActor @Sendable (AccountChange) -> Void
    private var pendingAccountChange: AccountChange?
    private let onBatch: @MainActor @Sendable (ActivityEventBatch) -> Void
    private let socketURL: URL
    private let logStorage: AppServerLogStore?
    private let tokenHistory: TokenHistoryStore
    private let recorder: ActivityRecorder
    private var session: AppServerSession?
    private var reducer = AppServerActivityReducer()
    private var subscribed = Set<String>()
    private var loop: Task<Void, Never>?
    private var storageTask: Task<Void, Never>?
    private var tokenRefreshTask: Task<[TokenTurn], Error>?
    private var generation = 0
    private var connectedAt = Date.distantFuture
    private var reconciledAt = Date.distantPast
    private var lastTokenRefresh = Date.distantPast
    private var isRunning = false
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var stateChanged = false
    private var lastPublished = Date.distantPast
    private var isTokenWriter = false
    private var writerRetryAfter = Date.distantPast
    private var drainWaiters: [CheckedContinuation<ActivityEventDrainResult, Never>] = []
    private var pendingEvents: [(event: ActivityRecord, bytes: Int)] = []
    private var pendingPublication: [ActivityRecord] = []
    private var pendingObservations: [(observation: TokenObservation, bytes: Int)] = []
    private var pendingStorageBytes = 0
    private var deferredNotifications: [ActivityInput] = []
    private var verifiedTurns: [ActivityTurnReference: Date] = [:]
    private var turnCursors: [String: String] = [:]

    private struct TurnReadResult {
        var turns: [ActivityTurn]
        var remaining: Set<String>
        var cursor: String?
    }

    private var checkedThreads: [String: Date] = [:]
    private var revisions: [String: Int] = [:]
    private var preparingThread: String?
    private var invalidThreads = Set<String>()
    private var storageRetryAfter = Date.distantPast
    private var storageFailed = false
    private var isHistoryRecordingPaused = false
    private var tokenRefreshFailed = false
    private var tokenRetryAfter = Date.distantPast
    private let maximumPendingEvents: Int
    private let maximumPendingBytes: Int
    private let maximumLoadedPages: Int
    private let reconciliationTimeout: TimeInterval

    init(
        lifecycleCache: SessionLifecycleCache,
        socketURL: URL = AppServerActivityReader.defaultSocketURL,
        logStorage: AppServerLogStore? = .shared,
        tokenHistory: TokenHistoryStore = TokenHistoryStore(),
        recorder: ActivityRecorder = ActivityRecorder(),
        maximumPendingEvents: Int = 4096,
        maximumPendingBytes: Int = 8 * 1024 * 1024,
        maximumLoadedPages: Int = 100,
        reconciliationTimeout: TimeInterval = 30,
        onAccountChange: @escaping @MainActor @Sendable (AccountChange) -> Void = { _ in },
        onBatch: @escaping @MainActor @Sendable (ActivityEventBatch) -> Void
    ) {
        self.lifecycleCache = lifecycleCache
        self.socketURL = socketURL
        self.logStorage = logStorage
        self.tokenHistory = tokenHistory
        self.recorder = recorder
        self.maximumPendingEvents = maximumPendingEvents
        self.maximumPendingBytes = maximumPendingBytes
        self.maximumLoadedPages = maximumLoadedPages
        self.reconciliationTimeout = reconciliationTimeout
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
        tokenRefreshTask?.cancel()
        let previous = loop
        previous?.cancel()
        loop = nil
        session?.close()
        session = nil
        subscribed.removeAll()
        await previous?.value
        pendingAccountChange = nil
        pendingPublication.removeAll()
        deferredNotifications.removeAll()
        verifiedTurns.removeAll()
        turnCursors.removeAll()
        checkedThreads.removeAll()
        invalidThreads.removeAll()
        if storageTask == nil, !pendingEvents.isEmpty || !pendingObservations.isEmpty {
            startStorageWorker()
        }
        // 退出只给已接收记录有限的排空时间, 慢文件操作不能卡住 App 退出
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while storageTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        saved = storageTask == nil && pendingEvents.isEmpty && pendingObservations.isEmpty
        storageTask?.cancel()
        completeDrains(.cancelled)
        await lifecycleCache.invalidate()
        return saved
    }

    /// 每次调用执行本次请求之后的查询, 不复用正在进行的旧快照
    func drainNow() async -> ActivityEventDrainResult {
        guard isRunning, !Task.isCancelled else { return .cancelled }
        guard session != nil else { return .sourceUnavailable }
        return await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func run(generation current: Int) async {
        while isRunning, generation == current, !Task.isCancelled {
            do {
                if session == nil {
                    try await connect(generation: current)
                }
                try await consumeAvailable(generation: current)
                if !drainWaiters.isEmpty || Date().timeIntervalSince(reconciledAt) >= 2 {
                    let waiters = drainWaiters
                    drainWaiters.removeAll()
                    do {
                        let covered = try await reconcile(bootstrap: false, forced: !waiters.isEmpty, generation: current)
                        try await consumeAvailable(generation: current)
                        let result: ActivityEventDrainResult = isRunning && generation == current && !Task
                            .isCancelled ? (covered ? .completed : .sourceUnavailable) : .cancelled
                        for waiter in waiters {
                            waiter.resume(returning: result)
                        }
                    } catch {
                        for waiter in waiters {
                            waiter.resume(returning: .sourceUnavailable)
                        }
                        throw error
                    }
                }
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
        reducer.reconnect()
        reducer.setTokenRecordingEnabled(isTokenWriter && !isHistoryRecordingPaused)
        try checkGeneration(current)
        await onBatch(.bootstrapStart)
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
        _ = try await reconcile(bootstrap: true, forced: true, generation: current)
        try checkGeneration(current)
        await onBatch(.bootstrapEnd)
    }

    private func acquireTokenWriter(generation current: Int) async throws {
        guard !isTokenWriter, Date() >= writerRetryAfter else { return }
        do {
            if try await tokenHistory.acquireRecordingLease() {
                try checkGeneration(current)
                isTokenWriter = true
                writerRetryAfter = .distantPast
                reducer.setTokenRecordingEnabled(!isHistoryRecordingPaused)
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
            waiter.resume(returning: result)
        }
    }

    private func disconnected() async {
        completeDrains(.sourceUnavailable)
        session?.close()
        session = nil
        subscribed.removeAll()
        deferredNotifications.removeAll()
        pendingAccountChange = nil
        verifiedTurns.removeAll()
        turnCursors.removeAll()
        invalidThreads.removeAll()
        checkedThreads.removeAll()
        await lifecycleCache.invalidate()
        await onBatch(.sourceUnavailable)
    }

    private func reconcile(bootstrap: Bool, forced: Bool, generation current: Int) async throws -> Bool {
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(reconciliationTimeout))
        return try await AppServerRequestBudget.$current.withValue(budget) {
            try await reconcileWithinBudget(bootstrap: bootstrap, forced: forced, generation: current)
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
        // 不发布截断列表, 否则未读取的线程会被错误地当作已经卸载
        throw CodexStatusError.invalidServerResponse
    }

    private func reconcileWithinBudget(bootstrap: Bool, forced: Bool, generation current: Int) async throws -> Bool {
        let loaded = try await loadThreads(generation: current)
        let knownActive = Set(reducer.states.keys.filter {
            reducer.states[$0]?.terminal == nil && reducer.threads[$0.threadID]?.status?.type != .notLoaded
        }.map(\.threadID))
        let now = Date()
        let dependencies = Set(reducer.missingRootTurns(liveOnly: forced).keys)
            .union(reducer.missingSubagentParents(liveOnly: forced))
        let required = loaded.union(knownActive).union(reducer.missingRootTurns(liveOnly: true).keys)
            .union(reducer.missingSubagentParents(liveOnly: true))
        let candidates = loaded.union(knownActive).union(dependencies).filter { id in
            let interval: TimeInterval = invalidThreads.contains(id) || knownActive.contains(id)
                || dependencies.contains(id) || reducer.threads[id]?.status?.type == .active ? 5 : 60
            return forced || now.timeIntervalSince(checkedThreads[id] ?? .distantPast) >= interval
        }.sorted {
            if required.contains($0) != required.contains($1) {
                return required.contains($0)
            }
            return (checkedThreads[$0] ?? .distantPast, $0) < (checkedThreads[$1] ?? .distantPast, $1)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        var covered = true
        for id in candidates {
            try checkGeneration(current)
            let verified = try await reconcileThread(id, loaded: loaded, bootstrap: bootstrap, forced: forced, generation: current)
            if loaded.contains(id) || knownActive.contains(id) {
                covered = covered && verified
            }
            // 日常核对分轮执行, 强制排空则等待本轮完整覆盖
            if !forced, ContinuousClock.now >= deadline {
                break
            }
        }
        reducer.maintain(loadedThreads: loaded, now: Date())
        subscribed.formIntersection(loaded)
        let retained = loaded.union(knownActive).union(dependencies)
        checkedThreads = checkedThreads.filter { retained.contains($0.key) }
        revisions = revisions.filter { retained.contains($0.key) }
        verifiedTurns = verifiedTurns.filter { reducer.states[$0.key] != nil && retained.contains($0.key.threadID) }
        turnCursors = turnCursors.filter { retained.contains($0.key) }
        invalidThreads.formIntersection(retained)
        reconciledAt = Date()
        await lifecycleCache.replace(reducer.states, verifiedTurns: verifiedTurns)
        try checkGeneration(current)
        if !bootstrap {
            await onBatch(.lifecycleChanged)
        }
        return covered && !reducer.states.values.contains {
            $0.terminal == nil && ($0.rootThreadID == nil || $0.rootTurnID == nil)
        }
    }

    private func reconcileThread(_ id: String, loaded: Set<String>, bootstrap: Bool, forced: Bool, generation current: Int) async throws -> Bool {
        let started = Date()
        let revision = revisions[id, default: 0]
        let newSubscription = !subscribed.contains(id)
        if newSubscription {
            preparingThread = id
        }
        defer { preparingThread = nil }
        var covered = false
        do {
            let read: ActivityThreadRead = try await request(ActivityRequests.thread(id), generation: current)
            var thread = read.thread
            if loaded.contains(id), newSubscription, thread.status?.type != .notLoaded {
                let joined: ActivityThreadResume = try await request(
                    ActivityRequests.subscribe(id), generation: current
                )
                thread = joined.thread
                subscribed.insert(id)
            }
            if newSubscription {
                reducer.threads[id] = thread
            }
            let includesItems = newSubscription || !reducer.missingSubagentContexts(in: id, liveOnly: forced).isEmpty
            let first: ActivityTurnsPage = try await request(
                ActivityRequests.turns(id, limit: 10, includesItems: includesItems), generation: current
            )
            if newSubscription, first.nextCursor == nil, first.data.count <= 1,
               first.data.allSatisfy({ $0.status == .running }),
               let created = thread.createdAt, created >= connectedAt {
                reducer.markNewThread(id)
            }
            let result = try await readRemainingTurns(id, first: first, includesItems: includesItems, forced: forced, generation: current)
            // 查询期间收到的新状态优先, 不用旧响应倒退实时状态或刷新其验证时间
            if revision == revisions[id, default: 0] {
                let events = reducer.reconcile(thread: thread, turns: result.turns, now: Date(), bootstrap: bootstrap || newSubscription)
                for turn in result.turns {
                    verifiedTurns[ActivityTurnReference(threadID: id, turnID: turn.id)] = started
                }
                for turnID in result.remaining {
                    let key = ActivityTurnReference(threadID: id, turnID: turnID)
                    verifiedTurns[key] = nil
                    reducer.states[key]?.readStatus = result.cursor == nil ? .notFound : .unavailable
                }
                let observations = reducer.takeTokenObservations()
                enqueueHistory(events: [], observations: observations)
                turnCursors[id] = result.cursor
                invalidThreads.remove(id)
                covered = result.remaining.isEmpty && thread.status?.type != .notLoaded
                if !events.isEmpty {
                    await onBatch(.snapshotEvents(events))
                }
            }
            preparingThread = nil
            consumeDeferred(for: id)
            if invalidThreads.contains(id) {
                reducer.invalidateThread(id)
            }
            try await flushPending(generation: current)
        } catch CodexStatusError.invalidResponsePayload {
            consumeDeferred(for: id)
            invalidateThread(id, method: "activity/thread", resetTokenBaseline: false)
        } catch let error as CodexStatusError where error.isMissingRollout(for: id)
            || (!error.isTransportFailure && !error.isProtocolOrParameterFailure) {
            reducer.invalidateThread(id)
            verifiedTurns = verifiedTurns.filter { $0.key.threadID != id }
            turnCursors[id] = nil
            subscribed.remove(id)
            consumeDeferred(for: id)
        } catch {
            consumeDeferred(for: id)
            throw error
        }
        checkedThreads[id] = started
        return covered
    }

    private func readRemainingTurns(
        _ id: String, first: ActivityTurnsPage, includesItems: Bool, forced: Bool, generation current: Int
    ) async throws -> TurnReadResult {
        var turns = first.data
        let activeTurns = reducer.states.keys.filter {
            $0.threadID == id && reducer.states[$0]?.terminal == nil
        }.map(\.turnID)
        var remaining = Set(activeTurns)
        remaining.formUnion(reducer.missingRootTurns(liveOnly: forced)[id] ?? [])
        remaining.subtract(first.data.map(\.id))
        var missingAgents = reducer.missingSubagentContexts(in: id, liveOnly: forced)
        func foundAgents(in turns: [ActivityTurn]) -> Set<String> {
            var agents = Set<String>()
            for turn in turns {
                for item in turn.items ?? [] where item.type == .subAgentActivity && item.kind == "started" {
                    if let agent = item.agentThreadId {
                        agents.insert(agent)
                    }
                }
            }
            return agents
        }
        missingAgents.subtract(foundAgents(in: first.data))
        var cursor = turnCursors[id] ?? first.nextCursor
        // 每轮重读最新页, 深页沿上次游标继续, 避免旧轮次一直被新轮次挤出查询窗口
        for _ in 0 ..< (forced ? 8 : 1) {
            guard !remaining.isEmpty || !missingAgents.isEmpty, let next = cursor else { break }
            let page: ActivityTurnsPage = try await request(
                ActivityRequests.turns(id, limit: 100, includesItems: includesItems, cursor: next), generation: current
            )
            guard page.nextCursor != next else { throw CodexStatusError.invalidServerResponse }
            turns += page.data
            remaining.subtract(page.data.map(\.id))
            missingAgents.subtract(foundAgents(in: page.data))
            cursor = page.nextCursor
        }
        return TurnReadResult(
            turns: turns, remaining: remaining.intersection(activeTurns),
            cursor: remaining.isEmpty && missingAgents.isEmpty ? nil : cursor
        )
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
            // 用量或轮次边界缺失时不能把跨轮次消耗归到下一条通知
            invalidateThread(
                threadID,
                method: method,
                resetTokenBaseline: [ActivityInput.Kind.usageUpdated, .turnStarted, .turnFinished].contains(AppServerActivityProtocol.kind(for: method))
            )
            return
        }
        let id = notification.params.threadId ?? notification.params.thread?.id
        if let id, preparingThread == id || (reducer.threads[id] == nil && notification.params.thread == nil) {
            guard deferredNotifications.count < 4096 else { throw CodexStatusError.invalidServerResponse }
            deferredNotifications.append(notification)
            return
        }
        consume(notification)
    }

    private func consume(_ notification: ActivityInput) {
        stateChanged = true
        if let id = notification.params.threadId ?? notification.params.thread?.id,
           notification.kind.category != .progress {
            revisions[id, default: 0] += 1
        }
        let events = reducer.consume(notification, now: Date())
        pendingPublication += events
        if let id = notification.params.threadId ?? notification.params.thread?.id, invalidThreads.contains(id) {
            reducer.invalidateThread(id)
        }
        let observations = reducer.takeTokenObservations()
        enqueueHistory(events: events, observations: observations)
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
                try await acquireTokenWriter(generation: current)
                _ = await retryStorage()
                try checkGeneration(current)
                await refreshTokenHistory(generation: current)
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        var failures = 0
        while !Task.isCancelled, failures < 3, !pendingEvents.isEmpty || !pendingObservations.isEmpty {
            do {
                try await persistPending()
            } catch {
                failures += 1
                recordStorageFailure(error)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await tokenHistory.releaseRecordingLease()
        isTokenWriter = false
        reducer.setTokenRecordingEnabled(false)
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
                try await recorder.record(event: pending.event)
                pendingEvents.removeFirst()
                pendingStorageBytes -= pending.bytes
            }
        } catch {
            failure = error
        }
        do {
            for pending in pendingObservations.prefix(64) {
                try Task.checkCancellation()
                try await tokenHistory.appendObservation(pending.observation)
                pendingObservations.removeFirst()
                pendingStorageBytes -= pending.bytes
            }
        } catch {
            failure = failure ?? error
        }
        if let failure {
            throw failure
        }
    }

    private func refreshTokenHistory(generation current: Int) async {
        guard isTokenWriter, pendingObservations.isEmpty, Date() >= tokenRetryAfter,
              Date().timeIntervalSince(lastTokenRefresh) >= 1 else { return }
        let refresh = Task { try await tokenHistory.refresh() }
        tokenRefreshTask = refresh
        defer { tokenRefreshTask = nil }
        do {
            let committed = try await refresh.value
            guard generation == current, isRunning, !Task.isCancelled else { return }
            // 此循环刷新期间不写队列, 新观测全部在队列中, 按检查点重放后再发布
            try reducer.acceptTokenTurns(committed, replaying: pendingObservations.map(\.observation))
            stateChanged = true
            tokenRefreshFailed = false
            tokenRetryAfter = .distantPast
            lastTokenRefresh = Date()
        } catch is CancellationError {
            return
        } catch {
            guard generation == current, isRunning else { return }
            if !tokenRefreshFailed {
                logStorage?.recordFailure(method: "activity/storage", message: error.localizedDescription, connection: "activity")
            }
            tokenRefreshFailed = true
            tokenRetryAfter = Date().addingTimeInterval(1)
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
        await lifecycleCache.replace(reducer.states, verifiedTurns: verifiedTurns)
        try checkGeneration(current)
        stateChanged = false
        lastPublished = Date()
        let events = pendingPublication
        pendingPublication.removeAll()
        if !events.isEmpty {
            await onBatch(.live(events))
        }
        await onBatch(.lifecycleChanged)
    }

    private func enqueueHistory(events: [ActivityRecord], observations: [TokenObservation]) {
        do {
            for event in events {
                guard !isHistoryRecordingPaused else { return }
                let bytes = try AppServerEventRecord(activity: event).jsonLineData().count
                pendingEvents.append((event, bytes))
                pendingStorageBytes += bytes
                enforceStorageLimit()
            }
            for observation in observations where isTokenWriter {
                guard !isHistoryRecordingPaused else { return }
                let bytes = try JSONLines.stableEncoder.encode(observation).count
                pendingObservations.append((observation, bytes))
                pendingStorageBytes += bytes
                enforceStorageLimit()
            }
        } catch {
            recordStorageFailure(error)
            pauseHistoryRecording()
        }
    }

    private func enforceStorageLimit() {
        if pendingEvents.count + pendingObservations.count >= maximumPendingEvents || pendingStorageBytes >= maximumPendingBytes {
            pauseHistoryRecording()
        }
    }

    private func pauseHistoryRecording() {
        isHistoryRecordingPaused = true
        reducer.setTokenRecordingEnabled(false)
    }

    private func invalidateThread(_ id: String, method: String, resetTokenBaseline: Bool) {
        let firstFailure = invalidThreads.insert(id).inserted
        verifiedTurns = verifiedTurns.filter { $0.key.threadID != id }
        turnCursors[id] = nil
        revisions[id, default: 0] += 1
        stateChanged = true
        reducer.invalidateThread(id)
        if resetTokenBaseline {
            reducer.invalidateTokenBaseline(id)
        }
        if firstFailure {
            logStorage?.recordFailure(method: method, message: "Invalid payload for thread \(id)", connection: "activity")
        }
    }

    private func retryStorage() async -> Bool {
        guard Date() >= storageRetryAfter else { return false }
        do {
            try await persistPending()
            storageFailed = false
            storageRetryAfter = .distantPast
            if isHistoryRecordingPaused, pendingEvents.isEmpty, pendingObservations.isEmpty, isRunning, !Task.isCancelled {
                isHistoryRecordingPaused = false
                reducer.setTokenRecordingEnabled(isTokenWriter)
            }
            return true
        } catch {
            recordStorageFailure(error)
            return false
        }
    }

    private func recordStorageFailure(_ error: Error) {
        if !storageFailed {
            logStorage?.recordFailure(method: "activity/storage", message: error.localizedDescription, connection: "activity")
        }
        storageFailed = true
        storageRetryAfter = Date().addingTimeInterval(1)
    }

    private struct MethodEnvelope: Decodable { let method: String }
}
