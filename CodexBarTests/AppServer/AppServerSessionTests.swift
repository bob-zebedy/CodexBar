import CryptoKit
import Darwin
import Foundation
import Testing

struct AppServerSessionTests {
    @Test(arguments: ["account", "activity"], [nil, "0.162.0", "codex/", "codex/invalid", "codex/0.159.0"] as [String?])
    func connectionsShareHandshakeValidation(_ connection: String, userAgent: String?) throws {
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            var result: [String: Any] = [:]
            result["userAgent"] = userAgent
            try peer.reply(to: request, result: result)
        }
        defer { server.close() }
        do {
            if connection == "account" {
                let session = try AccountSession(socketURL: server.url, logStorage: nil)
                defer { session.close() }
                _ = try session.initializeAccount()
            } else {
                let session = try AppServerSession(socketURL: server.url, logStorage: nil)
                defer { session.close() }
                try session.initialize(clientName: "codex_bar_activity", minimumVersion: CodexVersionReader.minimumAppServerVersion)
            }
            Issue.record("Expected handshake rejection")
        } catch let error as CodexStatusError {
            if userAgent == "codex/0.159.0" {
                guard case .unsupportedVersion = error else { Issue.record("Wrong error: \(error)")
                    return
                }
            } else {
                guard case .invalidServerResponse = error else { Issue.record("Wrong error: \(error)")
                    return
                }
            }
        }
        try server.finish()
    }

    @Test func accountRetriesUseNewIDsAndRememberUnsupportedMethods() throws {
        let server = try SharedServerFixture { peer in
            let first = try peer.readMessage()
            #expect(first["method"] as? String == "account/read")
            try peer.send(["id": #require(first["id"]), "error": ["code": -32000, "message": "temporary failure"]])
            let retry = try peer.readMessage()
            #expect(retry["id"] as? Int != first["id"] as? Int)
            try peer.reply(to: retry, result: ["value": 7])
            let unsupported = try peer.readMessage()
            #expect(unsupported["id"] as? Int != retry["id"] as? Int)
            try peer.send(["id": #require(unsupported["id"]), "error": ["code": -32601, "message": "unknown method"]])
            let next = try peer.readMessage()
            #expect(next["method"] as? String == "probe")
            try peer.reply(to: next, result: ["value": 8])
        }
        defer { server.close() }
        let session = try AccountSession(socketURL: server.url, logStorage: nil)
        defer { session.close() }
        let first = try session.request("account/read", as: Value.self)
        #expect(first.value == 7)
        for _ in 0 ..< 2 {
            #expect(throws: CodexStatusError.self) { _ = try session.request("missing", as: Value.self) }
        }
        let next = try session.request("probe", as: Value.self)
        #expect(next.value == 8)
        try server.finish()
    }

    @Test(arguments: [true, false])
    func activityReaderValidatesVersionAndReusesConnection(_ supported: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let releaseServer = DispatchSemaphore(value: 0)
        defer { releaseServer.signal() }
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            #expect(initialize["method"] as? String == "initialize")
            try peer.reply(to: initialize, result: ["userAgent": supported ? "codex/0.162.0" : "codex/0.159.0"])
            if supported {
                #expect(try peer.readMessage()["method"] as? String == "initialized")
                for _ in 0 ..< 4 {
                    let loaded = try peer.readMessage()
                    #expect(loaded["method"] as? String == "thread/loaded/list")
                    // 未知增量不能因业务载荷不兼容导致重连
                    for method in ["item/future/delta", "item/future/outputDelta", "hook/delta"] {
                        try peer.send(["method": method, "params": ["threadId": 123, "turn": false]])
                    }
                    try peer.reply(to: loaded, result: ["data": []])
                }
                #expect(releaseServer.wait(timeout: .now() + 5) == .success)
            }
        }
        defer { server.close() }
        var disconnected = false
        var bootstrapped = false
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url)
        ) { batch in
            switch batch {
            case .sourceUnavailable:
                disconnected = true
            case .bootstrapEnd:
                bootstrapped = true
            default:
                break
            }
        }
        await reader.start()
        for _ in 0 ..< 100 {
            if supported ? bootstrapped : disconnected {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(disconnected != supported)
        if supported {
            #expect(bootstrapped)
            for _ in 0 ..< 3 {
                #expect(await reader.drainNow() == .completed)
            }
            #expect(!disconnected)
        } else {
            #expect(!bootstrapped)
            #expect(disconnected)
        }
        await reader.stop()
        releaseServer.signal()
        try server.finish()
    }

    @Test(arguments: [true, false], [true, false])
    func logsStateAndPresentationWithoutDroppingDeltaDelivery(_ interleaved: Bool, _ polled: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let (filtered, retained) = try logDeliveryMessages()
        let messages = filtered + retained
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            if interleaved {
                for message in messages {
                    try peer.sendRaw(message)
                }
            }
            try peer.reply(to: request, result: ["value": 7])
            if !interleaved {
                for message in messages {
                    try peer.sendRaw(message)
                }
            }
            let done = try peer.readMessage()
            #expect(done["method"] as? String == "done")
            try peer.reply(to: done, result: ["value": 8])
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url, logStorage: storage)
        defer { session.close() }
        var delivered: [Data] = []
        if polled {
            let request = try session.beginRequest("probe", params: [:])
            receive: while true {
                switch try session.poll(request) {
                case .waiting: continue
                case let .event(data): delivered.append(data)
                case let .response(data):
                    #expect(try AppServerRPC.decode(data, as: Value.self).value == 7)
                    break receive
                }
            }
        } else {
            let response: Value = try session.request("probe")
            #expect(response.value == 7)
        }
        for _ in delivered.count ..< messages.count {
            let event = try #require(try session.nextEvent())
            delivered.append(event)
        }
        #expect(delivered == messages)
        let _: Value = try session.request("done")
        session.close()
        try server.finish()
        let page = try await storage.page(limit: 200)
        for message in filtered {
            #expect(!page.entries.contains { $0.detail == String(data: message, encoding: .utf8) })
        }
        for message in retained {
            #expect(page.entries.filter { $0.detail == String(data: message, encoding: .utf8) }.count == 1)
        }
        #expect(page.entries.filter { $0.method == "thread/tokenUsage/updated" }.count == 3)
        #expect(page.entries.first { $0.method == "probe" }?.status == .success)
        #expect(page.entries.contains { $0.method == "connection/closed" })
        let reopened = AppServerLogStore(directoryURL: directory.url)
        #expect(try await reopened.page(limit: 200).entries == page.entries)
    }

    private func logDeliveryMessages() throws -> (filtered: [Data], retained: [Data]) {
        var filtered = try unusedNotifications()
        var retained = try [
            "thread/started", "thread/status/changed", "turn/started", "turn/completed",
            "serverRequest/resolved", "account/updated", "account/rateLimits/updated", "error", "warning",
            "hook/started", "hook/completed", "model/rerouted", "model/verification",
            "modelProvider/authRecoveryStarted", "modelProvider/authRecoveryCompleted", "model/safetyBuffering/updated"
        ].map { try notification($0, params: ["marker": $0]) }
        try retained.append(notification("turn/diff/updated", params: ["diff": "original patch"]))
        try retained.append(notification("turn/plan/updated", params: ["plan": [["step": "original step", "status": "pending"]]]))
        for method in [
            "item/agentMessage/delta", "item/plan/delta", "item/reasoning/summaryTextDelta", "item/reasoning/textDelta",
            "item/commandExecution/outputDelta", "item/fileChange/outputDelta"
        ] {
            try filtered.append(notification(method, params: [
                "threadId": "thread", "turnId": "turn", "itemId": "item", "delta": "original fragment", "summaryIndex": 0, "contentIndex": 0
            ]))
        }
        try filtered.append(notification("item/agentMessage/delta", params: ["delta": 123]))
        for count in 1 ... 3 {
            try retained.append(notification("thread/tokenUsage/updated", params: ["total": count]))
        }
        for type in [
            "commandExecution",
            "fileChange",
            "webSearch",
            "imageView",
            "imageGeneration",
            "sleep",
            "mcpToolCall",
            "dynamicToolCall",
            "collabAgentToolCall",
            "contextCompaction",
            "subAgentActivity",
            "agentMessage",
            "reasoning",
            "enteredReviewMode",
            "exitedReviewMode"
        ] {
            for method in ["item/started", "item/completed"] {
                try retained.append(notification(method, params: ["item": ["type": type, "id": type, "output": "full output"]]))
            }
        }
        for method in [
            "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval",
            "mcpServer/elicitation/request"
        ] {
            try retained.append(JSONSerialization.data(withJSONObject: [
                "id": "approval", "method": method, "params": ["command": "original"]
            ]))
        }
        try retained.append(notification("item/completed", params: ["item": ["id": "malformed", "type": 123]]))
        return (filtered, retained)
    }

    private func notification(_ method: String, params: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
    }

    private func unusedNotifications() throws -> [Data] {
        var messages: [Data] = []
        for method in [
            "thread/settings/updated", "thread/environment/connected", "thread/environment/disconnected",
            "item/tool/requestUserInput", "item/autoApprovalReview/started", "item/autoApprovalReview/completed",
            "hook/futureEvent",
            "remoteControl/status/changed", "thread/goal/cleared", "thread/name/updated", "future/tool/delta"
        ] {
            try messages.append(notification(method, params: ["marker": method]))
        }
        try messages.append(JSONSerialization.data(withJSONObject: ["id": "unused", "method": "item/tool/call", "params": [:]]))
        for method in ["command/exec/outputDelta", "process/outputDelta", "item/future/delta", "item/future/outputDelta", "hook/delta"] {
            try messages.append(notification(method, params: ["deltaBase64": "dGVzdA==", "stream": "stdout"]))
        }
        try messages.append(notification("item/reasoning/summaryPartAdded", params: ["summaryIndex": 0]))
        try messages.append(notification("item/mcpToolCall/progress", params: ["message": "working"]))
        try messages.append(notification("mcpServer/startupStatus/updated", params: [
            "threadId": "thread", "name": "tripo_backend", "status": "starting"
        ]))
        for type in ["plan", "userMessage", "hookPrompt", "functionCallOutput", "futureItem"] {
            for method in ["item/started", "item/completed"] {
                try messages.append(notification(method, params: ["item": ["id": type, "type": type, "text": "body"]]))
            }
        }
        try messages.append(notification("mcpServer/elicitation/request", params: ["mode": "openai/userVerification"]))
        return messages
    }

    @Test func accountHandshakeUsesSharedSocketAndLeavesServerAvailable() throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            #expect(initialize["method"] as? String == "initialize")
            #expect((initialize["params"] as? [String: Any])?["capabilities"] as? [String: Bool] == ["experimentalApi": false])
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            #expect(try peer.readMessage()["method"] as? String == "initialized")
            let account = try peer.readMessage()
            #expect(account["method"] as? String == "account/read")
            #expect((account["params"] as? [String: Any])?["refreshToken"] as? Bool == false)
            try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
        }
        defer { server.close() }
        let session = try AccountSession(socketURL: server.url, logStorage: nil)
        let result = try session.initializeAccount()
        #expect(result.version == "0.162.0")
        #expect(result.account.account != nil)
        session.close()
        #expect(!session.isOpen)
        try server.finish()
        #expect(FileManager.default.fileExists(atPath: server.url.path))
    }

    @Test func accountMatchesResponseAfterNotificationAndPreservesPayloadErrorBoundary() throws {
        let server = try SharedServerFixture { peer in
            let first = try peer.readMessage()
            try peer.send(["method": "thread/tokenUsage/updated", "params": [:]])
            try peer.reply(to: first, result: ["value": "invalid"])
            let second = try peer.readMessage()
            try peer.reply(to: second, result: ["value": 42])
        }
        defer { server.close() }
        let session = try AccountSession(socketURL: server.url, logStorage: nil)
        defer { session.close() }
        do {
            _ = try session.request("probe", as: Value.self)
            Issue.record("Expected a payload error")
        } catch let error as CodexStatusError {
            #expect(!error.isTransportFailure)
            if case .invalidResponsePayload = error {} else {
                Issue.record("Wrong error: \(error)")
            }
        }
        #expect(session.isOpen)
        let value = try session.request("probe", as: Value.self)
        #expect(value.value == 42)
        try server.finish()
    }

    @Test func activityRetainsInterleavedApprovalWithoutAnsweringIt() throws {
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            try peer.send(["id": "approval", "method": "item/commandExecution/requestApproval", "params": [:]])
            try peer.reply(to: request, result: ["value": 7])
            let next = try peer.readMessage()
            #expect(next["method"] as? String == "probe")
            try peer.reply(to: next, result: ["value": 8])
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url, logStorage: nil)
        defer { session.close() }
        let first: Value = try session.request("probe")
        #expect(first.value == 7)
        let event = try #require(try session.nextEvent())
        let object = try #require(JSONSerialization.jsonObject(with: event) as? [String: Any])
        #expect(object["id"] as? String == "approval")
        let second: Value = try session.request("probe")
        #expect(second.value == 8)
        try server.finish()
    }

    @Test func missingSharedSocketFailsWithoutFallback() throws {
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).sock")
        #expect(throws: AppServerConnectionError.self) {
            _ = try AccountSession(socketURL: url, logStorage: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func disconnectedServerClosesAccountTransport() throws {
        let server = try SharedServerFixture { peer in
            _ = try peer.readMessage()
        }
        defer { server.close() }
        let session = try AccountSession(socketURL: server.url, logStorage: nil)
        #expect(throws: CodexStatusError.self) {
            _ = try session.request("probe", as: Value.self)
        }
        #expect(!session.isOpen)
        try server.finish()
    }

    @Test(arguments: ["account", "activity"])
    func bothConnectionsPersistFullWireRequestAndError(_ connection: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            try peer.send(["id": #require(request["id"]), "error": ["message": "body and secret", "code": -1]])
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url, logStorage: storage, connectionName: connection)
        defer { session.close() }
        #expect(throws: CodexStatusError.self) {
            let _: Value = try session.request("probe", params: ["text": "original body", "apiKey": "original secret"])
        }
        try server.finish()
        let page = try await storage.page()
        #expect(page.entries.filter { $0.method == "websocket/handshake" }.count == 1)
        #expect(page.entries.filter { $0.method == "probe" }.count == 1)
        let entry = try #require(page.entries.first { $0.method == "probe" })
        #expect(entry.connection == connection)
        #expect(entry.status == .failure)
        #expect(entry.request?.contains("original body") == true)
        #expect(entry.request?.contains("original secret") == true)
        #expect(entry.detail?.contains("body and secret") == true)
    }

    @Test(arguments: [true, false])
    func logsPushesApprovalsAndControlFramesOnceBeforeRouting(_ retainsNotifications: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            try peer.send(["method": "thread/tokenUsage/updated", "params": ["token": 123]])
            try peer.send(["id": #require(request["id"]), "method": "item/commandExecution/requestApproval", "params": ["command": "original"]])
            try peer.sendRaw(Data([0xFF, 0x00]), opcode: 9)
            #expect(try peer.readPayload(opcode: 10) == Data([0xFF, 0x00]))
            try peer.send(["id": 999, "result": ["unmatched": true]])
            try peer.reply(to: request, result: ["value": 7])
            try peer.send(["method": "item/completed", "params": ["text": "full content"]])
            let next = try peer.readMessage()
            #expect(next["method"] as? String == "done")
            try peer.reply(to: next, result: ["value": 8])
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url, retainsNotifications: retainsNotifications, logStorage: storage)
        let first: Value = try session.request("probe")
        #expect(first.value == 7)
        if retainsNotifications {
            for _ in 0 ..< 3 {
                #expect(try session.nextEvent() != nil)
            }
        }
        let live = try #require(try session.nextEvent())
        #expect(String(data: live, encoding: .utf8)?.contains("full content") == true)
        let _: Value = try session.request("done")
        session.close()
        session.close()
        try server.finish()
        let entries = try await storage.page().entries
        for method in [
            "thread/tokenUsage/updated", "item/commandExecution/requestApproval", "item/completed",
            "app-server/message", "websocket/ping", "websocket/pong", "connection/closed"
        ] {
            #expect(entries.filter { $0.method == method }.count == 1)
        }
        #expect(entries.first { $0.method == "websocket/ping" }?.detail == "base64:/wA=")
        #expect(entries.first { $0.method == "websocket/pong" }?.request == "base64:/wA=")
        #expect(entries.first { $0.method == "item/commandExecution/requestApproval" }?.isReceived == true)
        #expect(entries.first { $0.method == "item/completed" }?.detail?.contains("full content") == true)
        #expect(entries.filter { $0.method == "probe" }.count == 1)
        #expect(entries.first { $0.method == "probe" }?.status == .success)
    }

    @Test func malformedIncomingMessageAndConnectionFailureArePreserved() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let storage = AppServerLogStore(directoryURL: directory.url)
        let server = try SharedServerFixture { peer in
            _ = try peer.readMessage()
            try peer.sendRaw(Data("{broken JSON".utf8))
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url, logStorage: storage)
        do {
            let _: Value = try session.request("probe")
            Issue.record("Expected malformed JSON to fail")
        } catch {}
        session.close()
        try server.finish()
        let entries = try await storage.page().entries
        #expect(entries.first { $0.method == "app-server/message" }?.detail == "{broken JSON")
        #expect(entries.first { $0.method == "probe" }?.status == .failure)
        #expect(entries.filter { $0.method == "connection/closed" }.count == 1)
        #expect(throws: CodexStatusError.self) {
            _ = try AppServerSession(socketURL: directory.url.appendingPathComponent("missing.sock"), logStorage: storage)
        }
        #expect(try await storage.page().entries.contains { $0.method == "connection/open" && $0.status == .failure })
    }

    private nonisolated struct Value: Decodable {
        let value: Int
    }
}
