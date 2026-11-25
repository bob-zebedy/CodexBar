import Foundation

actor BridgePeer {
    typealias Output = @Sendable (Data) async throws -> Void
    private static let protocolVersion = "2025-11-25"

    private enum Phase {
        case initial, negotiated, ready
    }

    let runtime: BridgeRuntime
    let output: Output
    private let endSession: @Sendable () async -> Void
    var configurationID: UUID?
    private var phase = Phase.initial
    var supportsForms = false
    private var rejectedUses: Int64 = 0
    var closed = false
    var operations: [BridgeJSON: Task<Void, Never>] = [:]
    var pendingFormReplies: [BridgeJSON: CheckedContinuation<BridgeJSON, Error>] = [:]

    init(runtime: BridgeRuntime, endSession: @escaping @Sendable () async -> Void = {}, output: @escaping Output) {
        self.endSession = endSession
        self.runtime = runtime
        self.output = output
    }

    func close() {
        closed = true
        for operation in operations.values {
            operation.cancel()
        }
        operations.removeAll()
        for reply in pendingFormReplies.values {
            reply.resume(throwing: CancellationError())
        }
        pendingFormReplies.removeAll()
    }

    func accept(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let message = try JSONDecoder().decode(BridgeJSON.self, from: data)
        if configurationID == nil {
            configurationID = try runtime.configurationID(forToken: message.required("credential", maxBytes: 128))
            if message["session"] != .null {
                let session = message["session"]
                guard session["version"].text == Self.protocolVersion else { throw BridgeFailure("session_incompatible") }
                supportsForms = session["forms"] == .bool(true)
                phase = message["initialized"] == .bool(true) ? .ready : .negotiated
            }
            try await output(BridgeIPC.connected)
            return
        }
        guard let configurationID, message["jsonrpc"] == "2.0" else { throw BridgeFailure("invalid_rpc") }
        guard runtime.isEnabled else { throw BridgeFailure("unauthorized") }
        let id = message["id"].rpcID
        let params = message["params"]
        guard let method = message["method"].text else {
            if let id, let reply = pendingFormReplies.removeValue(forKey: id) {
                if message["error"] != .null {
                    reply.resume(throwing: BridgeFailure("client_form_failed"))
                } else {
                    reply.resume(returning: message["result"])
                }
            }
            return
        }
        if method == "notifications/initialized" {
            if phase == .negotiated {
                phase = .ready
            }
            return
        }
        if method == "notifications/cancelled" {
            if let id = params["requestId"].rpcID {
                operations[id]?.cancel()
            }
            return
        }
        guard let id else { return }
        switch method {
        case "initialize":
            guard phase == .initial else {
                try await rpcError(id, -32600, "Already initialized")
                return
            }
            phase = .negotiated
            let capability = params["capabilities"]["elicitation"].fields
            supportsForms = capability?.isEmpty == true || capability?["form"]?.fields != nil
            let result: BridgeJSON = [
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "codexbar-bridge", "version": "1"],
                "instructions": "When asked to delegate project work to Codex, use codex_start. Wait with the cursor and follow nextAction, even after completion."
            ]
            // 仅本地转发进程保留协商结果, 客户端只收到标准 MCP 响应
            try await send(["jsonrpc": "2.0", "id": id, "result": result, "session": ["version": .string(Self.protocolVersion), "forms": .bool(supportsForms)]])
        case "ping": try await result(id, [:])
        case "tools/list" where phase == .ready:
            try await result(id, ["tools": .array(BridgeTool.allCases.map(\.definition))])
        case "tools/call" where phase == .ready:
            try await acceptToolCall(params, configurationID: configurationID, id: id)
        default: try await rpcError(id, phase == .ready ? -32601 : -32600, phase == .ready ? "Unknown method" : "Initialize first")
        }
    }

    private func acceptToolCall(_ params: BridgeJSON, configurationID: UUID, id: BridgeJSON) async throws {
        guard let name = params["name"].text, let tool = BridgeTool(rawValue: name) else {
            try await rpcError(id, -32602, "Unknown tool")
            return
        }
        guard operations.count < 16, operations[id] == nil else {
            rejectedUses += 1
            if rejectedUses == 1 {
                Task {
                    while rejectedUses > 0 {
                        let count = rejectedUses
                        try? await runtime.recordToolUse(for: configurationID, amount: count)
                        rejectedUses -= count
                    }
                }
            }
            try await rpcError(id, -32600, "Busy or duplicate request")
            return
        }
        operations[id] = Task { await invoke(tool, params: params, configurationID: configurationID, id: id) }
    }

    func invoke(_ tool: BridgeTool, params: BridgeJSON, configurationID: UUID, id: BridgeJSON) async {
        defer { operations[id] = nil }
        do {
            try await runtime.recordToolUse(for: configurationID)
        } catch is BridgeSQLite.Failure {
            do { try await rpcError(id, -32603, "Unable to record tool use") } catch { close() }
            return
        } catch {
            close()
            await endSession()
            return
        }
        guard !Task.isCancelled, !closed else { return }
        let args = params["arguments"] == .null ? BridgeJSON.object([:]) : params["arguments"]
        let value: BridgeJSON
        do {
            let command = try tool.parse(args)
            if supportsForms {
                value = try await runtime.execute(command, configurationID: configurationID) { form in try await self.presentForm(form) }
            } else {
                value = try await runtime.execute(command, configurationID: configurationID)
            }
        } catch let failure as BridgeFailure {
            value = failure.result
        } catch is CancellationError {
            return
        } catch { value = BridgeFailure("bridge_unavailable", error.localizedDescription).result }
        guard !Task.isCancelled, !closed else { return }
        do {
            if tool == .wait, let event = value["events"].elements.last, params["_meta"]["progressToken"].rpcID != nil {
                let progress: BridgeJSON = [
                    "progressToken": params["_meta"]["progressToken"],
                    "progress": .integer(value["events"].elements.count),
                    "message": event["summary"].text.map(BridgeJSON.string) ?? event["type"]
                ]
                try await send(["jsonrpc": "2.0", "method": "notifications/progress", "params": progress])
            }
            guard !Task.isCancelled, !closed else { return }
            try await result(id, [
                "content": [["type": "text", "text": .string(value.jsonText())]],
                "structuredContent": value,
                "isError": .bool(value["error"] != .null)
            ])
        } catch { close() }
    }

    private func presentForm(_ form: BridgeJSON) async throws -> BridgeJSON {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        let id = BridgeJSON.string("form-" + UUID().uuidString)
        let timeout = Task {
            try await Task.sleep(for: .seconds(120))
            await dismiss(id)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingFormReplies[id] = continuation
                Task {
                    do {
                        try await send(["jsonrpc": "2.0", "id": id, "method": "elicitation/create", "params": form])
                    } catch { await dismiss(id) }
                }
            }
        } onCancel: { Task { await self.dismiss(id) } }
    }

    private func dismiss(_ id: BridgeJSON) async {
        guard let reply = pendingFormReplies.removeValue(forKey: id) else { return }
        reply.resume(throwing: BridgeFailure("client_form_expired"))
        try? await send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id]])
    }

    func result(_ id: BridgeJSON, _ payload: BridgeJSON) async throws {
        try await send(["jsonrpc": "2.0", "id": id, "result": payload])
    }

    func rpcError(_ id: BridgeJSON, _ code: Int, _ message: String) async throws {
        try await send(["jsonrpc": "2.0", "id": id, "error": ["code": .integer(code), "message": .string(message)]])
    }

    func send(_ message: BridgeJSON) async throws {
        guard !closed else { throw CancellationError() }
        var data = try message.data()
        data.append(10)
        try await output(data)
    }
}
