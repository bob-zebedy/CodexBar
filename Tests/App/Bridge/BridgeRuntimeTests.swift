import Foundation
import Testing

struct BridgeRuntimeTests {
    @Test(.tags(.integration))
    func clientWithMatchingTokenAnswersTheRequestAndRecoversTheTask() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let path = CodexPaths.canonicalPath(directory.path)
        let token = try await runtime.createConfigurationToken(name: "writer", writable: true)
        let configurationID = try runtime.configurationID(forToken: token)
        let otherConfigurationID = try await runtime.createConfiguration(name: "other", permissions: .init(writable: true)).id
        let args: BridgeJSON = ["project": .string(path), "prompt": "review", "operationId": "start-1"]
        let start = try await runtime.execute(.start, args: args, configurationID: configurationID)
        let replay = try await runtime.execute(.start, args: args, configurationID: configurationID)
        #expect(start == replay)
        #expect(upstream.starts == 1)
        let task = start["taskId"]
        let turn = start["turnId"]
        let empty = try await runtime.execute(.list, args: [:], configurationID: otherConfigurationID)
        #expect(empty["tasks"].elements.isEmpty)
        let approval: BridgeJSON = [
            "method": "item/commandExecution/requestApproval",
            "id": .integer(44),
            "params": ["threadId": task, "turnId": turn, "itemId": "item1", "command": "pwd", "cwd": .string(path), "reason": "Check the working directory?"]
        ]
        try await runtime.receive(approval)
        let snapshot = try await runtime.execute(.wait, args: ["taskId": task, "after": start["cursor"]], configurationID: configurationID)
        #expect(snapshot["status"] == "waiting")
        #expect(snapshot["pendingRequests"].elements.first?["summary"] == "Check the working directory?")
        let waiting = try await runtime.execute(.list, args: ["status": "waiting"], configurationID: configurationID)
        #expect(waiting["tasks"].elements.first?["taskId"] == task)
        let response = snapshot["nextAction"]["arguments"]
        let denied = await #expect(throws: BridgeFailure.self) { try await runtime.respond(response, configurationID: otherConfigurationID, response: ["action": "accept"]) }
        #expect(denied?.code == "task_not_found")
        try await verifyFileChangeRequest(runtime, upstream: upstream, configurationID: configurationID, task: task, turn: turn)
        try await approveCommandInSimplifiedChinese(runtime: runtime, token: token, response: response)
        #expect(upstream.answer == ["id": .integer(44), "result": ["decision": "accept"]])
        let duplicate = await #expect(throws: BridgeFailure.self) { try await runtime.respond(response, configurationID: configurationID, response: ["action": "decline"]) }
        #expect(duplicate?.code == "request_closed")
        let steering = try await runtime.execute(.reply, args: ["taskId": task, "turnId": turn, "message": "clarify", "operationId": "steer1"], configurationID: configurationID)
        #expect(steering["turnId"] == turn)
        let interrupted = try await runtime.execute(.interrupt, args: ["taskId": task, "turnId": turn], configurationID: configurationID)
        #expect(interrupted["status"] == "interrupt_requested")
        let completed: BridgeJSON = ["method": "turn/completed", "params": ["threadId": task, "turn": ["id": turn, "status": "interrupted", "items": []]]]
        try await runtime.receive(completed)
        await runtime.shutdown()
        let restored = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await restored.load()
        let listed = try await restored.execute(.list, args: [:], configurationID: configurationID)
        #expect(listed["tasks"].elements.first?["status"] == "interrupted")
        let recovered = try await restored.execute(.wait, args: ["taskId": task, "after": start["cursor"]], configurationID: configurationID)
        #expect(recovered["warning"] == "cursor_expired")
        for result in [listed, recovered] {
            #expect(try !result.jsonText().contains(token))
        }
        #expect(try await restored.execute(.start, args: args, configurationID: configurationID) == start)
    }

    private func approveCommandInSimplifiedChinese(runtime: BridgeRuntime, token: String, response: BridgeJSON) async throws {
        let output = BridgeFixtureOutput()
        let peer = BridgePeer(runtime: runtime, output: { try await output.write($0) })
        try await peer.accept(BridgeJSON.object(["credential": .string(token)]).data())
        try await peer.accept(BridgeJSON.object([
            "jsonrpc": "2.0",
            "id": .integer(1),
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": ["elicitation": ["form": [:]]]]
        ]).data())
        try await peer.accept(BridgeJSON.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).data())
        var arguments = try #require(response.fields)
        arguments["locale"] = "zh-CN"
        try await peer.accept(BridgeJSON.object([
            "jsonrpc": "2.0",
            "id": .integer(2),
            "method": "tools/call",
            "params": ["name": "codex_respond", "arguments": .object(arguments)]
        ]).data())
        let form = try await output.wait { $0["method"] == "elicitation/create" }
        #expect(form["params"]["message"] == "Check the working directory?")
        let choices = form["params"]["requestedSchema"]["properties"]["decision"]["oneOf"].elements
        #expect(choices == [["const": "allow_once", "title": "允许一次"], ["const": "deny", "title": "拒绝"]])
        let allow = try #require(choices.first)["const"]
        let formReply: BridgeJSON = ["jsonrpc": "2.0", "id": form["id"], "result": ["action": "accept", "content": ["decision": allow]]]
        try await peer.accept(formReply.data())
        let result = try await output.wait { $0["id"] == .integer(2) }
        #expect(result["result"]["structuredContent"]["status"] == "submitted")
        await peer.close()
    }

    private func verifyFileChangeRequest(_ runtime: BridgeRuntime, upstream: BridgeFixture, configurationID: UUID, task: BridgeJSON, turn: BridgeJSON) async throws {
        try await runtime.receive(["method": "item/started", "params": ["threadId": task, "turnId": turn, "item": [
            "type": "fileChange", "id": "file1", "changes": [["path": "before", "kind": ["type": "update", "move_path": "after"]]]
        ]]])
        try await runtime.receive([
            "method": "item/fileChange/requestApproval",
            "id": .integer(45),
            "params": ["threadId": task, "turnId": turn, "itemId": "file1"]
        ])
        let changes = try await runtime.execute(.wait, args: ["taskId": task], configurationID: configurationID)
        let fileRequest = try #require(changes["pendingRequests"].elements.first { $0["summary"].text?.contains("/after") == true })
        _ = try await runtime.respond(["taskId": task, "requestId": fileRequest["requestId"]], configurationID: configurationID, response: ["action": "decline"])
        #expect(upstream.answer == ["id": .integer(45), "result": ["decision": "decline"]])
        let after = try await runtime.execute(.wait, args: ["taskId": task, "after": changes["nextCursor"], "timeoutSeconds": .integer(0)], configurationID: configurationID)
        #expect(after["events"] == [["type": "response_submitted", "requestId": fileRequest["requestId"]]])
    }

    @Test(.tags(.integration))
    func readOnlyConfigurationAutomaticallyDeclinesFileApproval() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "reader").id
        let project = BridgeJSON.string(CodexPaths.canonicalPath(directory.path))
        let start = try await runtime.execute(.start, args: ["project": project, "prompt": "review", "operationId": "start"], configurationID: configurationID)
        let task = start["taskId"]
        try await runtime.receive(["method": "item/fileChange/requestApproval", "id": .integer(45), "params": [
            "threadId": task, "turnId": start["turnId"], "grantRoot": project
        ]])
        #expect(upstream.answer == ["id": .integer(45), "result": ["decision": "decline"]])
        let snapshot = try await runtime.execute(.wait, args: ["taskId": task, "after": start["cursor"], "timeoutSeconds": .integer(0)], configurationID: configurationID)
        #expect(snapshot["events"] == [["type": "request_declined", "reason": "unsupported_or_unauthorized_request"]])
        #expect(snapshot["pendingRequests"] == [])
        #expect(snapshot["nextAction"] == .null)
    }

    @Test(.tags(.integration))
    func disablingBridgePersistsWithoutRemovingTasksOrCredentials() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await runtime.load()
        #expect(!runtime.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: BridgeStore.databaseURL(in: directory).path))
        let token = try await runtime.createConfigurationToken(name: "reader")
        #expect(!preferences.defaults.bool(forKey: "Bridge.isEnabled"))
        let initialDenial = #expect(throws: BridgeFailure.self) { try runtime.configurationID(forToken: token) }
        #expect(initialDenial?.code == "unauthorized")
        try await runtime.setEnabled(true)
        #expect(preferences.defaults.bool(forKey: "Bridge.isEnabled"))
        let configurationID = try runtime.configurationID(forToken: token)
        let receipt = try await runtime.execute(.start, args: ["project": .string(directory.path), "prompt": "review", "operationId": "one"], configurationID: configurationID)
        try await runtime.setEnabled(false)
        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await reopened.load()
        #expect(!reopened.isEnabled)
        let denied = #expect(throws: BridgeFailure.self) { try reopened.configurationID(forToken: token) }
        #expect(denied?.code == "unauthorized")
        try await reopened.setEnabled(true)
        #expect(try reopened.configurationID(forToken: token) == configurationID)
        #expect(try await reopened.execute(.list, args: [:], configurationID: configurationID)["tasks"].elements.first?["taskId"] == receipt["taskId"])
    }

    @Test(.tags(.integration))
    func toolUsageUpdatesTheListAndFlushesAfterDisable() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        let first = try await runtime.createConfiguration(name: "first")
        _ = try await runtime.createConfiguration(name: "second")
        var updates = try await runtime.configurationUpdates().makeAsyncIterator()
        let editor = try BridgeSQLite(url: BridgeStore.databaseURL(in: directory))
        _ = await updates.next(isolation: #isolation)
        let host = BridgeHost(runtime: runtime)
        try await host.setEnabled(true)
        try await runtime.recordToolUse(for: first.id)
        let snapshot = await updates.next(isolation: #isolation)
        #expect(snapshot?.map(\.usageCount) == [1, 0])
        func storedCount() throws -> Int64 {
            try editor.number("SELECT uses FROM configurations WHERE id = ?", [.text(first.id.uuidString)])
        }
        #expect(try storedCount() == 1)
        try editor.run("BEGIN IMMEDIATE")
        try await runtime.recordToolUse(for: first.id)
        try await host.setEnabled(false)
        #expect(try storedCount() == 1)
        try editor.run("COMMIT")
        let flushed = try await waitForCondition(timeout: .seconds(5), pollInterval: .milliseconds(20)) {
            (try? storedCount()) == 2
        }
        #expect(flushed)
        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await reopened.load()
        #expect(await reopened.configurations.map(\.usageCount) == [2, 0])
    }

    @Test(.tags(.integration))
    func failedUsageWriteWaitsForTheNextToolCallWhileOtherCountsRecover() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let runtime = try preferences.makeBridgeRuntime(in: directory.url, connect: { BridgeFixture() })
        try await runtime.setEnabled(true)
        let first = try await runtime.createConfiguration(name: "first")
        let second = try await runtime.createConfiguration(name: "second")
        let writer = try BridgeSQLite(url: BridgeStore.databaseURL(in: directory.url))
        func storedUses(_ configuration: BridgeConfiguration) throws -> Int64 {
            try writer.number("SELECT uses FROM configurations WHERE id = ?", [.text(configuration.id.uuidString)])
        }

        try writer.run("BEGIN IMMEDIATE")
        try await runtime.recordToolUse(for: first.id)
        try writer.run("""
        CREATE TRIGGER reject_first BEFORE UPDATE OF uses ON configurations WHEN OLD.name = 'first'
        BEGIN SELECT RAISE(ABORT, 'fixture'); END
        """)
        try writer.run("COMMIT")
        try await runtime.setEnabled(false)
        #expect(try storedUses(first) == 0)
        try writer.run("DROP TRIGGER reject_first")

        try await runtime.setEnabled(true)
        try writer.run("BEGIN IMMEDIATE")
        try await runtime.recordToolUse(for: second.id)
        try writer.run("COMMIT")
        let recovered = try await waitForCondition(timeout: .seconds(5), pollInterval: .milliseconds(20)) {
            (try? storedUses(second)) == 1
        }
        try #require(recovered)
        #expect(await runtime.configurations.map(\.usageCount) == [1, 1])
        #expect(try storedUses(first) == 0)
        try await runtime.recordToolUse(for: first.id)
        #expect(try storedUses(first) == 2)
    }

    @Test(.tags(.integration))
    func configurationNamesAllowThirtyCharacters() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        let name = String(repeating: "名", count: 29) + "👩🏽‍💻"
        let configuration = try await runtime.createConfiguration(name: name)
        await #expect(throws: BridgeFailure.self) { try await runtime.createConfiguration(name: name + "字") }
        await #expect(throws: BridgeFailure.self) { try await runtime.updateConfiguration(configuration.id, name: name + "字", permissions: .init()) }
        #expect(await runtime.configurations.map(\.name) == [name])
    }

    @Test(.tags(.integration))
    func exportUsesTheSameConfigurationTokenAcrossReopens() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await runtime.setEnabled(true)
        let first = try await runtime.createConfiguration(name: "Same name")
        let permissions = BridgePermissions(writable: true, network: .allow, approval: .deny)
        let second = try await runtime.createConfiguration(name: "Same name", permissions: permissions)
        await #expect(throws: BridgeFailure.self) { try await runtime.createConfiguration(name: "Invalid", permissions: .init(network: .ask, approval: .deny)) }
        let path = directory.appendingPathComponent("CodexBar Debug.app/Contents/MacOS/CodexBar")
        let original = try await runtime.exportMCPConfiguration(for: first.id, format: .genericJSON, executable: path)
        let config = try JSONDecoder().decode(BridgeJSON.self, from: Data(original.utf8))["mcpServers"]["codex"]
        #expect(config["command"] == .string(path.path))
        #expect(config["args"] == ["--mcp"])
        let token = try #require(config["env"]["CODEXBAR_BRIDGE_TOKEN"].text)
        #expect(try runtime.configurationID(forToken: token) == first.id)
        try await runtime.recordToolUse(for: first.id)
        try await runtime.recordToolUse(for: first.id)
        try await runtime.updateConfiguration(first.id, name: "Renamed", permissions: first.permissions)
        let other = try await runtime.exportMCPConfiguration(for: second.id, format: .codex, executable: path)
        #expect(other.hasPrefix("[mcp_servers.codex]"))
        #expect(!other.contains(token))
        for format in BridgeMCPExportFormat.allCases {
            let exported = try await runtime.exportMCPConfiguration(for: first.id, format: format, executable: path)
            #expect(exported.contains(token))
        }
        let alternate = try await runtime.exportMCPConfiguration(for: first.id, format: .openCode, executable: path)
        let openCode = try JSONDecoder().decode(BridgeJSON.self, from: Data(alternate.utf8))
        #expect(openCode["mcp"]["servers"]["codex"]["environment"]["CODEXBAR_BRIDGE_TOKEN"] == .string(token))
        try await runtime.setEnabled(false)
        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await reopened.load()
        #expect(await reopened.configurations.map(\.permissions) == [BridgePermissions(), permissions])
        #expect(await reopened.configurations.map(\.usageCount) == [2, 0])
        #expect(try await reopened.exportMCPConfiguration(for: first.id, format: .genericJSON, executable: path) == original)
        try await reopened.deleteConfiguration(first.id)
        await #expect(throws: BridgeFailure.self) { try await reopened.exportMCPConfiguration(for: first.id, format: .genericJSON) }
        #expect(try await reopened.exportMCPConfiguration(for: second.id, format: .codex, executable: path) == other)
    }

    @Test(.tags(.integration), arguments: [false, true])
    func deletingAConfigurationDeclinesItsApprovalAndPreservesOtherConfigurations(disconnectBeforeCompletion: Bool) async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let token = try await runtime.createConfigurationToken(name: "first", writable: true)
        let configurationID = try runtime.configurationID(forToken: token)
        let otherConfigurationID = try await runtime.createConfiguration(name: "second").id
        let args: BridgeJSON = ["operationId": "same", "prompt": "work", "project": .string(directory.path)]
        let first = try await runtime.execute(.start, args: args, configurationID: configurationID)
        let second = try await runtime.execute(.start, args: args, configurationID: otherConfigurationID)
        try await runtime.receive(["method": "item/commandExecution/requestApproval", "id": .integer(44), "params": [
            "threadId": first["taskId"], "turnId": first["turnId"], "itemId": "item", "command": "pwd", "cwd": .string(directory.path)
        ]])
        let snapshot = try await runtime.execute(.wait, args: ["taskId": first["taskId"]], configurationID: configurationID)
        let command = try BridgeTool.respond.parse(snapshot["nextAction"]["arguments"])
        let rejected = await #expect(throws: BridgeFailure.self) {
            try await runtime.execute(command, configurationID: configurationID) { _ in
                try await runtime.deleteConfiguration(configurationID)
                return ["action": "accept", "content": ["decision": "allow_once"]]
            }
        }
        #expect(rejected?.code == "unauthorized")
        #expect(upstream.answer == ["id": .integer(44), "result": ["decision": "decline"]])
        #expect(throws: BridgeFailure.self) { try runtime.configurationID(forToken: token) }
        #expect(try await runtime.execute(.start, args: args, configurationID: otherConfigurationID) == second)
        try await runtime.receive(["method": "turn/completed", "params": ["threadId": first["taskId"], "turn": ["id": "older-turn", "status": "completed"]]])
        #expect(upstream.subscriptionsRemoved.isEmpty)
        try await runtime.receive(["method": "item/permissions/requestApproval", "id": .integer(45), "params": [
            "threadId": first["taskId"], "turnId": first["turnId"], "permissions": ["network": ["enabled": .bool(true)]]
        ]])
        #expect(upstream.answer == ["id": .integer(45), "result": ["permissions": [:], "scope": "turn"]])
        if disconnectBeforeCompletion {
            await runtime.disconnect()
            let previousReads = upstream.turnPageReads
            let recovered = try await waitForCondition(timeout: .seconds(5), pollInterval: .milliseconds(25)) {
                _ = await runtime.tick()
                return upstream.turnPageReads > previousReads
            }
            try #require(recovered)
            let surviving = try await runtime.execute(.list, args: [:], configurationID: otherConfigurationID)
            #expect(surviving["tasks"].elements.first?["status"] == "completed")
            let previousAnswer = upstream.answer
            try await runtime.receive(["method": "item/permissions/requestApproval", "id": .integer(46), "params": [
                "threadId": first["taskId"], "turnId": first["turnId"], "permissions": ["network": ["enabled": .bool(true)]]
            ]])
            #expect(upstream.answer == previousAnswer)
        }
        try await runtime.receive(["method": "turn/completed", "params": ["threadId": first["taskId"], "turn": ["id": first["turnId"], "status": "completed"]]])
        let expectedUnsubscriptions = try disconnectBeforeCompletion ? [] : [first.required("taskId")]
        #expect(upstream.subscriptionsRemoved == expectedUnsubscriptions)
        let store = try BridgeStore(directory: directory)
        #expect(try store.task(first.required("taskId")) == nil)
        #expect(try store.task(second.required("taskId"))?.configurationID == otherConfigurationID)
        #expect(try store.db.number("SELECT count(*) FROM operations") == 1)
    }

    @Test(.tags(.integration))
    func simultaneousReadersReceiveEachEvent() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "reader", permissions: .init(writable: true)).id
        let start = try await runtime.execute(.start, args: ["operationId": "readers", "prompt": "progress", "project": .string(directory.path)], configurationID: configurationID)
        var cursor = start["cursor"]
        var latencies: [Duration] = []
        for index in 0 ..< 101 {
            let args: BridgeJSON = ["taskId": start["taskId"], "after": cursor]
            async let first = runtime.execute(.wait, args: args, configurationID: configurationID)
            async let second = runtime.execute(.wait, args: args, configurationID: configurationID)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await runtime.waiters.count < 2 {
                guard ContinuousClock.now < deadline else { throw BridgeFailure("waiters_not_registered") }
                await Task.yield()
            }
            let sent = ContinuousClock.now
            try await runtime.receive(["method": "item/started", "params": [
                "threadId": start["taskId"], "turnId": start["turnId"], "item": ["type": "commandExecution", "id": .string(String(index))]
            ]])
            let results = try await (first, second)
            if index > 0 {
                latencies.append(sent.duration(to: .now))
            }
            #expect(results.0["events"] == results.1["events"])
            #expect(results.0["events"].elements.first?["itemId"] == .string(String(index)))
            cursor = results.0["nextCursor"]
        }
        let p95 = latencies.sorted()[94]
        print("Bridge wait p95 for 100 events with two readers: \(p95)")
        #expect(p95 < .milliseconds(500))
        await runtime.shutdown()
    }

    @Test(.tags(.integration))
    func lostTurnResponseSurvivesRestartWithoutResubmission() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture(losesTurnResponse: true)
        let original = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await original.setEnabled(true)
        let configurationID = try await original.createConfiguration(name: "retry", permissions: .init(writable: true)).id
        let args: BridgeJSON = ["operationId": "retry", "prompt": "run once", "project": .string(directory.path)]
        let lost = await #expect(throws: BridgeFailure.self) { try await original.execute(.start, args: args, configurationID: configurationID) }
        #expect(lost?.code == "outcome_unknown")
        await original.shutdown()
        let restored = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await restored.load()
        let retry = await #expect(throws: BridgeFailure.self) { try await restored.execute(.start, args: args, configurationID: configurationID) }
        #expect(retry?.code == "outcome_unknown")
        #expect(retry?.detail == "thread-1")
        #expect(upstream.starts == 1)
    }

    @Test(.tags(.integration))
    func clientChoosesAnAbsoluteProjectForEachTask() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first")
        let component = String(repeating: "p", count: 160)
        let second = directory.appendingPathComponent(component).appendingPathComponent(component).appendingPathComponent(component).appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let token = try await runtime.createConfigurationToken(name: "client")
        let configurationID = try runtime.configurationID(forToken: token)
        #expect(token.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil)
        for folder in [first, second] {
            _ = try await runtime.execute(.start, args: ["project": .string(folder.path), "prompt": "review", "operationId": .string(folder.lastPathComponent)], configurationID: configurationID)
        }
        let file = directory.appendingPathComponent("file")
        try Data().write(to: file)
        for invalid in ["first", first.path + "\0", file.path, directory.appendingPathComponent("missing").path] {
            let failure = await #expect(throws: BridgeFailure.self) {
                try await runtime.execute(.start, args: ["project": .string(invalid), "prompt": "review", "operationId": "invalid"], configurationID: configurationID)
            }
            #expect(failure?.code == "project_required")
        }
        #expect(upstream.starts == 2)
        let filtered = try await runtime.execute(.list, args: ["project": .string(second.path)], configurationID: configurationID)
        #expect(filtered["tasks"].elements.map { $0["project"] } == [.string(CodexPaths.canonicalPath(second.path))])
        let reloaded = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await reloaded.load()
        #expect(try reloaded.configurationID(forToken: token) == configurationID)
        let listed = try await reloaded.execute(.list, args: [:], configurationID: configurationID)
        #expect(listed["tasks"].elements.count == 2)
        try await reloaded.deleteConfiguration(configurationID)
        let revoked = #expect(throws: BridgeFailure.self) { try reloaded.configurationID(forToken: token) }
        #expect(revoked?.code == "unauthorized")
    }

    @Test(.tags(.integration), arguments: [false, true])
    func asyncQuestionRequiresMatchingConfigurationAndReturnsToTheThread(afterCompletion: Bool) async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "reader").id
        let otherConfigurationID = try await runtime.createConfiguration(name: "other").id
        let start = try await runtime.execute(.start, args: ["project": .string(directory.path), "prompt": "ask", "operationId": "create"], configurationID: configurationID)
        let task = start["taskId"]
        let turn = start["turnId"]
        let item: BridgeJSON = [
            "type": "agentMessage", "id": "call_test", "phase": "final_answer", "delivery": "async", "text": "Pick one",
            "questions": [["title": "Pick one", "options": ["A", "B"]], ["title": "Why?"]]
        ]
        let completed: BridgeJSON = ["method": "item/completed", "params": ["threadId": task, "turnId": turn, "item": item]]
        try await runtime.receive(completed)
        try await runtime.receive(completed)
        if afterCompletion {
            let second: BridgeJSON = ["type": "agentMessage", "id": "call_other", "delivery": "async", "questions": [["title": "Another?"]]]
            try await runtime.receive(["method": "item/completed", "params": ["threadId": task, "turnId": turn, "item": second]])
            try await runtime.receive(["method": "turn/completed", "params": ["threadId": task, "turn": ["id": turn, "status": "completed", "items": [item]]]])
        }
        let snapshot = try await runtime.execute(.wait, args: ["taskId": task], configurationID: configurationID)
        #expect(snapshot["status"] == (afterCompletion ? "completed" : "running"))
        #expect(await runtime.tick() == (afterCompletion ? 0.25 : 0.005))
        #expect(snapshot["pendingRequests"].elements.count == (afterCompletion ? 2 : 1))
        let question = try #require(snapshot["pendingRequests"].elements.first { $0["summary"].text?.hasPrefix("Pick one") == true })
        let args: BridgeJSON = ["taskId": task, "requestId": question["requestId"]]
        let answer: BridgeJSON = ["action": "accept", "content": ["q1": "B", "q2": "my reason"]]
        await #expect(throws: BridgeFailure.self) { try await runtime.respond(args, configurationID: otherConfigurationID, response: answer) }
        await #expect(throws: BridgeFailure.self) { try await runtime.respond(args, configurationID: configurationID, response: ["action": "accept", "content": [:]]) }
        let result = try await runtime.execute(BridgeTool.respond.parse(args), configurationID: configurationID) { form in
            let fields = form["requestedSchema"]["properties"]
            #expect(form["message"] == "")
            #expect(fields["q1"]["title"] == "Pick one" && fields["q1"]["enum"] == ["A", "B"])
            #expect(fields["q1_other"] == ["type": "string", "title": ""])
            #expect(fields["q2"]["title"] == "Why?")
            return answer
        }
        #expect(result["status"] == "submitted")
        #expect(result["taskId"] == task)
        #expect((result["turnId"] != turn) == afterCompletion)
        #expect(upstream.answer?["method"] == (afterCompletion ? "turn/start" : "turn/steer"))
        let input = try #require(upstream.answer?["params"]["input"].elements.first?["text"].text)
        let body = try #require(input.split(separator: "\n").dropFirst().first)
        let answers = try JSONDecoder().decode(BridgeJSON.self, from: Data(body.utf8)).elements
        #expect(answers.map { $0["answer"] } == ["B", "my reason"])
        #expect(answers.first?["questionItemId"].text == #"["request_user_input_async","call_test",0]"#)
        await #expect(throws: BridgeFailure.self) { try await runtime.respond(args, configurationID: configurationID, response: answer) }
        if afterCompletion {
            let stored = try BridgeStore(directory: directory)
            let taskID = try #require(task.text)
            #expect(try stored.task(taskID)?.latestTurnID == result["turnId"].text)
            let next = try await runtime.execute(.wait, args: ["taskId": task, "after": result["cursor"]], configurationID: configurationID)
            #expect(next["pendingRequests"].elements.map { $0["summary"] } == ["Another?"])
            let dismissed = try await runtime.respond(next["nextAction"]["arguments"], configurationID: configurationID, response: ["action": "cancel"])
            #expect(dismissed["status"] == "dismissed")
        }
        try await runtime.receive(completed)
        let replay = try await runtime.execute(.wait, args: ["taskId": task, "turnId": turn], configurationID: configurationID)
        #expect(replay["pendingRequests"] == [])
    }

    @Test(.tags(.integration))
    func pendingQuestionSurvivesProgressEviction() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "reader").id
        func start(_ number: Int) async throws -> BridgeJSON {
            try await runtime.execute(.start, args: ["project": .string(directory.path), "prompt": "work", "operationId": .string(String(number))], configurationID: configurationID)
        }
        let first = try await start(1)
        let question: BridgeJSON = ["method": "item/completed", "params": [
            "threadId": first["taskId"], "turnId": first["turnId"], "item": [
                "type": "agentMessage", "id": "question", "delivery": "async", "questions": [["title": "Which file?"]]
            ]
        ]]
        try await runtime.receive(question)
        let args: BridgeJSON = ["taskId": first["taskId"], "after": first["cursor"], "timeoutSeconds": .integer(0)]
        let before = try await runtime.execute(.wait, args: args, configurationID: configurationID)
        let answer = before["nextAction"]["arguments"]
        for number in 2 ... 65 {
            _ = try await start(number)
        }
        let after = try await runtime.execute(.wait, args: args, configurationID: configurationID)
        #expect(after["warning"] == "cursor_expired")
        #expect(after["pendingRequests"] == before["pendingRequests"])
        try await runtime.receive(question)
        #expect(try await runtime.execute(.wait, args: args, configurationID: configurationID)["pendingRequests"] == before["pendingRequests"])
        #expect(try await runtime.respond(answer, configurationID: configurationID, response: ["action": "accept", "content": ["q1": "README"]])["status"] == "submitted")
        try await runtime.receive(question)
        #expect(try await runtime.execute(.wait, args: args, configurationID: configurationID)["pendingRequests"] == [])
    }

    @Test func operationIDLimitIsCheckedAtTheToolEntry() throws {
        func args(_ count: Int) -> BridgeJSON {
            ["operationId": .string(String(repeating: "é", count: count)), "prompt": "test", "project": "/tmp"]
        }
        _ = try BridgeTool.start.parse(args(256))
        #expect(throws: BridgeFailure.self) { try BridgeTool.start.parse(args(257)) }
    }

    @Test(.tags(.integration))
    func waitTimeoutRuleIsVisibleInToolDiscoveryAndInErrors() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        try await runtime.setEnabled(true)
        let token = try await runtime.createConfigurationToken(name: "reader")
        let output = BridgeFixtureOutput()
        let peer = BridgePeer(runtime: runtime, output: { try await output.write($0) })
        func send(_ message: BridgeJSON) async throws {
            try await peer.accept(message.data())
        }
        try await send(["credential": .string(token)])
        try await send(["jsonrpc": "2.0", "id": .integer(1), "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
        try await send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try await send(["jsonrpc": "2.0", "id": .integer(2), "method": "tools/list"])
        let discovery = try await output.wait { $0["id"] == .integer(2) }
        #expect(await runtime.configurations.first?.usageCount == 0)
        var updates = try await runtime.configurationUpdates().makeAsyncIterator()
        let tools = discovery["result"]["tools"].elements
        let wait = try #require(tools.first { $0["name"] == "codex_wait" })
        let timeout = wait["inputSchema"]["properties"]["timeoutSeconds"]
        #expect(timeout["type"] == "integer" && timeout["minimum"] == .integer(0) && timeout["maximum"] == .integer(30) && timeout["default"] == .integer(30))
        let help = try #require(timeout["description"].text)
        #expect(help.contains("integer from 0 to 30") && help.contains("Defaults to 30"))

        try await send(["jsonrpc": "2.0", "id": .integer(3), "method": "tools/call", "params": [
            "name": "codex_wait", "arguments": ["taskId": "test", "timeoutSeconds": .integer(35)]
        ]])
        let reply = try await output.wait { $0["id"] == .integer(3) }
        let error = reply["result"]["structuredContent"]
        #expect(error["error"] == "invalid_argument" && error["message"].text?.contains("integer from 0 to 30") == true)
        #expect(await runtime.configurations.first?.usageCount == 1)
        try await send(["jsonrpc": "2.0", "id": .integer(4), "method": "tools/call", "params": ["name": "codex_list", "arguments": [:]]])
        let listed = try await output.wait { $0["id"] == .integer(4) }
        #expect(listed["result"]["isError"] == .bool(false))
        #expect(await updates.next()?.first?.usageCount == 2)
        await peer.close()
    }

    @Test func asyncQuestionsUseStructuredMetadataAndPreserveCustomAnswers() throws {
        let question: BridgeJSON = ["title": "Pick", "options": ["One", "Two"]]
        #expect(BridgeAsyncQuestions(["type": "agentMessage", "id": "1", "text": "Pick?", "questions": [question]]) == nil)
        #expect(BridgeAsyncQuestions(["type": "agentMessage", "id": "1", "delivery": "async", "questions": []]) == nil)
        let group = try #require(BridgeAsyncQuestions(["type": "agentMessage", "id": "1", "delivery": "async", "questions": [question]]))
        let form = try #require(BridgePendingRequest(id: "r", source: .message(group, origin: "u"), task: "t", turn: "u").form())
        #expect(form["message"] == "Pick")
        #expect(form["requestedSchema"]["properties"]["q1"]["title"] == "")
        #expect(try group.reply(["action": "cancel"]) == nil)
        #expect(try group.reply(["action": "decline"]) == nil)
        #expect(throws: BridgeFailure.self) { try group.reply(["action": "accept", "content": ["q1": "unknown"]]) }
        #expect(try group.reply(["action": "accept", "content": ["q1": "One", "q1_other": "Custom"]])?.contains(#""answer":"Custom""#) == true)
    }

    @Test func interactiveRequestsPresentOnlyOriginalContent() throws {
        func pending(_ method: BridgeRPCRequest.Method, _ params: BridgeJSON) -> BridgePendingRequest {
            let rpc = BridgeRPCRequest(id: .integer(1), method: method, params: params, permissions: .init(writable: true), project: "/fixture", changedPaths: nil)
            return BridgePendingRequest(id: "r", source: .rpc(rpc), task: "t", turn: "u")
        }
        let schema: BridgeJSON = ["type": "object", "properties": ["answer": ["type": "string", "title": "Answer"]]]
        for (request, text) in [
            (pending(.command, ["cwd": "/fixture", "command": "pwd", "reason": "  "]), "pwd"),
            (pending(.fileChange, ["grantRoot": "/fixture", "reason": "Apply this change?"]), "Apply this change?"),
            (pending(.fileChange, ["grantRoot": "/fixture"]), "/fixture"),
            (pending(.permissions, ["cwd": "/fixture", "permissions": ["network": ["enabled": .bool(true)]], "reason": "Connect?"]), "Connect?"),
            (pending(.permissions, ["cwd": "/fixture", "permissions": ["network": ["enabled": .bool(true)]]]), #"{"network":{"enabled":true}}"#),
            (pending(.elicitation, ["mode": "form", "message": "Pick a file", "requestedSchema": schema]), "Pick a file")
        ] {
            #expect(request.info["summary"].text == text)
            #expect(try #require(request.form())["message"].text == text)
        }
        let question: BridgeJSON = ["id": "one", "question": "Which file?"]
        let other: BridgeJSON = ["id": "two", "question": "Which branch?"]
        let single = try #require(pending(.userInput, ["questions": [question]]).form())
        #expect(single["message"] == "Which file?" && single["requestedSchema"]["properties"]["one"]["title"] == "")
        let multiple = try #require(pending(.userInput, ["questions": [question, other]]).form())
        #expect(multiple["message"] == "")
        #expect(multiple["requestedSchema"]["properties"]["one"]["title"] == "Which file?")
        #expect(multiple["requestedSchema"]["properties"]["two"]["title"] == "Which branch?")
    }

    @Test(.tags(.integration))
    func editingAConfigurationPreservesItsTokenAndRejectsPendingPermissions() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let token = try await runtime.createConfigurationToken(name: "writer", writable: true)
        let configurationID = try runtime.configurationID(forToken: token)
        let project = BridgeJSON.string(CodexPaths.canonicalPath(directory.path))
        let started = try await runtime.execute(.start, args: ["project": project, "prompt": "edit", "operationId": "one"], configurationID: configurationID)
        let task = started["taskId"]
        try await runtime.receive(["method": "item/commandExecution/requestApproval", "id": .integer(91), "params": [
            "threadId": task, "turnId": started["turnId"], "itemId": "cmd", "command": "pwd", "cwd": project
        ]])
        let waiting = try await runtime.execute(.wait, args: ["taskId": task], configurationID: configurationID)
        let pending = try #require(waiting["pendingRequests"].elements.first)
        let restricted = BridgePermissions(network: .deny, approval: .deny)
        try await runtime.updateConfiguration(configurationID, name: "  reader  ", permissions: restricted)
        #expect(upstream.answer == ["id": .integer(91), "result": ["decision": "decline"]])
        let expired = await #expect(throws: BridgeFailure.self) {
            try await runtime.respond(
                ["taskId": task, "requestId": pending["requestId"]],
                configurationID: configurationID,
                response: ["action": "accept", "content": ["decision": "allow_once"]]
            )
        }
        #expect(expired?.code == "request_closed")
        let steer = try await runtime.execute(.reply, args: ["taskId": task, "turnId": started["turnId"], "message": "continue", "operationId": "steer"], configurationID: configurationID)
        #expect(steer["turnId"] == started["turnId"] && upstream.answer?["method"] == "turn/steer")
        #expect(try runtime.configurationID(forToken: token) == configurationID)
        #expect(try await runtime.execute(.list, args: [:], configurationID: configurationID)["tasks"].elements.first?["taskId"] == task)
        try await runtime.setEnabled(false)
        try await runtime.updateConfiguration(configurationID, name: "offline", permissions: restricted)
        await #expect(throws: BridgeFailure.self) { try await runtime.updateConfiguration(configurationID, name: " ", permissions: restricted) }
        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await reopened.load()
        let edited = try #require(await reopened.configurations.first)
        #expect(edited.id == configurationID && edited.name == "offline" && edited.permissions == restricted)
    }

    @Test func boundedEventPagesAndUnicodeResult() throws {
        var buffer = BridgeTurnEvents(task: "t")
        for index in 0 ..< 220 {
            buffer.append(["n": .integer(index)])
        }
        var cursor = BridgeCursor(epoch: buffer.epoch, task: "t", turn: "u", sequence: 28)
        #expect(buffer.events.count == BridgeTurnEvents.capacity)
        #expect(buffer.page(from: &cursor).0.count == 16)
        let expected = String(repeating: "完成", count: 4000)
        buffer.captureAnswer(["type": "agentMessage", "text": .string(expected)])
        var text = ""
        var hasMore = true
        while hasMore {
            let page = buffer.result(from: &cursor)
            text += try #require(page.0.text)
            hasMore = page.1
        }
        #expect(text == expected)
    }

    @Test(.tags(.integration))
    func restartedRuntimeReadsPastTurnsWithoutChangingLatest() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "reader").id
        let args: BridgeJSON = ["project": .string(directory.path), "prompt": "first", "operationId": "start"]
        let first = try await runtime.execute(.start, args: args, configurationID: configurationID)
        let task = first["taskId"]
        let firstTurnID = try #require(first["turnId"].text)
        upstream.setHistory(firstTurnID, items: [["type": "agentMessage", "phase": "final_answer", "text": "First answer"]])
        let last = try await runtime.execute(.reply, args: ["taskId": task, "message": "again", "operationId": "follow"], configurationID: configurationID)
        let restarted = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await restarted.load()
        #expect(try await restarted.execute(.start, args: args, configurationID: configurationID) == first)
        #expect(upstream.starts == 1)
        let latest = try await restarted.execute(.list, args: [:], configurationID: configurationID)["tasks"].elements.first
        let database = try BridgeSQLite(url: BridgeStore.databaseURL(in: directory))
        try database.run("ALTER TABLE questions RENAME TO unavailable_questions")
        let past = try await restarted.execute(.wait, args: ["taskId": task, "after": first["cursor"]], configurationID: configurationID)
        #expect(past["turnId"] == first["turnId"])
        #expect(past["status"] == "completed")
        #expect(past["freshness"] == "current")
        #expect(past["result"] == "First answer")
        #expect(past["warning"] == "cursor_expired")
        #expect(try await restarted.execute(.interrupt, args: ["taskId": task, "turnId": first["turnId"]], configurationID: configurationID)["status"] == "completed")
        let missing = await #expect(throws: BridgeFailure.self) { try await restarted.execute(.wait, args: ["taskId": task, "turnId": "missing"], configurationID: configurationID) }
        #expect(missing?.code == "turn_not_found")
        #expect(latest?["turnId"] == last["turnId"])
        #expect(try await restarted.execute(.list, args: [:], configurationID: configurationID)["tasks"].elements.first == latest)
    }

    @Test(.tags(.integration))
    func waitRecoversTerminalResultsAndQuestionsAcrossRestarts() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "review").id
        let started = try await runtime.execute(.start, args: ["project": .string(directory.path), "prompt": "ask", "operationId": "one"], configurationID: configurationID)
        let task = started["taskId"], turn = started["turnId"]
        let turnID = try #require(turn.text)
        let question: BridgeJSON = ["type": "agentMessage", "id": "m1", "delivery": "async", "questions": [["title": "First?"]]]
        let carried: BridgeJSON = ["type": "agentMessage", "id": "m2", "delivery": "async", "questions": [["title": "Second?"]]]
        let handled: BridgeJSON = ["type": "agentMessage", "id": "m3", "delivery": "async", "questions": [["title": "Already answered?"]]]
        let answered = try #require(try BridgeAsyncQuestions(handled)?.reply(["action": "accept", "content": ["q1": "yes"]]))
        let reply: BridgeJSON = ["type": "userMessage", "id": "reply", "content": [["type": "text", "text": .string(answered)]]]
        let result: BridgeJSON = ["type": "agentMessage", "id": "answer", "text": "Done"]
        let commentary: BridgeJSON = ["type": "agentMessage", "phase": "commentary", "text": "Working"]
        upstream.setHistory(turnID, items: [handled, reply, question, carried, result] + Array(repeating: commentary, count: 34))
        try await runtime.receive(["method": "turn/completed", "params": ["threadId": task, "turn": [
            "id": turn, "status": "completed", "items": [question, carried, result, commentary]
        ]]])
        let args: BridgeJSON = ["taskId": task, "timeoutSeconds": .integer(0)]
        let live = try await runtime.execute(.wait, args: args, configurationID: configurationID)
        #expect(live["nextAction"] == .null && live["hasMore"] == .bool(true))
        #expect(try await runtime.execute(.wait, args: args, configurationID: configurationID)["result"] == "Done")
        await runtime.shutdown()

        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await reopened.load()
        let partial = try await reopened.execute(BridgeTool.wait.parse(args), configurationID: configurationID)
        #expect(partial["hasMore"] == .bool(true) && partial["freshness"] == "reconciling")
        let remaining: BridgeJSON = ["taskId": task, "after": partial["nextCursor"], "timeoutSeconds": .integer(0)]
        let withoutForms = try await reopened.execute(BridgeTool.wait.parse(remaining), configurationID: configurationID)
        #expect(withoutForms["nextAction"] == .null && withoutForms["formRequired"].text != nil)
        #expect(withoutForms["result"] == "Done")
        let pending = withoutForms["pendingRequests"].elements
        #expect(Set(pending.compactMap { $0["summary"].text }) == ["First?", "Second?"])
        let first = try #require(pending.first { $0["summary"] == "First?" })
        let response = try await reopened.respond(["taskId": task, "requestId": first["requestId"]], configurationID: configurationID, response: ["action": "accept", "content": ["q1": "yes"]])
        #expect(response["turnId"] != turn)
        await reopened.shutdown()

        let continued = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await continued.load()
        let moving = try await continued.execute(.wait, args: args, configurationID: configurationID)
        let rest: BridgeJSON = ["taskId": task, "after": moving["nextCursor"], "timeoutSeconds": .integer(0)]
        let next = try await continued.execute(.wait, args: rest, configurationID: configurationID)
        #expect(next["pendingRequests"].elements.map { $0["summary"] } == ["Second?"])
        _ = try await continued.respond(next["nextAction"]["arguments"], configurationID: configurationID, response: ["action": "cancel"])
        await continued.shutdown()
        let dismissed = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await dismissed.load()
        #expect(try await dismissed.execute(.wait, args: args, configurationID: configurationID)["pendingRequests"] == [])
    }

    @Test(.tags(.integration))
    func failedSnapshotKeepsItsOwnReasonAcrossRestart() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "check").id
        let started = try await runtime.execute(.start, args: ["project": .string(directory.path), "prompt": "test", "operationId": "one"], configurationID: configurationID)
        let task = started["taskId"], turn = started["turnId"]
        let args: BridgeJSON = ["taskId": task, "turnId": turn]
        try upstream.setHistory(#require(turn.text), items: [], failure: "Model rejected the request")
        let question: BridgeJSON = ["type": "agentMessage", "id": "m1", "delivery": "async", "questions": [["title": "Retry?"]]]
        try await runtime.receive(["method": "turn/completed", "params": ["threadId": task, "turn": [
            "id": turn, "status": "failed", "error": ["message": "Model rejected the request"], "items": [question]
        ]]])
        let failed = try await runtime.execute(.wait, args: args, configurationID: configurationID)
        #expect(failed["failureMessage"] == "Model rejected the request")
        #expect(failed["pendingRequests"] == [])
        _ = try await runtime.execute(.reply, args: ["taskId": task, "message": "again", "operationId": "two"], configurationID: configurationID)
        await runtime.shutdown()
        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await reopened.load()
        let pagesBeforeWait = upstream.turnPageReads
        let result = try await reopened.execute(.wait, args: args, configurationID: configurationID)
        #expect(result["status"] == "failed" && result["failureMessage"] == "Model rejected the request")
        #expect(result["events"] == [])
        #expect(upstream.turnPageReads - pagesBeforeWait == 2)
    }

    @Test(.tags(.integration), arguments: [false, true])
    func waitDistinguishesMissingAndOversizedFinalAnswers(oversized: Bool) async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await runtime.setEnabled(true)
        let configurationID = try await runtime.createConfiguration(name: "reader").id
        let started = try await runtime.execute(.start, args: ["project": .string(directory.path), "prompt": "check", "operationId": "start"], configurationID: configurationID)
        let task = started["taskId"], turn = started["turnId"]
        let turnID = try #require(turn.text)
        let fallback: BridgeJSON = ["type": "agentMessage", "text": "fallback"]
        let items: [BridgeJSON] = oversized ? [
            fallback, ["type": "agentMessage", "phase": "final_answer", "text": .string(String(repeating: "a", count: 2 * 1024 * 1024 + 1))], fallback
        ] : []
        let args: BridgeJSON = ["taskId": task, "turnId": turn, "timeoutSeconds": .integer(0)]
        func verify(_ runtime: BridgeRuntime) async throws {
            let snapshot = try await runtime.execute(.wait, args: args, configurationID: configurationID)
            #expect(snapshot["status"] == "completed")
            #expect(snapshot["result"] == .null && snapshot["resultAvailable"] == .bool(false))
            #expect(snapshot["resultWarning"] == (oversized ? "result_too_large" : .null))
            #expect(snapshot["freshness"] == "current" && snapshot["hasMore"] == .bool(false))
        }

        upstream.setHistory(turnID, items: items)
        try await runtime.receive(["method": "turn/completed", "params": ["threadId": task, "turn": ["id": turn, "status": "completed", "items": .array(items)]]])
        try await verify(runtime)
        await runtime.shutdown()
        let reopened = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await reopened.load()
        try await verify(reopened)
        // 已经完整扫描过的轮次不应再次从历史选择候选答复
        upstream.setHistory(turnID, items: [fallback])
        try await verify(reopened)
    }

    @Test func answerSelectionPrefersExplicitFinalInEitherReadingOrder() {
        let old: BridgeJSON = ["type": "agentMessage", "text": "old"]
        let latest: BridgeJSON = ["type": "agentMessage", "text": "latest", "phase": .null]
        let explicit: BridgeJSON = ["type": "agentMessage", "phase": "final_answer", "text": "explicit"]
        for newestFirst in [false, true] {
            for (items, expected) in [([old, latest], "latest"), ([old, explicit, latest], "explicit")] {
                var buffer = BridgeTurnEvents(task: "t")
                for item in newestFirst ? Array(items.reversed()) : items {
                    buffer.captureAnswer(item, newestFirst: newestFirst)
                }
                #expect(buffer.answer?.text == expected)
            }
        }
    }

    @Test func structuredQuestionRetainsChoicesAndAllowsCustomText() throws {
        let question: BridgeJSON = ["id": "file", "question": "Which file?", "isOther": .bool(true), "options": [["label": "README"], ["label": "CHANGELOG"]]]
        let other: BridgeJSON = ["id": "file_other", "question": "Why?"]
        let rpc = BridgeRPCRequest(id: .integer(1), method: .userInput, params: ["questions": [question, other]], permissions: .init(), project: "/project", changedPaths: nil)
        guard case let .input(schema) = rpc.form else { Issue.record("missing form")
            return
        }
        #expect(schema["properties"]["file"]["enum"] == ["README", "CHANGELOG"])
        #expect(schema["required"] == ["file_other"])
        for (key, answer) in [("file", "CHANGELOG"), ("file_other_other", "LICENSE")] {
            let values: BridgeJSON = .object([key: .string(answer), "file_other": "reason"])
            #expect(try rpc.answer(["action": "accept", "content": values])["answers"]["file"] == ["answers": [.string(answer)]])
        }
    }

    @Test func loggingProtectsNestedSubagentsDuringAndAfterStartup() {
        let privacy = BridgeLogPrivacy()
        let grandchild = ["id": "grandchild", "source": ["subAgent": ["threadSpawn": ["parent_thread_id": "child"]]]] as [String: Any]
        let child = ["id": "child", "source": ["subagent": ["thread_spawn": ["parent_thread_id": "root"]]]] as [String: Any]
        privacy.beginRestoration()
        #expect(privacy.trackThreadsAndCheckRedaction(["result": ["data": [grandchild, child]]]))
        #expect(privacy.trackThreadsAndCheckRedaction(["params": ["threadId": "root", "text": "synthetic message"]]))
        privacy.register("root")
        privacy.finishRestoration()
        #expect(privacy.trackThreadsAndCheckRedaction(["params": ["threadId": "grandchild", "text": "synthetic message"]]))
        #expect(!privacy.trackThreadsAndCheckRedaction(["params": ["threadId": "unrelated"]]))

        let live = BridgeLogPrivacy()
        #expect(!live.trackThreadsAndCheckRedaction(["result": ["data": [grandchild]]]))
        #expect(!live.trackThreadsAndCheckRedaction(["params": ["thread": child]]))
        #expect(live.trackThreadsAndCheckRedaction(["params": ["thread": ["id": "root", "threadSource": "codexbar_bridge"]]]))
        #expect(live.trackThreadsAndCheckRedaction(["params": ["threadId": "grandchild"]]))
        #expect(!live.trackThreadsAndCheckRedaction(["params": ["threadId": "unrelated"]]))
    }

    @Test func fullPrivacyRegistryProtectsAllThreadContentAfterTheLimit() {
        let privacy = BridgeLogPrivacy()
        for number in 0 ..< 8192 {
            privacy.register("thread-" + String(number))
        }
        let unknown = ["params": ["threadId": "other"]]
        privacy.register("thread-8191")
        #expect(!privacy.trackThreadsAndCheckRedaction(unknown))
        privacy.register("one-more-thread")
        #expect(privacy.trackThreadsAndCheckRedaction(unknown))
        #expect(!privacy.trackThreadsAndCheckRedaction(["method": "account/updated", "params": [:]]))
    }

    @Test func unrelatedSubagentsDoNotHideOtherThreadsWhenThePendingTableFills() {
        let privacy = BridgeLogPrivacy()
        let entries = (0 ... 8192).map { ["id": "child-" + String($0), "parentThreadId": "unrelated"] }
        #expect(!privacy.trackThreadsAndCheckRedaction(["result": ["data": entries]]))
        privacy.register("bridge")
        #expect(privacy.trackThreadsAndCheckRedaction(["params": ["thread": ["id": "bridge-child", "parentThreadId": "bridge"]]]))
        #expect(!privacy.trackThreadsAndCheckRedaction(["params": ["threadId": "unrelated"]]))
    }

    @Test func loggingRecognizesBridgeThreadAndApprovalArgumentsAreClosed() throws {
        let privacy = BridgeLogPrivacy()
        #expect(!privacy.trackThreadsAndCheckRedaction(["params": ["threadId": "other"]]))
        #expect(privacy.trackThreadsAndCheckRedaction(["result": ["thread": ["threadSource": "codexbar_bridge", "id": "one"]]]))
        #expect(privacy.trackThreadsAndCheckRedaction(["params": ["threadId": "one", "command": "secret"]]))
        #expect(privacy.trackThreadsAndCheckRedaction(["result": ["data": []]], threadID: "one"))
        #expect(throws: BridgeFailure.self) { try BridgeTool.respond.parse(["taskId": "one", "requestId": "r", "decision": "allow_once"]) }
    }
}

actor BridgeFixtureOutput {
    var values: [BridgeJSON] = []
    func write(_ data: Data) throws {
        try values.append(JSONDecoder().decode(BridgeJSON.self, from: data))
    }

    func wait(_ predicate: @Sendable (BridgeJSON) -> Bool) async throws -> BridgeJSON {
        for _ in 0 ..< 200 {
            if let item = values.first(where: predicate) {
                return item
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw BridgeFailure("fixture_timeout")
    }
}
