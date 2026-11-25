import Darwin
import Foundation
import os
import Testing

@Suite(.tags(.integration))
struct BridgeRecoveryTests {
    private func withTask(
        upstream: BridgeFixture = BridgeFixture(),
        _ check: (BridgeRuntime, UUID, BridgeJSON, URL, TestPreferences) async throws -> Void
    ) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let runtime = try preferences.makeBridgeRuntime(in: directory.url) { upstream }
        try await runtime.setEnabled(true)
        let owner = try await runtime.createConfiguration(name: "client", permissions: .init(writable: true)).id
        let start = try await runtime.execute(.start, args: ["project": .string(directory.url.path), "prompt": "check", "operationId": "start"], configurationID: owner)
        try await check(runtime, owner, start, directory.url, preferences)
        await runtime.shutdown()
    }

    private func question(_ id: String, titles: [String] = ["Continue?"]) -> BridgeJSON {
        ["type": "agentMessage", "delivery": "async", "id": .string(id), "questions": .array(titles.map { ["title": .string($0)] })]
    }

    private func emit(_ item: BridgeJSON, to runtime: BridgeRuntime, start: BridgeJSON) async throws {
        try await runtime.receive(["method": "item/completed", "params": ["threadId": start["taskId"], "turnId": start["turnId"], "item": item]])
    }

    private func reply(item: String, index: Int) throws -> BridgeJSON {
        let key: BridgeJSON = ["request_user_input_async", .string(item), .integer(index)]
        let entries: BridgeJSON = try [["questionItemId": .string(key.jsonText()), "answer": "yes"]]
        let text = try "<send_user_message_question_reply>\n" + entries.jsonText() + "\n</send_user_message_question_reply>"
        return ["type": "userMessage", "id": "reply", "content": [["type": "text", "text": .string(text)]]]
    }

    @Test(arguments: [false, true]) func anUncommittedFormReceiptPreventsResubmissionAcrossRestart(afterCompletion: Bool) async throws {
        let sends = OSAllocatedUnfairLock(initialState: 0)
        let upstream = BridgeFixture { method, _ in
            if method == "turn/steer" || method == "turn/start" {
                sends.withLock { $0 += 1 }
            }
        }
        try await withTask(upstream: upstream) { runtime, owner, start, directory, preferences in
            let item = question("question")
            let sibling = question("sibling", titles: ["Second form?"])
            try await emit(item, to: runtime, start: start)
            if afterCompletion {
                try await emit(sibling, to: runtime, start: start)
                try await runtime.receive(["method": "turn/completed", "params": ["threadId": start["taskId"], "turn": ["id": start["turnId"], "status": "completed"]]])
            }
            let wait: BridgeJSON = ["taskId": start["taskId"], "timeoutSeconds": .integer(0)]
            let first = try await runtime.execute(.wait, args: wait, configurationID: owner)
            let chosen = try #require(first["pendingRequests"].elements.first { $0["summary"] == "Continue?" })
            let args: BridgeJSON = ["taskId": start["taskId"], "requestId": chosen["requestId"]]
            let answer: BridgeJSON = ["action": "accept", "content": ["q1": "yes"]]
            let db = try BridgeSQLite(url: BridgeStore.databaseURL(in: directory))
            try db.run("""
            CREATE TRIGGER fail_form_receipt BEFORE UPDATE OF status ON operations WHEN NEW.id GLOB 'question/*'
            BEGIN SELECT RAISE(ABORT, 'fixture'); END
            """)
            let failure = await #expect(throws: BridgeFailure.self) { try await runtime.respond(args, configurationID: owner, response: answer) }
            #expect(failure?.code == "outcome_unknown")
            try db.run("DROP TRIGGER fail_form_receipt")
            await runtime.shutdown()
            let turn = try start.required("turnId")
            upstream.setHistory(turn, items: afterCompletion ? [item, sibling] : [item])
            let restored = try preferences.makeBridgeRuntime(in: directory) { upstream }
            try await restored.load()
            let pending = try await restored.execute(.wait, args: wait, configurationID: owner)
            let request = try #require(pending["pendingRequests"].elements.first { $0["summary"] == "Continue?" })
            #expect(request["status"] == "outcome_unknown")
            #expect(pending["nextAction"]["arguments"]["requestId"] != request["requestId"])
            let retry = await #expect(throws: BridgeFailure.self) {
                try await restored.respond(["taskId": start["taskId"], "requestId": request["requestId"]], configurationID: owner, response: answer)
            }
            #expect(retry?.code == "outcome_unknown")
            #expect(sends.withLock { $0 } == 2)
            let delivered = try reply(item: "question", index: 0)
            if afterCompletion {
                let latest = try upstream.call("thread/turns/list", ["threadId": start["taskId"]])
                let successor = try #require(latest["data"].elements.first?["id"].text)
                try #require(successor != turn)
                let sent = try #require(upstream.answer?["params"]["input"].elements.first?["text"])
                upstream.setHistory(successor, items: [["type": "userMessage", "id": "delivered", "content": [["type": "text", "text": sent]]]])
            } else {
                try await emit(delivered, to: restored, start: start)
            }
            let reconciled = try await restored.execute(.wait, args: wait, configurationID: owner)
            if afterCompletion {
                #expect(reconciled["turnId"] != start["turnId"])
                #expect(reconciled["pendingRequests"].elements.map { $0["summary"] } == ["Second form?"])
                let receipt = try await restored.respond(reconciled["nextAction"]["arguments"], configurationID: owner, response: answer)
                #expect(receipt["status"] == "submitted")
            } else {
                #expect(reconciled["pendingRequests"] == [])
            }
            await restored.shutdown()
        }
    }

    @Test func crossTurnFormWaitsForOlderPagesAndIgnoresReplayedTurnEvents() async throws {
        let upstream = BridgeFixture()
        try await withTask(upstream: upstream) { runtime, owner, start, directory, preferences in
            let task = start["taskId"], turn = start["turnId"]
            let older = question("older", titles: ["Earlier form?"])
            let recent = question("recent", titles: ["Recent form?"])
            let filler: BridgeJSON = ["type": "reasoning"]
            try upstream.setHistory(start.required("turnId"), items: [older] + Array(repeating: filler, count: 70) + [recent])
            let completion: BridgeJSON = ["method": "turn/completed", "params": ["threadId": task, "turn": ["id": turn, "status": "completed"]]]
            try await runtime.receive(completion)
            await runtime.shutdown()
            let restored = try preferences.makeBridgeRuntime(in: directory) { upstream }
            try await restored.load()
            let wait: BridgeJSON = ["taskId": task, "timeoutSeconds": .integer(0)]
            let initial = try await restored.execute(.wait, args: wait, configurationID: owner)
            #expect(initial["hasMore"] == .bool(true) && initial["nextAction"] == .null)
            let request = try #require(initial["pendingRequests"].elements.first)
            let args: BridgeJSON = ["taskId": task, "requestId": request["requestId"]]
            let answer: BridgeJSON = ["action": "accept", "content": ["q1": "yes"]]
            let early = await #expect(throws: BridgeFailure.self) { try await restored.respond(args, configurationID: owner, response: answer) }
            #expect(early?.code == "history_reconciling")
            let ready = try await restored.execute(.wait, args: wait, configurationID: owner)
            #expect(ready["pendingRequests"].elements.count == 2 && ready["nextAction"] != .null)
            let sent = try await restored.respond(args, configurationID: owner, response: answer)
            try #require(sent["turnId"] != turn)
            try await restored.receive(["method": "turn/started", "params": ["threadId": task, "turn": ["id": turn]]])
            try await restored.receive(completion)
            var latest = try await restored.execute(.wait, args: wait, configurationID: owner)
            for _ in 0 ..< 3 where latest["hasMore"] == .bool(true) {
                latest = try await restored.execute(.wait, args: wait, configurationID: owner)
            }
            #expect(latest["turnId"] == sent["turnId"])
            #expect(latest["pendingRequests"].elements.map { $0["summary"] } == ["Earlier form?"])
            await restored.shutdown()
        }
    }

    @Test func retryAfterCancellationStartsTheFirstTurnOnTheExistingThread() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let upstream = BridgeFixture { method, _ in
            if method == "thread/start" {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let runtime = try preferences.makeBridgeRuntime(in: directory.url) { upstream }
        try await runtime.setEnabled(true)
        let owner = try await runtime.createConfiguration(name: "client").id
        let args: BridgeJSON = ["project": .string(directory.url.path), "prompt": "test", "operationId": "start"]
        let first = Task { try await runtime.execute(.start, args: args, configurationID: owner) }
        await #expect(throws: CancellationError.self) { try await first.value }
        let record = try #require(try await runtime.execute(.list, args: [:], configurationID: owner)["tasks"].elements.first)
        #expect(record["turnId"] == .null && upstream.answer == nil)
        await runtime.shutdown()
        let restored = try preferences.makeBridgeRuntime(in: directory.url) { upstream }
        try await restored.load()
        let receipt = try await restored.execute(.start, args: args, configurationID: owner)
        #expect(upstream.starts == 1 && receipt["taskId"] == record["taskId"] && receipt["turnId"] != .null)
        await restored.shutdown()
    }

    @Test func splitOutOfOrderRepliesCloseAnOpenFormOnlyWhenComplete() async throws {
        try await withTask { runtime, owner, start, _, _ in
            try await emit(reply(item: "q", index: 1), to: runtime, start: start)
            let q = question("q", titles: ["First?", "Second?"])
            try await emit(q, to: runtime, start: start)
            try await emit(reply(item: "q", index: 1), to: runtime, start: start)
            let wait: BridgeJSON = ["taskId": start["taskId"], "timeoutSeconds": .integer(0)]
            let snapshot = try await runtime.execute(.wait, args: wait, configurationID: owner)
            try #require(snapshot["pendingRequests"].elements.count == 1)
            let command = try BridgeTool.respond.parse(snapshot["nextAction"]["arguments"])
            let final = try reply(item: "q", index: 0)
            let failure = await #expect(throws: BridgeFailure.self) {
                try await runtime.execute(command, configurationID: owner) { _ in
                    try await runtime.receive(["method": "item/completed", "params": ["threadId": start["taskId"], "turnId": start["turnId"], "item": final]])
                    return ["action": "cancel"]
                }
            }
            #expect(failure?.code == "request_closed")
            try await emit(q, to: runtime, start: start)
            #expect(try await runtime.execute(.wait, args: wait, configurationID: owner)["pendingRequests"] == [])
        }
    }

    @Test func fullQuestionQueueRefillsAfterAnAnswerAndIgnoresClosedItems() async throws {
        let upstream = BridgeFixture()
        try await withTask(upstream: upstream) { runtime, owner, start, _, _ in
            let items = (1 ... 65).map { question(String($0), titles: ["Question " + String($0)]) }
            try upstream.setHistory(start.required("turnId"), items: items)
            for item in items {
                try await emit(item, to: runtime, start: start)
            }
            let wait: BridgeJSON = ["taskId": start["taskId"], "timeoutSeconds": .integer(0)]
            func snapshot() async throws -> BridgeJSON {
                try await runtime.execute(.wait, args: wait, configurationID: owner)
            }
            let full = try await snapshot()
            try #require(full["pendingRequests"].elements.count == 64)
            #expect(full["pendingRequestWarning"] == "question_capacity_reached")
            _ = try await runtime.respond(full["nextAction"]["arguments"], configurationID: owner, response: ["action": "cancel"])
            var page = try await snapshot()
            for _ in 0 ..< 4 where page["hasMore"] == .bool(true) && !page["pendingRequests"].elements.contains(where: { $0["summary"] == "Question 65" }) {
                page = try await snapshot()
            }
            #expect(page["pendingRequests"].elements.count == 64)
            #expect(page["pendingRequests"].elements.contains { $0["summary"] == "Question 65" })
            for _ in 0 ..< 64 {
                let current = try await snapshot()
                _ = try await runtime.respond(current["nextAction"]["arguments"], configurationID: owner, response: ["action": "cancel"])
            }
            try await emit(items[0], to: runtime, start: start)
            try await emit(question("66"), to: runtime, start: start)
            #expect(try await snapshot()["pendingRequests"].elements.count == 1)
        }
    }

    @Test func longPollReturnsTheCloseEventFoundOnTheLastHistoryPage() async throws {
        let upstream = BridgeFixture()
        try await withTask(upstream: upstream) { runtime, owner, start, _, _ in
            let task = start["taskId"]
            let turn = try upstream.call("turn/start", ["threadId": task])["turn"].required("id")
            try await runtime.receive(["method": "turn/started", "params": ["threadId": task, "turn": ["id": .string(turn)]]])
            let question = question("q")
            try await emit(question, to: runtime, start: ["taskId": task, "turnId": .string(turn)])
            let progress: BridgeJSON = ["type": "agentMessage", "phase": "commentary", "text": "working"]
            try upstream.setHistory(turn, items: [question, reply(item: "q", index: 0)] + Array(repeating: progress, count: 32))
            let first = try await runtime.execute(.wait, args: ["taskId": task], configurationID: owner)
            try #require(first["hasMore"] == .bool(true))
            let request = try #require(first["pendingRequests"].elements.first)

            let clock = ContinuousClock.now
            let next = try await runtime.execute(.wait, args: ["taskId": task, "after": first["nextCursor"], "timeoutSeconds": .integer(4)], configurationID: owner)
            #expect(clock.duration(to: .now) < .seconds(3))
            #expect(next["status"] == "running" && next["pendingRequests"] == [])
            #expect(next["events"] == [["type": "request_closed", "requestId": request["requestId"]]])
        }
    }

    @Test func terminalHistoryOutageRetriesAndDeliversTheFinalText() async throws {
        let upstream = BridgeFixture()
        try await withTask(upstream: upstream) { runtime, owner, start, directory, preferences in
            try upstream.setHistory(start.required("turnId"), items: [["type": "agentMessage", "phase": "final_answer", "text": "done"]])
            try await runtime.receive(["method": "turn/completed", "params": ["threadId": start["taskId"], "turn": ["id": start["turnId"], "status": "completed"]]])
            await runtime.shutdown()
            let available = OSAllocatedUnfairLock(initialState: false)
            let restored = try preferences.makeBridgeRuntime(in: directory) {
                guard available.withLock({ $0 }) else { throw AppServerError.serverConnectionClosed }
                return upstream
            }
            try await restored.load()
            let first = try await restored.execute(.wait, args: ["taskId": start["taskId"], "timeoutSeconds": .integer(0)], configurationID: owner)
            #expect(first["hasMore"] == .bool(true) && first["result"] == .null && first["retryAfterSeconds"].int != nil)
            let cursor = first["nextCursor"]
            let tooSoon = await #expect(throws: BridgeFailure.self) {
                try await restored.execute(.wait, args: ["taskId": start["taskId"], "after": cursor, "timeoutSeconds": .integer(0)], configurationID: owner)
            }
            #expect(tooSoon?.code == "history_retry_later")
            available.withLock { $0 = true }
            let final = try await restored.execute(.wait, args: ["taskId": start["taskId"], "after": cursor], configurationID: owner)
            #expect(final["hasMore"] == .bool(false) && final["result"] == "done")
            await restored.shutdown()
        }
    }

    @Test func historyPollingStartsANewRetryCycleAfterThreeFailures() async throws {
        let upstream = BridgeFixture { method, _ in
            if method == "thread/items/list" {
                throw AppServerError.serverConnectionClosed
            }
        }
        try await withTask(upstream: upstream) { runtime, owner, start, _, _ in
            let task = start["taskId"]
            try await runtime.receive(["method": "turn/completed", "params": ["threadId": task, "turn": ["id": start["turnId"], "status": "completed"]]])
            let first = try await runtime.execute(.wait, args: ["taskId": task], configurationID: owner)
            try #require(first["retryAfterSeconds"].int == 1)
            let poll: BridgeJSON = ["taskId": task, "after": first["nextCursor"]]
            let second = try await runtime.execute(.wait, args: poll, configurationID: owner)
            #expect(second["retryAfterSeconds"].int == 2)
            let third = try await runtime.execute(.wait, args: poll, configurationID: owner)
            #expect(third["resultWarning"] == "history_unavailable" && third["hasMore"] == .bool(false))
            #expect(try await runtime.execute(.wait, args: poll, configurationID: owner)["resultWarning"] == "history_unavailable")

            try await Task.sleep(for: .seconds(4))
            let next = try await runtime.execute(.wait, args: ["taskId": task, "timeoutSeconds": .integer(0)], configurationID: owner)
            #expect(next["retryAfterSeconds"].int == 1 && next["hasMore"] == .bool(true))
        }
    }

    @Test func slowCancelledPeerPreservesAnotherApprovalAndAllowsNewHandshakes() async throws {
        let waiting = OSAllocatedUnfairLock(initialState: false)
        let entered = OSAllocatedUnfairLock(initialState: false)
        let delay = DispatchSemaphore(value: 0)
        let upstream = BridgeFixture { method, _ in
            guard method == "thread/start", waiting.withLock({ $0 }) else { return }
            entered.withLock { $0 = true }
            let deadline = ContinuousClock.now + .seconds(5)
            while delay.wait(timeout: .now() + .milliseconds(15)) == .timedOut {
                try AppServerRequestBudget.checkCurrent()
                guard ContinuousClock.now < deadline else { throw AppServerError.serverTimeout }
            }
            try AppServerRequestBudget.checkCurrent()
        }
        try await withTask(upstream: upstream) { runtime, owner, start, directory, _ in
            let host = BridgeHost(runtime: runtime)
            try await host.restore()
            try await runtime.receive(["id": .integer(31), "method": "item/commandExecution/requestApproval", "params": [
                "threadId": start["taskId"], "turnId": start["turnId"], "itemId": "item", "command": "pwd", "cwd": .string(directory.path), "reason": "Check?"
            ]])
            let snapshot = try await runtime.execute(.wait, args: ["taskId": start["taskId"]], configurationID: owner)
            let approval = snapshot["nextAction"]["arguments"]
            try #require(approval["requestId"].text != nil)
            let token = try await runtime.createConfigurationToken(name: "client A")
            let peer = BridgePeer(runtime: runtime, output: { _ in })
            let hello: BridgeJSON = ["credential": .string(token), "session": ["version": "2025-11-25"], "initialized": .bool(true)]
            try await peer.accept(hello.data())
            let endpoint = try BridgeEndpoint(in: directory)
            waiting.withLock { $0 = true }
            let args: BridgeJSON = ["project": .string(directory.path), "prompt": "test", "operationId": "second"]
            let startCall: BridgeJSON = ["jsonrpc": "2.0", "id": .integer(9), "method": "tools/call", "params": ["name": "codex_start", "arguments": args]]
            try await peer.accept(startCall.data())
            let deadline = ContinuousClock.now + .seconds(3)
            while !entered.withLock({ $0 }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(entered.withLock { $0 })
            try await Task.detached {
                let fd = try BridgeIPC.connect(to: endpoint, hello: ["credential": .string(token)])
                defer { Darwin.close(fd) }
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
                let initialize: BridgeJSON = ["jsonrpc": "2.0", "id": .integer(1), "method": "initialize", "params": ["protocolVersion": "2025-11-25"]]
                try BridgeIPC.write(initialize.data() + Data([10]), to: fd)
                #expect(try BridgeTransportTests.readFrame(fd)?["result"]["protocolVersion"] == "2025-11-25")
            }.value
            await peer.close()
            delay.signal()
            _ = try await runtime.respond(approval, configurationID: owner, response: ["action": "decline"])
            #expect(upstream.answer == ["id": .integer(31), "result": ["decision": "decline"]])
            #expect(upstream.starts == 2)
            await host.stop()
        }
    }

    @Test(arguments: [false, true]) func startupWriteLockRetriesUnlessStopped(stop: Bool) async throws {
        try await withTask { runtime, _, _, directory, preferences in
            await runtime.shutdown()
            let db = try BridgeSQLite(url: BridgeStore.databaseURL(in: directory))
            try db.run("BEGIN IMMEDIATE")
            let restored = try preferences.makeBridgeRuntime(in: directory) { BridgeFixture() }
            let host = BridgeHost(runtime: restored)
            let attempt = Task { try await host.restore() }
            try await Task.sleep(for: .milliseconds(2200))
            if stop {
                await host.stop()
            }
            try db.run("ROLLBACK")
            if stop {
                await #expect(throws: CancellationError.self) { try await attempt.value }
            } else {
                try await attempt.value
            }
            let endpoint = try BridgeEndpoint(in: directory)
            #expect(FileManager.default.fileExists(atPath: endpoint.path) == !stop)
            #expect(restored.isEnabled)
            await host.stop()
        }
    }
}
