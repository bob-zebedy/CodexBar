import Foundation
import Testing

struct ActivityReaderBoundsTests {
    @Test(arguments: [["repeat", "repeat"], ["a", "b", "a"], ["a", "b", "c"]])
    func invalidPaginationCannotCompleteBootstrap(cursors: [String]) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            for cursor in cursors {
                let request = try peer.readMessage()
                #expect(request["method"] as? String == "thread/loaded/list")
                try peer.reply(to: request, result: ["data": [], "nextCursor": cursor])
            }
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var failed = false
        var ready = false
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url, logStorage: nil,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url), maximumLoadedPages: 3
        ) { batch in
            if case .sourceUnavailable = batch {
                failed = true
            }
            if case .bootstrapEnd = batch {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !failed {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(failed)
        #expect(!ready)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test(arguments: [false, true])
    func incompleteDiscoveryCannotReportSuccessfulDrain(timesOut: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            let first = try peer.readMessage()
            try peer.reply(to: first, result: ["data": [], "nextCursor": "last"])
            let last = try peer.readMessage()
            #expect((last["params"] as? [String: Any])?["cursor"] as? String == "last")
            try peer.reply(to: last, result: ["data": []])
            let next = try peer.readMessage()
            #expect((next["params"] as? [String: Any])?["cursor"] == nil)
            if !timesOut {
                try peer.reply(to: next, result: ["data": [], "nextCursor": "repeat"])
                let repeated = try peer.readMessage()
                try peer.reply(to: repeated, result: ["data": [], "nextCursor": "repeat"])
            }
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var ready = false
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url, logStorage: nil,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url), reconciliationTimeout: 0.5
        ) { batch in
            if case .bootstrapEnd = batch {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        let start = Date()
        #expect(await reader.drainNow() == .sourceUnavailable)
        #expect(Date().timeIntervalSince(start) < 2)
        await reader.stop()
        release.signal()
        try server.finish()
    }

    @Test func missingRootAndCreationMetadataAreReadFromUnloadedParent() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date().addingTimeInterval(-60)
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            while let request = try? peer.readMessage() {
                let params = request["params"] as? [String: Any] ?? [:]
                let id = params["threadId"] as? String ?? ""
                switch request["method"] as? String {
                case "thread/loaded/list":
                    try peer.reply(to: request, result: ["data": ["child"]])
                case "thread/read", "thread/resume":
                    if request["method"] as? String == "thread/resume" {
                        #expect(id == "child")
                    }
                    var thread: [String: Any] = ["id": id, "source": "cli", "status": ["type": id == "child" ? "active" : "notLoaded"]]
                    if id == "child" {
                        thread["parentThreadId"] = "parent"
                    }
                    try peer.reply(to: request, result: ["thread": thread])
                case "thread/turns/list":
                    if id == "child" {
                        try peer.reply(to: request, result: ["data": [[
                            "id": "child-turn", "rootTurnId": "root-turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970 + 1
                        ]]])
                    } else if params["cursor"] == nil {
                        #expect(params["itemsView"] as? String == "full")
                        try peer.reply(to: request, result: ["data": [], "nextCursor": "older"])
                    } else {
                        #expect(params["cursor"] as? String == "older")
                        #expect(params["itemsView"] as? String == "full")
                        let item: [String: Any] = [
                            "id": "spawn", "type": "subAgentActivity", "kind": "started",
                            "agentThreadId": "child", "model": "child-model", "reasoningEffort": "low"
                        ]
                        let turn: [String: Any] = [
                            "id": "root-turn", "rootTurnId": "root-turn", "status": "completed",
                            "startedAt": now.timeIntervalSince1970, "completedAt": now.timeIntervalSince1970 + 2, "items": [item]
                        ]
                        try peer.reply(to: request, result: ["data": [turn]])
                    }
                default:
                    Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let lifecycle = SessionLifecycleCache()
        var ready = false
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycle, socketURL: server.url, logStorage: nil,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url), recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .bootstrapEnd = batch {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        #expect(await reader.drainNow() == .completed)
        let states = await lifecycle.lifecycleStates(for: [.init(threadID: "child", turnID: "child-turn")])
        let child = try #require(states.first)
        #expect(child.rootThreadID == "parent")
        #expect(child.rootTurnID == "root-turn")
        #expect(child.effort == "low")
        await reader.stop()
        try server.finish()
    }

    private nonisolated static func initialize(_ peer: SharedServerFixture.Peer) throws {
        let request = try peer.readMessage()
        try peer.reply(to: request, result: ["userAgent": "codex/0.162.0"])
        _ = try peer.readMessage()
    }
}

extension ActivityReaderBoundsTests {
    @Test(arguments: [false, true])
    func unresolvedChildOnlyBlocksLiveDrainWhileRunning(running: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let now = Date().addingTimeInterval(-60)
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            try peer.reply(to: request, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            while let request = try? peer.readMessage() {
                let params = request["params"] as? [String: Any] ?? [:]
                let id = params["threadId"] as? String ?? ""
                switch request["method"] as? String {
                case "thread/loaded/list":
                    try peer.reply(to: request, result: ["data": ["healthy", "child"]])
                case "thread/read", "thread/resume":
                    var thread: [String: Any] = ["id": id, "source": "cli", "status": ["type": id == "healthy" ? "active" : id == "child" ? "idle" : "notLoaded"]]
                    if id == "child" {
                        thread["parentThreadId"] = "deleted-parent"
                    }
                    try peer.reply(to: request, result: ["thread": thread])
                case "thread/turns/list":
                    let turns: [[String: Any]] = if id == "healthy" {
                        [["id": "healthy-turn", "rootTurnId": "healthy-turn", "status": "inProgress", "startedAt": now.timeIntervalSince1970]]
                    } else if id == "child" {
                        [[
                            "id": "child-turn", "rootTurnId": "missing-root", "status": running ? "inProgress" : "completed",
                            "startedAt": now.timeIntervalSince1970, "completedAt": now.timeIntervalSince1970 + 10
                        ]]
                    } else {
                        []
                    }
                    try peer.reply(to: request, result: ["data": turns])
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let lifecycle = SessionLifecycleCache()
        var ready = false
        let reader = AppServerActivityReader(
            lifecycleCache: lifecycle, socketURL: server.url, logStorage: nil,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url), recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            if case .bootstrapEnd = batch {
                ready = true
            }
        }
        await reader.start()
        for _ in 0 ..< 200 where !ready {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready)
        let result = await reader.drainNow()
        let states = await lifecycle.lifecycleStates(for: [.init(threadID: "healthy", turnID: "healthy-turn")])
        #expect(states.first?.readStatus == .complete)
        #expect(result == (running ? .sourceUnavailable : .completed))
        await reader.stop()
        try server.finish()
    }
}
