import Foundation
import Synchronization
import Testing

@MainActor
struct ActivityReconciliationTests {
    @Test(arguments: [false, true])
    func bootstrapCannotFinishARecoveryStartedAfterItsBarrier(restarted: Bool) throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDataDirectoryURL: directory.url
        )
        let recovery = UUID()
        let readerID = UUID()
        monitor.consume(ActivityUpdate(
            readerID: readerID,
            revision: 1,
            phase: .bootstrapStart,
            graph: ActivityTaskGraph(),
            transitions: [],
            terminalEvents: [],
            backfilledTasks: [],
            recoveryID: recovery
        ))
        #expect(monitor.activeRecoveryID == recovery)
        if restarted {
            monitor.beginProtectionRecovery()
        }
        monitor.consume(ActivityUpdate(
            readerID: readerID,
            revision: 2,
            phase: .bootstrapEnd,
            graph: ActivityTaskGraph(),
            transitions: [],
            terminalEvents: [],
            backfilledTasks: [],
            recoveryID: recovery
        ))
        #expect(monitor.isProtectionRecoveryInProgress == restarted)
        monitor.stop()
    }

    @Test func recoveryRetriesOnlyUnfinishedThreadsAndNewRecoveryReadsAllThreads() async throws {
        let directory = try TestDirectory()
        var readerStopped = true
        defer {
            if readerStopped {
                await #expect(throws: Never.self) { try await directory.removeAfterClosingHistory() }
            }
        }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let state = Mutex(Scenario())
        let initial = ContinuousClock.now
        let clock = Mutex(initial)
        let server = try SharedServerFixture { try Self.serve($0, state: state) }
        defer { server.close() }
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url),
            activityDataDirectoryURL: directory.url
        )
        var ready = false
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            reconciliationClock: { clock.withLock { $0 } },
            onBatch: { update in
                monitor.consume(update)
                if case .bootstrapEnd = update.phase {
                    ready = true
                }
            }
        )
        defer {
            let pendingRecovery = monitor.recoveryTask
            pendingRecovery?.cancel()
            monitor.activityReader = nil
            readerStopped = await reader.stop()
            await pendingRecovery?.value
            #expect(readerStopped)
        }
        monitor.activityReader = reader
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        let recovery = try #require(monitor.activeRecoveryID)
        for _ in 0 ..< 3 {
            monitor.requestActivityRecovery()
            await monitor.recoveryTask?.value
            #expect(monitor.isProtectionRecoveryInProgress)
        }
        #expect(monitor.activeRecoveryID == recovery)
        #expect(state.withLock { $0.reads } == ["missing": 1, "normal": 1])
        monitor.beginProtectionRecovery()
        monitor.requestActivityRecovery()
        await monitor.recoveryTask?.value
        #expect(state.withLock { $0.reads } == ["missing": 2, "normal": 2])
        #expect(monitor.isProtectionRecoveryInProgress)
        let nextRecovery = try #require(monitor.activeRecoveryID)
        state.withLock { $0.missing = false }
        clock.withLock { $0 = initial.advanced(by: .seconds(5)) }
        #expect(await reader.drainForRecovery(generation: nextRecovery).status == .completed)
        #expect(state.withLock { $0.reads } == ["missing": 3, "normal": 2])
        #expect(monitor.isProtectionRecoveryInProgress)
        monitor.requestActivityRecovery()
        await monitor.recoveryTask?.value
        #expect(!monitor.isProtectionRecoveryInProgress)
        #expect(monitor.canPublishActivityTransitions)
        #expect(await reader.stop())
        try server.finish()
    }

    @Test(arguments: [false, true])
    func boundedRetriesKeepIdleRefreshIntervalsAndEventuallyRecoverWithoutNotifications(delayedRetry: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let state = Mutex(Scenario())
        let initial = ContinuousClock.now
        let recovery = UUID()
        let clock = Mutex(initial)
        let server = try SharedServerFixture { try Self.serve($0, state: state) }
        defer { server.close() }
        var ready = false
        var disconnected = false
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            reconciliationClock: { clock.withLock { $0 } },
            onBatch: {
                if $0.phase == .bootstrapEnd {
                    ready = true
                }
                if $0.phase == .sourceUnavailable {
                    disconnected = true
                }
            }
        )
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        // 首次恢复读取后, 失败线程在 5, 20, 50 秒重试, 此后每 60 秒探测
        let schedule = delayedRetry ? [(0, 2, 2), (70, 3, 3), (75, 3, 3), (129, 3, 3)]
            : [(0, 2, 2), (4, 2, 2), (5, 3, 2), (19, 3, 2), (20, 4, 2), (49, 4, 2), (50, 5, 2), (60, 5, 3), (109, 5, 3)]
        for (seconds, missingReads, normalReads) in schedule {
            clock.withLock { $0 = initial.advanced(by: .seconds(seconds)) }
            let result = await reader.drainForRecovery(generation: recovery)
            #expect(result.status == .partial)
            if case let .update(update) = result {
                #expect(!update.isComplete)
            }
            #expect(state.withLock { $0.reads } == ["missing": missingReads, "normal": normalReads])
        }
        state.withLock { $0.missing = false }
        clock.withLock { $0 = initial.advanced(by: .seconds(delayedRetry ? 130 : 110)) }
        let recoveredReads = delayedRetry ? ["missing": 4, "normal": 4] : ["missing": 6, "normal": 3]
        #expect(await reader.drainForRecovery(generation: recovery).status == .completed)
        #expect(state.withLock { $0.reads } == recoveredReads)
        // 新一轮恢复重新执行完整屏障, 后续读取沿用这轮恢复的重试预算
        let nextRecovery = UUID()
        #expect(await reader.drainForRecovery(generation: nextRecovery).status == .completed)
        #expect(state.withLock { $0.reads } == recoveredReads.mapValues { $0 + 1 })
        state.withLock { $0.loaded = false }
        #expect(await reader.drainForRecovery(generation: nextRecovery).status == .completed)
        state.withLock { $0.loaded = true
            $0.missing = true
        }
        #expect(await reader.drainForRecovery(generation: nextRecovery).status == .partial)
        #expect(state.withLock { $0.reads } == recoveredReads.mapValues { $0 + 2 })
        #expect(!disconnected)
        #expect(await reader.stop())
        try server.finish()
    }

    @Test func liveThreadChangesInvalidateOnlyItsRecoveryResult() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let state = Mutex(Scenario())
        let clock = ContinuousClock.now
        let recovery = UUID()
        let server = try SharedServerFixture { try Self.serve($0, state: state) }
        defer { server.close() }
        var ready = false
        var publishedStates = [ActivityTaskState]()
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            reconciliationClock: { clock },
            onBatch: {
                if $0.phase == .bootstrapEnd {
                    ready = true
                }
                if let task = $0.graph.tasks[.init(thread: "normal", turn: "turn")] {
                    publishedStates.append(task.state)
                }
            }
        )
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        #expect(await reader.drainForRecovery(generation: recovery).status == .partial)
        for stage in 1 ... 3 {
            state.withLock { $0.stage = stage }
            let result = await reader.drainForRecovery(generation: recovery)
            #expect(result.status == .partial)
            if case let .update(update) = result {
                let key = ActivityTaskKey(thread: "normal", turn: "turn")
                if stage == 3 {
                    #expect(update.graph.tasks[key] == nil)
                    #expect(update.graph.recentlyEndedTaskAt[key] != nil)
                } else {
                    #expect(update.graph.tasks[key]?.state == (stage == 1 ? .running : .waitingApproval))
                }
            }
            #expect(state.withLock { $0.reads } == ["missing": 2, "normal": 2 + stage])
        }
        #expect(publishedStates.contains(.running))
        #expect(publishedStates.contains(.waitingApproval))
        #expect(await reader.stop())
        try server.finish()
    }

    @Test func protocolFailureStillReconnectsAndDiscardsPreviousChecks() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let state = Mutex(Scenario())
        let server = try SharedServerFixture(connections: 2) { try Self.serve($0, state: state) }
        defer { server.close() }
        var bootstraps = [ActivityUpdate]()
        var disconnected = false
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) {
            if $0.phase == .bootstrapEnd {
                bootstraps.append($0)
            }
            if $0.phase == .sourceUnavailable {
                disconnected = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where bootstraps.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(bootstraps.count == 1)
        state.withLock { $0.protocolFailure = true }
        #expect(await reader.drainForRecovery(generation: UUID()).status == .sourceUnavailable)
        for _ in 0 ..< 500 where bootstraps.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(bootstraps.count == 2)
        #expect(disconnected)
        #expect(bootstraps[0].recoveryID != bootstraps[1].recoveryID)
        #expect(bootstraps[1].isComplete)
        #expect(state.withLock { $0.reads } == ["missing": 3, "normal": 3])
        #expect(await reader.stop())
        try server.finish()
    }

    @Test func notificationDuringLastRetryPreventsCompletingWithStaleSuccess() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let state = Mutex(Scenario())
        let initial = ContinuousClock.now
        let clock = Mutex(initial)
        let recovery = UUID()
        let server = try SharedServerFixture { try Self.serve($0, state: state) }
        defer { server.close() }
        var ready = false
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            reconciliationClock: { clock.withLock { $0 } },
            onBatch: {
                if $0.phase == .bootstrapEnd {
                    ready = true
                }
            }
        )
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        #expect(await reader.drainForRecovery(generation: recovery).status == .partial)
        state.withLock { $0.missing = false
            $0.lateStage = 1
        }
        clock.withLock { $0 = initial.advanced(by: .seconds(5)) }
        #expect(await reader.drainForRecovery(generation: recovery).status == .partial)
        #expect(state.withLock { $0.reads } == ["missing": 3, "normal": 2])
        let result = await reader.drainForRecovery(generation: recovery)
        #expect(result.status == .completed)
        if case let .update(update) = result {
            #expect(update.graph.tasks[.init(thread: "normal", turn: "turn")]?.state == .running)
        }
        #expect(state.withLock { $0.reads } == ["missing": 3, "normal": 3])
        #expect(await reader.stop())
        try server.finish()
    }

    @Test(arguments: ["turn/started", "item/agentMessage/delta"])
    func activityExpeditesFailedThreadButDuplicateNotificationsRemainBounded(method: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let state = Mutex(Scenario())
        let initial = ContinuousClock.now
        let clock = Mutex(initial)
        let recovery = UUID()
        let server = try SharedServerFixture { try Self.serve($0, state: state) }
        defer { server.close() }
        var ready = false
        let reader = AppServerActivityReader(
            socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            reconciliationClock: { clock.withLock { $0 } },
            onBatch: {
                if $0.phase == .bootstrapEnd {
                    ready = true
                }
            }
        )
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready)
        for seconds in [0, 5, 20, 50] {
            clock.withLock { $0 = initial.advanced(by: .seconds(seconds)) }
            #expect(await reader.drainForRecovery(generation: recovery).status == .partial)
        }
        #expect(state.withLock { $0.reads } == ["missing": 5, "normal": 2])
        for seconds in 80 ... 84 {
            clock.withLock { $0 = initial.advanced(by: .seconds(seconds)) }
            state.withLock {
                $0.missingNotification = method
                $0.hasMissingActivity = true
                $0.timestamp = Date().addingTimeInterval(1).timeIntervalSince1970
            }
            #expect(await reader.drainForRecovery(generation: recovery).status == .partial)
            // 每轮 20 条通知只提前一次探测, 持续失败时仍保留最小间隔
            #expect(state.withLock { $0.reads } == ["missing": 6, "normal": 3])
        }
        clock.withLock { $0 = initial.advanced(by: .seconds(85)) }
        state.withLock { $0.missing = false }
        let result = await reader.drainForRecovery(generation: recovery)
        switch result {
        case let .update(update):
            #expect(update.graph.tasks[.init(thread: "missing", turn: "turn")]?.state == .running)
        default: Issue.record("Activity notification did not restore the failed thread")
        }
        #expect(state.withLock { $0.reads } == ["missing": 7, "normal": 3])
        clock.withLock { $0 = initial.advanced(by: .seconds(90)) }
        #expect(await reader.drainForRecovery(generation: recovery).status == .completed)
        #expect(state.withLock { $0.reads } == ["missing": 8, "normal": 3])
        #expect(await reader.stop())
        try server.finish()
    }

    private nonisolated struct Scenario {
        var reads: [String: Int] = [:]
        var missing = true
        var loaded = true
        var stage = 0
        var sentStage = 0
        var protocolFailure = false
        var lateStage: Int?
        var missingNotification: String?
        var hasMissingActivity = false
        var timestamp = Date().timeIntervalSince1970

        func thread(_ id: String) -> [String: Any] {
            let active = (id == "normal" && (stage == 1 || stage == 2)) || (id == "missing" && hasMissingActivity)
            return ["id": id, "source": "cli", "threadSource": "user", "status": [
                "type": active ? "active" : "idle", "activeFlags": active && stage == 2 ? ["waitingOnApproval"] : []
            ]]
        }

        var turn: [String: Any] {
            [
                "id": "turn",
                "rootTurnId": "turn",
                "status": stage == 3 ? "completed" : "inProgress",
                "startedAt": timestamp,
                "completedAt": stage == 3 ? timestamp + 1 : NSNull()
            ]
        }
    }

    private nonisolated static func serve(_ peer: SharedServerFixture.Peer, state: borrowing Mutex<Scenario>) throws {
        while let request = try? peer.readMessage() {
            let method = request["method"] as? String ?? ""
            let id = (request["params"] as? [String: Any])?["threadId"] as? String ?? ""
            let snapshot = state.withLock {
                if method == "thread/read" {
                    $0.reads[id, default: 0] += 1
                }
                return $0
            }
            switch method {
            case "initialize": try peer.reply(to: request, result: ["userAgent": "codex/0.165.0"])
            case "initialized": break
            case "thread/loaded/list":
                if let method = snapshot.missingNotification {
                    for _ in 0 ..< 20 {
                        try peer.send(["method": method, "params": ["threadId": "missing", "turnId": "turn", "turn": snapshot.turn, "itemId": "answer", "delta": "text"]])
                    }
                    state.withLock { $0.missingNotification = nil }
                }
                if snapshot.stage != snapshot.sentStage {
                    try sendStage(peer, snapshot: snapshot)
                    state.withLock { $0.sentStage = snapshot.stage }
                }
                try peer.reply(to: request, result: ["data": snapshot.loaded ? ["missing", "normal"] : []])
            case "thread/read", "thread/resume":
                if id == "missing", method == "thread/resume", let stage = snapshot.lateStage {
                    let changed = state.withLock {
                        $0.stage = stage
                        $0.sentStage = stage
                        $0.lateStage = nil
                        return $0
                    }
                    try sendStage(peer, snapshot: changed)
                }
                if id == "normal", snapshot.protocolFailure {
                    state.withLock { $0.protocolFailure = false
                        $0.missing = false
                    }
                    try peer.send(["id": #require(request["id"]), "error": ["code": -32602, "message": "invalid params"]])
                } else if id == "missing", snapshot.missing, method == "thread/resume" {
                    try peer.send(["id": #require(request["id"]), "error": ["code": -32600, "message": "no rollout found for thread id missing"]])
                } else {
                    try peer.reply(to: request, result: ["thread": snapshot.thread(id)])
                }
            case "thread/turns/list":
                let hasTurn = (id == "normal" && snapshot.stage > 0) || (id == "missing" && snapshot.hasMissingActivity)
                try peer.reply(to: request, result: ["data": hasTurn ? [snapshot.turn] : []])
            default: Issue.record("Unexpected request: \(method)")
            }
        }
    }

    private nonisolated static func sendStage(_ peer: SharedServerFixture.Peer, snapshot: Scenario) throws {
        if snapshot.stage == 1 || snapshot.stage == 3 {
            try peer.send(["method": snapshot.stage == 1 ? "turn/started" : "turn/completed", "params": ["threadId": "normal", "turn": snapshot.turn]])
        }
        try peer.send(["method": "thread/status/changed", "params": ["threadId": "normal", "status": #require(snapshot.thread("normal")["status"])]])
    }
}
