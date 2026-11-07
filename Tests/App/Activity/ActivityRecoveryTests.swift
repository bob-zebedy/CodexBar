import Foundation
import Synchronization
import Testing

@Suite(.tags(.integration))
struct ActivityRecoveryTests {
    @Test func missingSocketBacksOffWithoutRepeatingPresentationOrFailureLogs() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await storage.close() } }
        let delays = Mutex<[Duration]>([])
        var phases: [ActivityUpdate.Phase] = []
        let reader = AppServerActivityReader(
            socketURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).sock"), logStorage: storage,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            waitBeforeReconnect: { delay in
                let count = delays.withLock { $0.append(delay)
                    return $0.count
                }
                try await Task.sleep(for: count < 6 ? .milliseconds(10) : .seconds(60))
            },
            onBatch: { phases.append($0.phase) }
        )
        defer { await reader.stop() }
        await reader.start()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { delays.withLock { $0.count == 6 } })
        #expect(phases == [.sourceUnavailable])
        #expect(delays.withLock { $0 } == [.seconds(3), .seconds(6), .seconds(12), .seconds(24), .seconds(60), .seconds(60)])
        let entries = try await storage.page().entries
        #expect(entries.filter { $0.status == .failure }.count == 1)
        #expect(entries.first { $0.status == .failure }?.method == "activity/connection")
        let stoppedAt = ContinuousClock.now
        #expect(await reader.stop())
        #expect(ContinuousClock.now - stoppedAt < .seconds(2))
    }

    @Test func sourceAppearingDuringBackoffRecoversAndResetsRetryDelay() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let socketURL = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: socketURL) }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": []])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let delays = Mutex<[Duration]>([])
        var phases: [ActivityUpdate.Phase] = []
        let reader = AppServerActivityReader(
            socketURL: socketURL, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            waitBeforeReconnect: { delay in
                let count = delays.withLock { $0.append(delay)
                    return $0.count
                }
                if count == 3 {
                    try FileManager.default.createSymbolicLink(at: socketURL, withDestinationURL: server.url)
                }
                try await Task.sleep(for: count <= 3 ? .milliseconds(10) : .seconds(60))
            },
            onBatch: { phases.append($0.phase) }
        )
        defer { await reader.stop() }
        await reader.start()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { phases.contains(.bootstrapEnd) })
        #expect(phases == [.sourceUnavailable, .bootstrapStart, .bootstrapEnd])
        try await Task.sleep(for: .milliseconds(150))
        release.signal()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { delays.withLock { $0.count == 4 } })
        #expect(delays.withLock { $0 } == [.seconds(3), .seconds(6), .seconds(12), .seconds(3)])
        #expect(phases.last == .sourceUnavailable)
        #expect(await reader.stop())
        try server.finish()
    }

    @Test(arguments: ["item/started", "item/completed"])
    func reasoningContentDoesNotInvalidateLivePresentation(method: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": ["thread"]])
            let thread: [String: Any] = ["id": "thread", "source": "cli", "createdAt": timestamp, "cwd": "/tmp", "status": ["type": "active", "activeFlags": []]]
            let read = try peer.readMessage()
            try peer.reply(to: read, result: ["thread": thread])
            let resume = try peer.readMessage()
            try peer.reply(to: resume, result: ["thread": thread])
            let turns = try peer.readMessage()
            try peer.send(["method": "item/started", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]]])
            try peer.send(["method": method, "params": [
                "threadId": "thread", "turnId": "turn",
                "item": ["id": "reasoning", "type": "reasoning", "summary": [], "content": ["synthetic reasoning"]]
            ]])
            try peer.reply(to: turns, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": timestamp]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var received = false
        var failed = false
        var presentation: ActivityLiveSummary?
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            if batch.phase == .live, let task = batch.graph.tasks.values.first {
                received = true
                presentation = task.snapshot.presentation
            }
            if batch.phase == .sourceUnavailable {
                failed = true
            }
        }
        await reader.start()
        for _ in 0 ..< 100 {
            if received || failed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await reader.stop()
        release.signal()
        try server.finish()
        #expect(received)
        #expect(!failed)
        #expect(presentation != nil)
    }

    @Test(arguments: [false, true])
    func laterMalformedMessagePreservesEarlierValidEvent(_ malformed: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let timestamp = Date().timeIntervalSince1970
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let loaded = try peer.readMessage()
            try peer.reply(to: loaded, result: ["data": ["thread"]])
            let thread: [String: Any] = ["id": "thread", "source": "cli", "createdAt": timestamp, "cwd": "/tmp", "status": ["type": "active", "activeFlags": []]]
            let read = try peer.readMessage()
            try peer.reply(to: read, result: ["thread": thread])
            let resume = try peer.readMessage()
            try peer.reply(to: resume, result: ["thread": thread])
            let turns = try peer.readMessage()
            try peer.send(["method": "item/started", "params": ["threadId": "thread", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution"]]])
            if malformed {
                try peer.send(["method": "thread/status/changed", "params": ["threadId": "thread", "status": 123]])
            }
            try peer.reply(to: turns, result: ["data": [["id": "turn", "status": "inProgress", "startedAt": timestamp]]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var failed = false
        var live = 0
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(),
            socketURL: server.url,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url)
        ) { batch in
            switch batch.phase {
            case .sourceUnavailable: failed = true
            case .live: live += batch.graph.tasks.count
            default: break
            }
        }
        await reader.start()
        for _ in 0 ..< 100 {
            if failed || live > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await reader.stop()
        release.signal()
        try server.finish()
        let recorded = try directory.historyRecords().filter { $0.activityData != nil }.count
        #expect(recorded == 1)
        #expect(live == 1)
        #expect(!failed)
    }
}
