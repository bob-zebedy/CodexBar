import Foundation
import os

actor BridgeRuntime {
    typealias Connector = @Sendable () throws -> any BridgeUpstream
    let directory: URL
    let connect: Connector
    private var database: BridgeStore?
    var store: BridgeStore {
        get throws {
            guard let database else { throw BridgeFailure("bridge_unavailable") }
            return database
        }
    }

    static let enabledKey = "Bridge.isEnabled"
    private let defaults: UserDefaults
    private let enabled: OSAllocatedUnfairLock<Bool>
    nonisolated var isEnabled: Bool {
        enabled.withLock { $0 }
    }

    private var pendingToolUses: [UUID: (amount: Int64, waitingForLock: Bool)] = [:]
    private var usageRetryScheduled = false
    private var configurationObservers: [UUID: AsyncStream<[BridgeConfiguration]>.Continuation] = [:]
    private(set) var configurations: [BridgeConfiguration] = [] {
        didSet {
            for observer in configurationObservers.values {
                observer.yield(configurations)
            }
        }
    }

    var activeTasks: [String: BridgeTaskRecord] = [:]
    var connection: (any BridgeUpstream)?
    var pump: Task<Void, Never>?
    private var deferredEvent: BridgeJSON?
    enum ThreadSubscription: Equatable {
        case verified(BridgePermissions), unverified, retiring(turn: String)

        var isTrackingTask: Bool {
            switch self {
            case .verified, .unverified: true
            case .retiring: false
            }
        }

        func permits(_ request: BridgeRPCRequest) -> Bool {
            guard isTrackingTask, request.form != nil else { return false }
            guard request.method.isApproval else { return true }
            guard case let .verified(applied) = self else { return false }
            return applied == request.permissions || request.isPermitted(by: applied)
        }
    }

    var subscriptions: [String: ThreadSubscription] = [:]
    var buffers: [String: BridgeTurnEvents] = [:]
    var requests = BridgePendingRequests()
    var lastConnectionAttempt = Date.distantPast
    var retrySeconds: Double = 1
    struct Waiter {
        let task: String
        let turn: String
        let continuation: CheckedContinuation<Void, Never>
    }

    var waiters: [UUID: Waiter] = [:]
    var lastPruned = Date.distantPast
    private var pruneRetryAfter = Date.distantPast
    var recoveryAfter: [String: Date] = [:]

    init(directory: URL = BridgeStore.directory, defaults: UserDefaults = .standard, connect: @escaping Connector = { try BridgeControlConnection(socket: CodexPaths.appServerSocket()) }) {
        self.directory = directory
        self.defaults = defaults
        enabled = OSAllocatedUnfairLock(initialState: defaults.bool(forKey: Self.enabledKey))
        self.connect = connect
    }

    func load() throws {
        // 服务关闭时也要恢复已有线程的日志保护
        if isEnabled || FileManager.default.fileExists(atPath: BridgeStore.databaseURL(in: directory).path) {
            try openStore()
        } else {
            BridgeLogPrivacy.shared.finishRestoration()
        }
    }

    func configurationUpdates() throws -> AsyncStream<[BridgeConfiguration]> {
        try load()
        let id = UUID()
        let (stream, continuation) = AsyncStream<[BridgeConfiguration]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        configurationObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeConfigurationObserver(id) }
        }
        continuation.yield(configurations)
        return stream
    }

    private func removeConfigurationObserver(_ id: UUID) {
        configurationObservers[id] = nil
    }

    private func openStore() throws {
        guard database == nil else { return }
        let db = try BridgeStore(directory: directory)
        try db.prune(now: Date())
        try db.forEachTaskID(BridgeLogPrivacy.shared.register)
        let restored = try db.activeTasks()
        configurations = try db.configurations()
        activeTasks = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        lastPruned = Date()
        database = db
        BridgeLogPrivacy.shared.finishRestoration()
    }

    func pruneIfNeeded() throws {
        let now = Date()
        guard now.timeIntervalSince(lastPruned) >= 86400, now >= pruneRetryAfter else { return }
        do {
            let removed = try store.prune(now: now)
            lastPruned = now
            releaseTasks(removed)
        } catch let failure as BridgeSQLite.Failure where failure.isBusy {
            pruneRetryAfter = now.addingTimeInterval(5)
        }
    }

    func taskRecord(for id: String) throws -> BridgeTaskRecord? {
        try activeTasks[id] ?? store.task(id)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try openStore()
        }
        defaults.set(enabled, forKey: Self.enabledKey)
        self.enabled.withLock { $0 = enabled }
        if !enabled {
            shutdown()
        }
    }

    func shutdown() {
        flushPendingToolUses()
        pump?.cancel()
        pump = nil
        buffers.removeAll()
        disconnect()
    }

    func disconnect() {
        connection?.close()
        connection = nil
        deferredEvent = nil
        subscriptions.removeAll()
        requests.disconnect()
        for turn in buffers.keys {
            buffers[turn]?.needsHistory = true
            buffers[turn]?.historyScan = nil
            buffers[turn]?.historyUnavailable = false
            buffers[turn]?.terminalHistoryRead = false
        }
        for id in Array(waiters.keys) {
            wake(id)
        }
        recoveryAfter.removeAll()
    }

    private func makeConfiguration(id configurationID: UUID, name: String, permissions: BridgePermissions) throws -> BridgeConfiguration {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= BridgeConfiguration.maximumNameLength, permissions.isValid else { throw BridgeFailure("invalid_configuration") }
        return BridgeConfiguration(id: configurationID, name: name, permissions: permissions)
    }

    func createConfiguration(name: String, permissions: BridgePermissions = .init()) throws -> BridgeConfiguration {
        let configuration = try makeConfiguration(id: UUID(), name: name, permissions: permissions)
        try openStore()
        guard configurations.count < 64 else { throw BridgeFailure("invalid_configuration") }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        let secret = String((0 ..< 22).map { _ in alphabet[Int.random(in: alphabet.indices)] })
        try store.addConfiguration(configuration, token: secret)
        configurations.append(configuration)
        return configuration
    }

    func updateConfiguration(_ configurationID: UUID, name: String, permissions: BridgePermissions) throws {
        var updated = try makeConfiguration(id: configurationID, name: name, permissions: permissions)
        try openStore()
        guard let index = configurations.firstIndex(where: { $0.id == configurationID }) else { throw BridgeFailure("invalid_configuration") }
        let previous = configurations[index]
        updated.usageCount = previous.usageCount
        try store.updateConfiguration(updated)
        configurations[index] = updated
        guard previous.permissions != permissions else { return }
        let tasks = Set(activeTasks.values.filter { $0.configurationID == configurationID }.map(\.id))
        for request in requests.disallowedApprovals(in: tasks, permissions: permissions) {
            try? resolve(request, response: ["action": "decline"])
        }
    }

    func exportMCPConfiguration(for configurationID: UUID, format: BridgeMCPExportFormat, executable: URL? = Bundle.main.executableURL) throws -> String {
        guard let executable else { throw BridgeFailure("missing_executable") }
        let token = try store.token(for: configurationID)
        return try format.render(command: executable.path, token: token)
    }

    func deleteConfiguration(_ configurationID: UUID) throws {
        let removedTaskIDs = try store.deleteConfiguration(configurationID)
        pendingToolUses[configurationID] = nil
        configurations.removeAll { $0.id == configurationID }
        releaseTasks(removedTaskIDs)
    }

    private func releaseTasks(_ removedTaskIDs: Set<String>) {
        guard !removedTaskIDs.isEmpty else { return }
        var finished: [String] = []
        for task in removedTaskIDs {
            let turn = activeTasks.removeValue(forKey: task)?.latestTurnID
            recoveryAfter[task] = nil
            guard subscriptions[task]?.isTrackingTask == true else { continue }
            if let turn {
                // 最后一个订阅者立即离开会让运行中的 Codex 等不到后续审批的答复
                subscriptions[task] = .retiring(turn: turn)
            } else {
                subscriptions[task] = nil
                finished.append(task)
            }
        }
        for (key, waiter) in waiters where removedTaskIDs.contains(waiter.task) {
            wake(key)
        }
        for request in requests.removeRequests(for: removedTaskIDs) {
            if case let .rpc(rpc) = request.source {
                try? sendRPCResponse(rpc.method.declinedResult, to: rpc)
            }
        }
        for task in finished {
            guard connection != nil else { break }
            _ = try? call("thread/unsubscribe", ["threadId": .string(task)])
        }
        buffers = buffers.filter { !removedTaskIDs.contains($0.value.task) }
    }

    nonisolated func configurationID(forToken token: String) throws -> UUID {
        guard isEnabled, let configurationID = try BridgeStore.configurationID(forToken: token, in: directory) else { throw BridgeFailure("unauthorized") }
        return configurationID
    }

    func requireConfiguration(_ configurationID: UUID) throws -> BridgeConfiguration {
        guard isEnabled, let configuration = configurations.first(where: { $0.id == configurationID }) else { throw BridgeFailure("unauthorized") }
        return configuration
    }

    func recordToolUse(for configurationID: UUID, amount increment: Int64 = 1) throws {
        guard isEnabled, let index = configurations.firstIndex(where: { $0.id == configurationID }) else { throw BridgeFailure("unauthorized") }
        let amount = (pendingToolUses[configurationID]?.amount ?? 0) + increment
        if try !persistToolUses(amount, at: index) {
            configurations[index].usageCount = min(configurations[index].usageCount, .max - increment) + increment
        }
    }

    private func persistToolUses(_ amount: Int64, at index: Int) throws -> Bool {
        let configurationID = configurations[index].id
        defer {
            if pendingToolUses[configurationID]?.waitingForLock == true {
                scheduleUsageRetry()
            }
        }
        let count: Int64?
        do {
            count = try store.addToolUses(amount, for: configurationID)
        } catch {
            // 只有写锁冲突才定时重试, 其他错误等下次调用工具或关闭 Bridge 时再补写已计入的次数
            pendingToolUses[configurationID]?.waitingForLock = (error as? BridgeSQLite.Failure)?.isBusy == true
            throw error
        }
        guard let count else {
            pendingToolUses[configurationID] = (amount, true)
            return false
        }
        pendingToolUses[configurationID] = nil
        if count != configurations[index].usageCount {
            configurations[index].usageCount = count
        }
        return true
    }

    private func scheduleUsageRetry() {
        guard !usageRetryScheduled else { return }
        usageRetryScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.retryPendingToolUses()
        }
    }

    private func retryPendingToolUses() {
        usageRetryScheduled = false
        flushPendingToolUses(onlyWaitingForLock: true)
    }

    private func flushPendingToolUses(onlyWaitingForLock: Bool = false) {
        for (configurationID, pending) in pendingToolUses where !onlyWaitingForLock || pending.waitingForLock {
            guard let index = configurations.firstIndex(where: { $0.id == configurationID }) else { continue }
            do {
                _ = try persistToolUses(pending.amount, at: index)
            } catch let failure as BridgeFailure where failure.code == "unauthorized" {
                pendingToolUses[configurationID] = nil
            } catch { continue }
        }
    }

    func requireTask(_ id: String, configurationID: UUID) throws -> BridgeTaskRecord {
        _ = try requireConfiguration(configurationID)
        guard let record = try taskRecord(for: id), record.configurationID == configurationID else { throw BridgeFailure("task_not_found") }
        return record
    }

    func activate() {
        guard isEnabled, pump == nil else { return }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await self?.tick() ?? 1.0
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    func open() throws {
        guard connection == nil else { return }
        guard Date().timeIntervalSince(lastConnectionAttempt) >= retrySeconds else { throw BridgeFailure("bridge_reconnecting") }
        lastConnectionAttempt = Date()
        do {
            connection = try connect()
            retrySeconds = 1
        } catch { retrySeconds = min(60, retrySeconds * 2)
            throw error
        }
    }

    func tick() -> Double {
        guard isEnabled else { return 1 }
        do {
            try pruneIfNeeded()
            if connection == nil, activeTasks.isEmpty {
                return 1
            }
            try open()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(15))
            for _ in 0 ..< 64 {
                guard let event = try deferredEvent ?? connection?.next() else { break }
                do {
                    try receive(event)
                    deferredEvent = nil
                } catch let failure as BridgeSQLite.Failure where failure.isBusy {
                    // 按原顺序补写当前事件, 本地写锁期间保留其他客户端的审批
                    deferredEvent = event
                    return 0.25
                }
                if ContinuousClock.now >= deadline {
                    break
                }
            }
            for (turn, buffer) in buffers where buffer.delta.map({ Date().timeIntervalSince($0.since) >= 0.2 }) == true {
                flushDelta(turn)
            }
            if let record = activeTasks.values.first(where: { candidate in
                subscriptions[candidate.id] == nil
                    && (recoveryAfter[candidate.id] ?? .distantPast) <= Date()
            }) {
                recoveryAfter[record.id] = Date().addingTimeInterval(30)
                try restoreForObservation(record)
            }
        } catch {
            if !(error is BridgeFailure) {
                disconnect()
            }
            return min(retrySeconds, 5)
        }
        let hasActiveWork = !waiters.isEmpty || activeTasks.values.contains { $0.status == .running } || requests.needsFastPolling(activeTasks: activeTasks)
        return hasActiveWork ? 0.005 : 0.25
    }

    func call(_ method: String, _ params: BridgeJSON) throws -> BridgeJSON {
        try Task.checkCancellation()
        try open()
        return try exchange(method, params)
    }

    func exchange(_ method: String, _ params: BridgeJSON) throws -> BridgeJSON {
        do {
            return try AppServerRequestBudget.$finishesCurrentExchange.withValue(true) {
                try connection!.call(method, params)
            }
        } catch let AppServerError.serverError(error) {
            if error.code == -32601 {
                throw BridgeFailure("unsupported_capability", method)
            }
            throw BridgeFailure("codex_rejected", String(error.message.prefix(512)))
        } catch {
            disconnect()
            throw error
        }
    }

    func execute(_ command: BridgeCommand, configurationID: UUID, presentForm: (@Sendable (BridgeJSON) async throws -> BridgeJSON)? = nil) async throws -> BridgeJSON {
        try Task.checkCancellation()
        let configuration = try requireConfiguration(configurationID)
        switch command {
        case let .submit(submission): return try submit(submission, configuration: configuration)
        case let .wait(task, turn, after, seconds): return try await wait(task: task, turn: turn, after: after, seconds: seconds, configurationID: configurationID, supportsForms: presentForm != nil)
        case let .list(project, status, cursor): return try list(project: project, status: status, cursor: cursor, configurationID: configurationID)
        case let .respond(task, id, options):
            return try await respond(task: task, id: id, configurationID: configurationID, approvalOptions: options, presentForm: presentForm)
        case let .interrupt(taskID, turn):
            let record = try requireTask(taskID, configurationID: configurationID)
            let status = try turnDetails(for: turn, in: record).status
            if status.isTerminal {
                return ["status": .string(status.rawValue)]
            }
            try attach(record)
            do {
                _ = try call("turn/interrupt", ["threadId": .string(record.id), "turnId": .string(turn)])
            } catch {
                try refreshLatestTurnStatus(for: record.id)
                let terminal = try turnDetails(for: turn, in: requireTask(record.id, configurationID: configurationID)).status
                if terminal.isTerminal {
                    return ["status": .string(terminal.rawValue)]
                }
                throw error
            }
            return ["status": "interrupt_requested", "turnId": .string(turn)]
        }
    }

    private func list(project path: String?, status: String?, cursor encoded: String?, configurationID: UUID) throws -> BridgeJSON {
        let project = try path.map(resolveProject)
        let cursor = try encoded.map(BridgeListCursor.decode)
        if let cursor, cursor.configurationID != configurationID || cursor.project != project || cursor.status != status {
            throw BridgeFailure("invalid_cursor")
        }
        let blocking = requests.blockingTurns
        let matching = try store.list(configurationID: configurationID, project: project, status: status, after: cursor, blocking: blocking)
        let page = matching.prefix(40)
        let items: [BridgeJSON] = page.map { record in
            let waiting = record.latestTurnID.map { blocking.contains(BridgeTurnKey(task: record.id, turn: $0)) } == true
            return [
                "taskId": .string(record.id),
                "project": .string(record.project),
                "title": .string(record.title),
                "turnId": record.latestTurnID.map(BridgeJSON.string) ?? .null,
                "status": .string(waiting ? BridgeTurnStatus.waiting.rawValue : record.status.rawValue),
                "updatedAt": .number(record.updated.timeIntervalSince1970)
            ]
        }
        let next = try page.last.flatMap { last in
            try page.count < matching.count ? BridgeListCursor(configurationID: configurationID, project: project, status: status, updated: last.updated, id: last.id).encoded() : nil
        }
        return ["tasks": .array(items), "nextCursor": next ?? .null]
    }
}
