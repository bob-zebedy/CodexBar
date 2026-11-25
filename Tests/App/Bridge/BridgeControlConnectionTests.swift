import Foundation
import os
import Testing

@Suite(.tags(.integration))
struct BridgeControlConnectionTests {
    @Test func logsWireMessagesAndShortensOnlyConversationText() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let logs = AppServerLogStore(directoryURL: directory.url)
        let prefix = String(repeating: "字", count: BridgeLogPayload.characterLimit)
        let prompt = prefix + "用户输入的末尾"
        let answer = prefix + "助手回复的末尾"
        let summary = prefix + "…"
        let output = String(repeating: "x", count: 150 * 1024)
        let question = BridgeRPCRequest.Method.userInput
        let unknown = "example/customRequest"
        let threadReply = #"{"id":2,"result":{"thread":{"id":"t","threadSource":"codexbar_bridge","preview":"","turns":[]},"cwd":"/project","extra":null}}"#
        let turnReply = #"{"id":3, "result":{"turn":{"id":"turn","items":[{"text":"\#(answer)","type":"agentMessage","id":"a"}]}}}"#
        let delta = #"{"method":"item/commandExecution/outputDelta","params":{"delta":"\#(output)","unknownNumber":1.234567890123456789e+20}}"#
        let ask = #"{"id":"q","method":"item/tool/requestUserInput","params":{"questions":[{"id":"one","question":"Short?"}]}}"#
        let unsupported = #"{"id":22,"method":"example/customRequest","params":{"text":"\#(prompt)"}}"#
        let failure = #"{"id":4,"error":{"code":-32602, "message":"\#(answer)","data":{"text":"\#(prompt)"}}}"#
        let sent = OSAllocatedUnfairLock(initialState: [String]())
        let server = try SharedServerFixture { peer in
            func read() throws -> String {
                let payload = try peer.readPayload(opcode: 1)
                let raw = try #require(String(data: payload, encoding: .utf8))
                sent.withLock { $0.append(raw) }
                return raw
            }
            let handshake = try peer.readMessage()
            #expect((handshake["params"] as? [String: Any])?["capabilities"] as? [String: Bool] == ["experimentalApi": true])
            try peer.reply(to: handshake, result: ["userAgent": "codex/0.162.0"])
            #expect(try peer.readMessage()["method"] as? String == "initialized")
            _ = try read()
            try peer.sendRaw(Data(threadReply.utf8))
            let input = try read()
            #expect(input.contains(prompt))
            for message in [delta, ask, unsupported, turnReply] {
                try peer.sendRaw(Data(message.utf8))
            }
            let reply = try read()
            #expect(reply.contains(prompt))
            _ = try read()
            _ = try read()
            try peer.sendRaw(Data(failure.utf8))
        }
        defer { server.close() }
        let bridge = try BridgeControlConnection(socket: server.url, logs: logs)
        defer { bridge.close() }
        #expect(try bridge.call("thread/start", ["cwd": "/project", "approvalPolicy": BridgePermissions.Approval.ask.policy])["thread"]["id"] == "t")
        let input: BridgeJSON = [["type": "text", "text": .string(prompt)], ["type": "mention", "name": .string(prompt)]]
        let turn = try bridge.call("turn/start", ["threadId": "t", "input": input])
        #expect(turn["turn"]["items"].elements.first?["text"].text == answer)
        #expect(try bridge.next()?["params"]["delta"].text == output)
        let form = try #require(try bridge.next())
        try bridge.answer(question, id: form["id"], result: ["answers": ["one": ["answers": [.string(prompt)]]]])
        let other = try #require(try bridge.next())
        try bridge.reject(unknown, id: other["id"])
        #expect(throws: AppServerError.self) { try bridge.call("turn/steer", ["input": input]) }
        try server.finish()
        bridge.close()
        try await logs.close()

        let reopened = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await reopened.close() } }
        let rows = try await reopened.page().entries
        func row(_ name: String, _ source: AppServerLogEntry.Source) throws -> AppServerLogEntry {
            let matches = rows.filter { $0.connection == "bridge" && $0.method == name && $0.source == source }
            try #require(matches.count == 1)
            return matches[0]
        }
        let frames = sent.withLock { $0 }
        try #require(frames.count == 5)
        let start = try row("thread/start", .request)
        #expect(start.request == frames[0] && start.detail == threadReply)
        let run = try row("turn/start", .request)
        // mention.name 和正文内容完全相同, 仍须逐字保留
        let expectedInput = frames[1].replacingOccurrences(of: #""text":"\#(prompt)""#, with: #""text":"\#(summary)""#)
        #expect(run.request == expectedInput && run.detail == turnReply.replacingOccurrences(of: answer, with: summary))
        #expect(try row("item/commandExecution/outputDelta", .received).detail == delta)
        #expect(try row(question.rawValue, .received).detail == ask)
        #expect(try row(question.rawValue, .sent).request == frames[2].replacingOccurrences(of: prompt, with: summary))
        #expect(try row(unknown, .received).detail == unsupported)
        #expect(try row(unknown, .sent).request == frames[3])
        let failed = try row("turn/steer", .request)
        #expect(failed.status == .failure && failed.detail == failure)
    }

    @Test func preservesHistoryFieldsAndSharesOneSummaryAcrossReplyFragments() throws {
        let first = String(repeating: "a", count: BridgeLogPayload.characterLimit)
        let full = first + "more"
        let item = #"{"type":"userMessage","content":[{"type":"text","text":"\#(full)"},{"type":"image","url":"\#(full)"}]}"#
        let reply = #"{"id":42, "result":{"data":[{"item":\#(item),"extra":{"items":[\#(item)]}}],"nextCursor":"\#(full)"}}"#
        let original = #""text":"\#(full)""#
        var expected = reply
        try expected.replaceSubrange(#require(expected.range(of: original)), with: #""text":"\#(first)…""#)
        #expect(BridgeLogPayload.text(Data(reply.utf8), method: "thread/items/list") == expected)

        var stream = BridgeLogPayload.Stream()
        func fragment(_ text: String, item: String) -> String {
            let params = ["threadId": "t", "turnId": "turn", "itemId": item, "delta": text]
            let raw = #"{"params":{"delta":"\#(text)","itemId":"\#(item)","turnId":"turn","threadId":"t"},"method":"item/agentMessage/delta"}"#
            return stream.text(Data(raw.utf8), method: "item/agentMessage/delta", params: params)
        }
        #expect(fragment(first, item: "a").contains(first))
        #expect(fragment("more", item: "a").contains(#""delta":"…""#))
        #expect(fragment("short", item: "b").contains(#""delta":"short""#))
    }

    @Test func connectionFailureRecordsTheTransportError() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let logs = AppServerLogStore(directoryURL: directory.url)
        defer { await #expect(throws: Never.self) { try await logs.close() } }
        let missing = URL(fileURLWithPath: "/tmp/\(UUID()).sock")
        let error = #expect(throws: AppServerConnectionError.self) { try BridgeControlConnection(socket: missing, logs: logs) }
        let entries = try await logs.page().entries
        let entry = try #require(entries.first { $0.method == "connection/open" })
        #expect(entry.status == .failure && entry.connection == "bridge")
        #expect(entry.detail == error?.localizedDescription)
    }
}
