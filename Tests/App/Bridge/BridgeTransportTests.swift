import Darwin
import Foundation
import os
import Testing

struct BridgeTransportTests {
    @Test func lineReaderDeliversCompleteLinesBeforeAnOversizedLine() throws {
        var reader = BridgeLineReader(limit: 4)
        var first = Data("\nab".utf8)
        #expect(try reader.nextLine(in: &first) == nil)
        var rest = Data("cd\n\nx\nabcde\n".utf8)
        #expect(try reader.nextLine(in: &rest) == Data("abcd\n".utf8))
        #expect(try reader.nextLine(in: &rest) == Data("x\n".utf8))
        let failure = #expect(throws: BridgeFailure.self) { try reader.nextLine(in: &rest) }
        #expect(failure?.code == "message_too_large")
    }

    @Test(.tags(.integration))
    func listenerStateReflectsStartupFailureAndRecovery() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let runtime = try preferences.makeBridgeRuntime(in: directory.url) { BridgeFixture() }
        try await runtime.setEnabled(true)
        let host = BridgeHost(runtime: runtime)
        let path = directory.url.appendingPathComponent("mcp.sock")
        try Data().write(to: path)
        var states = await host.listeningUpdates().makeAsyncIterator()
        let failure = await #expect(throws: BridgeFailure.self) { try await host.restore() }
        #expect(failure?.code == "unsafe_socket_path" && runtime.isEnabled)
        #expect(await states.next() == false)
        try FileManager.default.removeItem(at: path)
        try await host.restore()
        #expect(await states.next() == true)
        await host.stop()
        #expect(await states.next() == false)
    }

    @Test(.tags(.integration))
    func localSocketStreamsRequestsAndDisconnectsOnDisable() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        let token = try await runtime.createConfigurationToken(name: "reader")
        let host = BridgeHost(runtime: runtime)
        let endpoint = try BridgeEndpoint(in: directory)
        do {
            for _ in 0 ..< 2 {
                try await host.setEnabled(true)
                try await Self.verifySocket(endpoint, token: token, host: host)
            }
        } catch {
            await host.stop()
            throw error
        }
    }

    @concurrent
    private nonisolated static func verifySocket(_ endpoint: BridgeEndpoint, token: String, host: BridgeHost) async throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { Darwin.close(fd) }
        try #require(endpoint.withAddress { Darwin.connect(fd, $0, $1) } == 0)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
        var enabled: Int32 = 1
        try #require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0)
        let client = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let credential: BridgeJSON = ["credential": .string(token)]
        let request: BridgeJSON = ["jsonrpc": "2.0", "id": .integer(1), "method": "ping", "params": ["padding": .string(String(repeating: "x", count: 20000))]]
        try client.write(contentsOf: credential.data())
        try client.write(contentsOf: Data([10]) + request.data() + Data([10]))
        #expect(try readFrame(fd)?["bridge"] == "connected")
        let reply = try #require(try readFrame(fd))
        #expect(reply["id"] == .integer(1) && reply["result"] == [:])
        try await host.setEnabled(false)
        #expect(try readFrame(fd)?["bridge"] == "end")
        #expect(try readFrame(fd) == nil)
        #expect(!FileManager.default.fileExists(atPath: endpoint.path))
    }

    nonisolated static func readFrame(_ fd: Int32) throws -> BridgeJSON? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 256 * 1024 {
            let size = Darwin.read(fd, &byte, 1)
            if size == 0, data.isEmpty {
                return nil
            }
            guard size == 1 else { throw BridgeFailure("fixture_read_failed") }
            if byte == 10 {
                return try JSONDecoder().decode(BridgeJSON.self, from: data)
            }
            data.append(byte)
        }
        throw BridgeFailure("fixture_frame_too_large")
    }

    @Test(.tags(.integration))
    func stdioRestoresTheSameTaskAndDropsInterruptedApprovals() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = BridgeFixture()
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        let host = BridgeHost(runtime: runtime)
        try await host.setEnabled(true)
        let restored = try preferences.makeBridgeRuntime(in: directory, connect: { upstream })
        try await Self.verifyStdio(in: directory, host: host, restored: restored, upstream: upstream)
    }

    @concurrent
    private nonisolated static func verifyStdio(in directory: URL, host: BridgeHost, restored: BridgeRuntime, upstream: BridgeFixture) async throws {
        let runtime = host.runtime
        let token = try await runtime.createConfigurationToken(name: "reader", writable: true)
        let endpoint = try BridgeEndpoint(in: directory)
        for version in ["2024-11-05", "2025-03-26", "2025-06-18"] {
            let hello: BridgeJSON = ["credential": .string(token), "session": ["version": .string(version)], "initialized": .bool(true)]
            #expect(throws: BridgeIPC.EndSession.self) {
                try Darwin.close(BridgeIPC.connect(to: endpoint, hello: hello))
            }
        }
        var pair = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let fd = pair[0]
        defer { Darwin.close(fd) }
        let relayFD = pair[1]
        DispatchQueue.global().async {
            defer { Darwin.close(relayFD) }
            try? BridgeStdioRelay(endpoint: endpoint, token: token, input: relayFD, output: relayFD).run()
        }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        try #require(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
        var enabled: Int32 = 1
        try #require(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0)
        func send(_ message: BridgeJSON) throws {
            try BridgeIPC.write(message.data() + Data([10]), to: fd)
        }
        func call(_ id: Int, _ tool: String, _ arguments: BridgeJSON) throws {
            try send(["jsonrpc": "2.0", "id": .integer(id), "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]])
        }
        func receive() throws -> BridgeJSON {
            try #require(try Self.readFrame(fd))
        }
        try send(["jsonrpc": "2.0", "id": .integer(1), "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": ["elicitation": [:]]]])
        let handshake = try receive()
        #expect(handshake["session"] == .null && handshake["result"]["protocolVersion"] == "2025-11-25")
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try call(2, "codex_start", ["project": .string(directory.path), "prompt": "check", "operationId": "first"])
        let first = try receive()["result"]["structuredContent"]
        let task = try #require(first["taskId"].text)
        func openApproval(_ runtime: BridgeRuntime, turn: BridgeJSON, id: Int) async throws -> BridgeJSON {
            try await runtime.receive(["id": .integer(id), "method": "item/commandExecution/requestApproval", "params": [
                "threadId": .string(task), "turnId": turn, "itemId": "cmd", "command": "pwd", "cwd": .string(directory.path), "reason": "Check?"
            ]])
            try call(id, "codex_wait", ["taskId": .string(task)])
            let arguments = try receive()["result"]["structuredContent"]["nextAction"]["arguments"]
            try call(id + 1, "codex_respond", arguments)
            let form = try receive()
            try #require(form["method"] == "elicitation/create")
            let decision = form["params"]["requestedSchema"]["properties"]["decision"]
            #expect(decision["oneOf"] == [["const": "allow_once", "title": "Allow once"], ["const": "deny", "title": "Deny"]])
            return form["id"]
        }
        let stale = try await openApproval(runtime, turn: first["turnId"], id: 3)
        // 数字 4 的表单仍在等待, 同值的字符串可以独立取消和调用工具
        try send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": "4"]])
        try send(["jsonrpc": "2.0", "id": "4", "method": "tools/call", "params": ["name": "codex_list", "arguments": [:]]])
        let listed = try receive()
        try #require(listed["id"] == "4" && listed["result"]["isError"] == .bool(false))
        await host.stop()
        let cancelled = try receive()
        #expect(cancelled["method"] == "notifications/cancelled" && cancelled["params"]["requestId"] == stale)
        let disconnected = try receive()
        #expect(disconnected["id"] == .integer(4) && disconnected["error"]["message"].text?.contains("bridge_disconnected") == true)
        try call(5, "codex_list", [:])
        #expect(try receive()["error"]["message"].text?.contains("bridge_unavailable") == true)

        let replacement = BridgeHost(runtime: restored)
        try await replacement.restore()
        try call(6, "codex_reply", ["taskId": .string(task), "message": "continue", "operationId": "second"])
        let second = try receive()["result"]["structuredContent"]
        try #require(second["taskId"] == .string(task) && second["turnId"] != first["turnId"], "Follow-up response: \(second)")
        let current = try await openApproval(restored, turn: second["turnId"], id: 7)
        try send(["jsonrpc": "2.0", "id": stale, "result": ["action": "accept", "content": ["decision": "allow_once"]]])
        try send(["jsonrpc": "2.0", "id": current, "result": ["action": "decline"]])
        #expect(try receive()["result"]["structuredContent"]["status"] == "submitted")
        #expect(upstream.starts == 1 && upstream.answer == ["id": .integer(7), "result": ["decision": "decline"]])
        try await replacement.setEnabled(false)
        #expect(try Self.readFrame(fd) == nil)
    }

    @Test(.tags(.integration))
    func relayExitsWhenHostClosesWhileStandardOutputIsFull() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let runtime = try preferences.makeBridgeRuntime(in: directory.url) { BridgeFixture() }
        let host = BridgeHost(runtime: runtime)
        try await host.setEnabled(true)
        let token = try await runtime.createConfigurationToken(name: "reader")
        let endpoint = try BridgeEndpoint(in: directory.url)
        let input = Pipe(), output = Pipe()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let relay = Task.detached {
            defer { finished.withLock { $0 = true } }
            try? BridgeStdioRelay(endpoint: endpoint, token: token, input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor).run()
        }
        func send(_ message: BridgeJSON) throws {
            try input.fileHandleForWriting.write(contentsOf: message.data() + Data([10]))
        }
        do {
            try send(["jsonrpc": "2.0", "id": .integer(1), "method": "initialize", "params": ["protocolVersion": "2025-11-25"]])
            let read = output.fileHandleForReading.fileDescriptor
            var descriptor = pollfd(fd: read, events: Int16(POLLIN), revents: 0)
            try #require(poll(&descriptor, 1, 2500) == 1)
            try #require(try Self.readFrame(read)?["id"] == .integer(1))
            let write = output.fileHandleForWriting.fileDescriptor
            let flags = fcntl(write, F_GETFL)
            try #require(flags >= 0 && fcntl(write, F_SETFL, flags | O_NONBLOCK) == 0)
            let block = Data(repeating: 32, count: 4096)
            while block.withUnsafeBytes({ Darwin.write(write, $0.baseAddress, $0.count) }) > 0 {}
            var byte: UInt8 = 32
            while Darwin.write(write, &byte, 1) > 0 {}
            try #require(errno == EAGAIN)
            try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            try send(["jsonrpc": "2.0", "id": .integer(2), "method": "tools/call", "params": ["name": "codex_list"]])
            let accepted = try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { await runtime.configurations.first?.usageCount == 1 }
            try #require(accepted)
            await host.stop()
            let stopped = try await waitForCondition(timeout: .seconds(4), pollInterval: .milliseconds(10)) { finished.withLock { $0 } }
            #expect(stopped)
        } catch {
            await host.stop()
            try? input.fileHandleForWriting.close()
            throw error
        }
        try input.fileHandleForWriting.close()
        await relay.value
    }

    @Test(.tags(.integration))
    func busyUsageCounterKeepsConnectionsAndFlushesAfterUnlock() async throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try preferences.makeBridgeRuntime(in: directory, connect: { BridgeFixture() })
        let host = BridgeHost(runtime: runtime)
        try await host.setEnabled(true)
        do {
            try await Self.verifyBusyCounter(in: directory, host: host)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @concurrent
    private nonisolated static func verifyBusyCounter(in directory: URL, host: BridgeHost) async throws {
        let runtime = host.runtime
        let token = try await runtime.createConfigurationToken(name: "counter")
        let configurationID = try runtime.configurationID(forToken: token)
        let endpoint = try BridgeEndpoint(in: directory)
        func connect() throws -> Int32 {
            let fd = try BridgeIPC.connect(to: endpoint, hello: ["credential": .string(token), "session": ["version": "2025-11-25"], "initialized": .bool(true)])
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
                Darwin.close(fd)
                throw POSIXError(.EIO)
            }
            return fd
        }
        func call(_ fd: Int32, _ id: Int, _ name: BridgeJSON = "codex_list", _ arguments: BridgeJSON = [:]) throws -> BridgeJSON {
            let request: BridgeJSON = ["jsonrpc": "2.0", "id": .integer(id), "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            try BridgeIPC.write(request.data() + Data([10]), to: fd)
            let response = try #require(try readFrame(fd))
            try #require(response["id"] == .integer(id))
            return response
        }
        let first = try connect()
        defer { Darwin.close(first) }
        let second = try connect()
        defer { Darwin.close(second) }
        let editor = try BridgeSQLite(url: BridgeStore.databaseURL(in: directory))
        try editor.run("BEGIN IMMEDIATE")
        try editor.run("UPDATE configurations SET uses = 100")
        for (id, fd) in [first, second, first].enumerated() {
            #expect(try call(fd, id)["result"]["isError"] == .bool(false))
        }
        #expect(await runtime.configurations.first?.usageCount == 3)
        #expect(try editor.number("SELECT uses FROM configurations") == 100)
        try editor.run("COMMIT")
        let flushed = try await waitForCondition(timeout: .seconds(5), pollInterval: .milliseconds(20)) {
            await runtime.configurations.first?.usageCount == 103
        }
        try #require(flushed)
        #expect(try editor.number("SELECT uses FROM configurations") == 103)

        try editor.run("CREATE TRIGGER fail_count BEFORE UPDATE OF uses ON configurations BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        #expect(try call(first, 3)["error"]["code"] == .integer(-32603))
        try editor.run("DROP TRIGGER fail_count")
        try editor.run("CREATE TRIGGER fail_task BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        let failed = try call(first, 4, "codex_start", ["project": .string(directory.path), "prompt": "test", "operationId": "busy"])
        #expect(failed["result"]["isError"] == .bool(true))
        #expect(try call(first, 5)["result"]["isError"] == .bool(false))
        #expect(try editor.number("SELECT uses FROM configurations") == 105)

        try editor.run("BEGIN IMMEDIATE")
        #expect(try call(second, 6)["result"]["isError"] == .bool(false))
        try editor.run("ROLLBACK")
        try await host.deleteConfiguration(configurationID)
        for fd in [first, second] {
            #expect(try readFrame(fd)?["bridge"] == "end")
            #expect(try readFrame(fd) == nil)
        }
        #expect(try editor.number("SELECT count(*) FROM configurations") == 0)
    }
}
