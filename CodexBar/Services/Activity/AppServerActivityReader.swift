import Foundation
import os

nonisolated enum ActivityEventBatch {
    case bootstrapStart
    case bootstrapEvents([ActivityRecord])
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
    private let onBatch: @MainActor @Sendable (ActivityEventBatch) -> Void
    private let socketURL: URL
    private let tokenHistory: TokenHistoryStore
    private let recorder: ActivityRecorder
    private var session: AppServerSession?
    private var reducer = AppServerActivityReducer()
    private var subscribed = Set<String>()
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var connectedAt = Date.distantFuture
    private var reconciledAt = Date.distantPast
    private var persistedTokens: [TokenTurn] = []
    private var lastTokenRefresh = Date.distantPast
    private var isRunning = false
    private var isStopping = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var stateChanged = false
    private var lastPublished = Date.distantPast
    private var isTokenWriter = false
    private var drainWaiters: [CheckedContinuation<ActivityEventDrainResult, Never>] = []
    private var pendingEvents: [ActivityRecord] = []
    private var pendingPublication: [ActivityRecord] = []
    private var pendingObservations: [TokenObservation] = []
    private var deferredNotifications: [ActivityNotification] = []
    private var verifiedThreads: [String: Date] = [:]
    private var checkedThreads: [String: Date] = [:]
    private var revisions: [String: Int] = [:]
    private var preparingThread: String?
    private var invalidThreads = Set<String>()
    private var storageRetryAfter = Date.distantPast
    private var storageFailed = false
    private var storagePaused = false
    private let maximumPendingEvents: Int
    private let maximumPendingBytes: Int

    init(
        lifecycleCache: SessionLifecycleCache,
        socketURL: URL = AppServerActivityReader.defaultSocketURL,
        tokenHistory: TokenHistoryStore = TokenHistoryStore(),
        recorder: ActivityRecorder = ActivityRecorder(),
        maximumPendingEvents: Int = 4096,
        maximumPendingBytes: Int = 8 * 1024 * 1024,
        onBatch: @escaping @MainActor @Sendable (ActivityEventBatch) -> Void
    ) {
        self.lifecycleCache = lifecycleCache
        self.socketURL = socketURL
        self.tokenHistory = tokenHistory
        self.recorder = recorder
        self.maximumPendingEvents = maximumPendingEvents
        self.maximumPendingBytes = maximumPendingBytes
        self.onBatch = onBatch
    }

    func start() {
        guard !isRunning, !isStopping else { return }
        isRunning = true
        generation += 1
        let current = generation
        loop = Task { [weak self] in await self?.run(generation: current) }
    }

    func stop() async {
        if isStopping {
            await withCheckedContinuation { stopWaiters.append($0) }
            return
        }
        isStopping = true
        defer {
            isStopping = false
            let waiters = stopWaiters
            stopWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        isRunning = false
        generation += 1
        let previous = loop
        previous?.cancel()
        loop = nil
        session?.close()
        session = nil
        subscribed.removeAll()
        await previous?.value
        try? await persistPending()
        completeDrains(.cancelled)
        isTokenWriter = false
        await tokenHistory.releaseRecordingLease()
        await lifecycleCache.invalidate()
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
                if storagePaused {
                    guard await retryStorage() else {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    storagePaused = false
                }
                if session == nil {
                    try await connect(generation: current)
                }
                try await acquireTokenWriter(generation: current)
                try await consumeAvailable(generation: current)
                if !drainWaiters.isEmpty || Date().timeIntervalSince(reconciledAt) >= 2 {
                    let waiters = drainWaiters
                    drainWaiters.removeAll()
                    do {
                        try await reconcile(bootstrap: false, forced: !waiters.isEmpty, generation: current)
                        try await consumeAvailable(generation: current)
                        let result: ActivityEventDrainResult = isRunning && generation == current && !Task.isCancelled ? .completed : .cancelled
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
        // 存储未准备好时不创建连接, 避免本地故障触发重复初始化
        isTokenWriter = try await tokenHistory.acquireRecordingLease()
        try await persistPending()
        persistedTokens = try await tokenHistory.refresh()
        try checkGeneration(current)
        await onBatch(.bootstrapStart)
        try checkGeneration(current)
        let connection = try AppServerSession(socketURL: socketURL)
        do {
            try connection.initialize()
        } catch {
            connection.close()
            throw error
        }
        session = connection
        connectedAt = Date()
        reducer.reconnect()
        reducer.restoreTokenTurns(persistedTokens)
        try await reconcile(bootstrap: true, forced: true, generation: current)
        try checkGeneration(current)
        await onBatch(.bootstrapEnd)
    }

    private func acquireTokenWriter(generation current: Int) async throws {
        guard !isTokenWriter, Date() >= storageRetryAfter else { return }
        do {
            if try await tokenHistory.acquireRecordingLease() {
                try await persistPending()
                persistedTokens = try await tokenHistory.refresh()
                try checkGeneration(current)
                reducer.restoreTokenTurns(persistedTokens)
                isTokenWriter = true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordStorageFailure(error)
        }
    }

    private func recover(from error: Error, generation current: Int) async {
        guard generation == current, isRunning else { return }
        let method = error is StorageBacklogFull || session == nil && !(error is CodexStatusError) ? "activity/storage" : "activity/connection"
        AppServerLogStore.shared.recordFailure(method: method, message: error.localizedDescription, connection: "activity")
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
        verifiedThreads.removeAll()
        invalidThreads.removeAll()
        checkedThreads.removeAll()
        isTokenWriter = false
        await tokenHistory.releaseRecordingLease()
        await lifecycleCache.invalidate()
        await onBatch(.sourceUnavailable)
    }

    private func reconcile(bootstrap: Bool, forced: Bool, generation current: Int) async throws {
        var loaded = Set<String>()
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor {
                params["cursor"] = cursor
            }
            let page: ActivityLoadedPage = try await request("thread/loaded/list", params: params, generation: current)
            loaded.formUnion(page.data)
            cursor = page.nextCursor
        } while cursor != nil && loaded.count < 10000
        let knownActive = Set(reducer.states.keys.filter {
            reducer.states[$0]?.terminal == nil && reducer.threads[$0.threadID]?.status?.type != "notLoaded"
        }.map(\.threadID))
        let now = Date()
        let candidates = loaded.union(knownActive).filter { id in
            let interval: TimeInterval = invalidThreads.contains(id) || knownActive.contains(id) || reducer.threads[id]?.status?.type == "active" ? 5 : 60
            return forced || now.timeIntervalSince(checkedThreads[id] ?? .distantPast) >= interval
        }.sorted { (checkedThreads[$0] ?? .distantPast, $0) < (checkedThreads[$1] ?? .distantPast, $1) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        for id in candidates {
            try checkGeneration(current)
            try await reconcileThread(id, loaded: loaded, bootstrap: bootstrap, generation: current)
            // 日常核对分轮执行, 强制排空则等待本轮完整覆盖
            if !forced, ContinuousClock.now >= deadline {
                break
            }
        }
        subscribed.formIntersection(loaded)
        let retained = loaded.union(knownActive)
        checkedThreads = checkedThreads.filter { retained.contains($0.key) }
        revisions = revisions.filter { retained.contains($0.key) }
        verifiedThreads = verifiedThreads.filter { retained.contains($0.key) }
        invalidThreads.formIntersection(retained)
        reconciledAt = Date()
        await lifecycleCache.replace(reducer.states, verifiedThreads: verifiedThreads)
        try checkGeneration(current)
        if !bootstrap {
            await onBatch(.lifecycleChanged)
        }
    }

    private func reconcileThread(_ id: String, loaded: Set<String>, bootstrap: Bool, generation current: Int) async throws {
        let started = Date()
        let revision = revisions[id, default: 0]
        let newSubscription = !subscribed.contains(id)
        if newSubscription {
            preparingThread = id
        }
        defer { preparingThread = nil }
        do {
            let read: ActivityThreadRead = try await request("thread/read", params: ["threadId": id, "includeTurns": false], generation: current)
            var thread = read.thread
            var reviewer: ApprovalReviewer?
            if loaded.contains(id), newSubscription, thread.status?.type != "notLoaded" {
                let joined: ActivityThreadResume = try await request(
                    "thread/resume", params: ["threadId": id, "excludeTurns": true], generation: current
                )
                thread = joined.thread
                thread.model = joined.model ?? thread.model
                thread.reasoningEffort = joined.reasoningEffort ?? thread.reasoningEffort
                reviewer = joined.approvalsReviewer?.value
                subscribed.insert(id)
            }
            if newSubscription {
                reducer.threads[id] = thread
            }
            let turns: ActivityTurnsPage = try await request(
                "thread/turns/list", params: ["threadId": id, "limit": 10, "itemsView": "summary"], generation: current
            )
            if newSubscription, turns.data.count <= 1, turns.data.allSatisfy({ $0.status == "inProgress" }),
               let created = thread.createdAt, created >= connectedAt.timeIntervalSince1970 {
                reducer.markNewThread(id)
            }
            // 查询期间收到的新状态优先, 不用旧响应倒退实时状态
            if revision == revisions[id, default: 0] {
                let events = reducer.reconcile(thread: thread, turns: turns.data, reviewer: reviewer, now: Date(), bootstrap: bootstrap || newSubscription)
                if !events.isEmpty {
                    await onBatch(.bootstrapEvents(events))
                }
            }
            if !invalidThreads.contains(id) || revision == revisions[id, default: 0] {
                invalidThreads.remove(id)
                verifiedThreads[id] = started
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
            verifiedThreads[id] = nil
            subscribed.remove(id)
            consumeDeferred(for: id)
        } catch {
            consumeDeferred(for: id)
            throw error
        }
        checkedThreads[id] = started
    }

    private func consumeDeferred(for id: String) {
        guard reducer.threads[id] != nil else { return }
        let pending = deferredNotifications.filter { ($0.params.threadId ?? $0.params.thread?.id) == id }
        deferredNotifications.removeAll { ($0.params.threadId ?? $0.params.thread?.id) == id }
        for notification in pending {
            consume(notification)
        }
    }

    private func request<Response: Decodable>(_ method: String, params: [String: Any], generation current: Int) async throws -> Response {
        try checkGeneration(current)
        guard let connection = session else { throw CodexStatusError.serverConnectionClosed }
        let pending = try connection.beginRequest(method, params: params)
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
        try Task.checkCancellation()
        guard generation == current, isRunning else { throw CancellationError() }
    }

    private func consume(_ data: Data) throws {
        let method = try JSONDecoder().decode(MethodEnvelope.self, from: data).method
        guard ActivityNotification.category(for: method) != .ignored else { return }
        let notification: ActivityNotification
        do {
            notification = try JSONDecoder().decode(ActivityNotification.self, from: data)
        } catch is DecodingError {
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let params = envelope["params"] as? [String: Any],
                  let threadID = params["threadId"] as? String ?? (params["thread"] as? [String: Any])?["id"] as? String,
                  !threadID.isEmpty else { throw CodexStatusError.invalidServerResponse }
            // 用量或轮次边界缺失时不能把跨轮次消耗归到下一条通知
            invalidateThread(threadID, method: method, resetTokenBaseline: ["thread/tokenUsage/updated", "turn/started", "turn/completed"].contains(method))
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

    private func consume(_ notification: ActivityNotification) {
        stateChanged = true
        if let id = notification.params.threadId ?? notification.params.thread?.id,
           ActivityNotification.category(for: notification.method) == .state {
            revisions[id, default: 0] += 1
        }
        let events = reducer.consume(notification, now: Date())
        pendingEvents += events
        pendingPublication += events
        if let id = notification.params.threadId ?? notification.params.thread?.id, invalidThreads.contains(id) {
            reducer.invalidateThread(id)
        }
        let observations = reducer.takeTokenObservations()
        if isTokenWriter {
            pendingObservations += observations
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

    private func persistPending() async throws {
        while let event = pendingEvents.first {
            try await recorder.record(event: event)
            pendingEvents.removeFirst()
        }
        if isTokenWriter, !pendingObservations.isEmpty || Date().timeIntervalSince(lastTokenRefresh) >= 1 {
            let batch = pendingObservations
            let committed = try await tokenHistory.recordObservations(batch)
            pendingObservations.removeFirst(batch.count)
            persistedTokens = committed
            reducer.acceptTokenTurns(committed)
            lastTokenRefresh = Date()
        }
    }

    private func flushPending(generation current: Int, force: Bool = true) async throws {
        try checkGeneration(current)
        guard stateChanged || !pendingEvents.isEmpty || !pendingObservations.isEmpty || !pendingPublication.isEmpty else { return }
        if !force, pendingEvents.isEmpty, pendingObservations.isEmpty, Date().timeIntervalSince(lastPublished) < 0.1 {
            return
        }
        _ = await retryStorage()
        try checkGeneration(current)
        await lifecycleCache.replace(reducer.states, verifiedThreads: verifiedThreads)
        try checkGeneration(current)
        stateChanged = false
        lastPublished = Date()
        let events = pendingPublication
        pendingPublication.removeAll()
        let visible = events.filter { event in
            guard [.subagentStarted, .subagentEnded].contains(event.eventKind),
                  let agent = event.agentID, let turn = event.turnID else { return true }
            return reducer.states[ActivityTurnReference(threadID: agent, turnID: turn, startedAt: event.timestamp)] != nil
        }
        if !visible.isEmpty {
            await onBatch(.live(visible))
        }
        await onBatch(.lifecycleChanged)
        if storageFailed, try pendingStorageExceedsLimit() {
            storagePaused = true
            throw StorageBacklogFull()
        }
    }

    private func invalidateThread(_ id: String, method: String, resetTokenBaseline: Bool) {
        let firstFailure = invalidThreads.insert(id).inserted
        verifiedThreads[id] = nil
        revisions[id, default: 0] += 1
        stateChanged = true
        reducer.invalidateThread(id)
        if resetTokenBaseline {
            reducer.invalidateTokenBaseline(id)
        }
        if firstFailure {
            AppServerLogStore.shared.recordFailure(method: method, message: "Invalid payload for thread \(id)", connection: "activity")
        }
    }

    private func retryStorage() async -> Bool {
        guard Date() >= storageRetryAfter else { return false }
        do {
            try await persistPending()
            storageFailed = false
            storageRetryAfter = .distantPast
            return true
        } catch {
            recordStorageFailure(error)
            return false
        }
    }

    private func recordStorageFailure(_ error: Error) {
        if !storageFailed {
            AppServerLogStore.shared.recordFailure(method: "activity/storage", message: error.localizedDescription, connection: "activity")
        }
        storageFailed = true
        storageRetryAfter = Date().addingTimeInterval(1)
    }

    private func pendingStorageExceedsLimit() throws -> Bool {
        if pendingEvents.count + pendingObservations.count >= maximumPendingEvents {
            return true
        }
        var bytes = 0
        for event in pendingEvents {
            bytes += try AppServerEventRecord(activity: event).jsonLineData().count
            if bytes >= maximumPendingBytes {
                return true
            }
        }
        bytes += try JSONLines.stableEncoder.encode(pendingObservations).count
        return bytes >= maximumPendingBytes
    }

    private struct StorageBacklogFull: LocalizedError {
        var errorDescription: String? {
            "Activity persistence buffer is full; collection is paused until pending data is saved"
        }
    }

    private struct MethodEnvelope: Decodable { let method: String }
}
