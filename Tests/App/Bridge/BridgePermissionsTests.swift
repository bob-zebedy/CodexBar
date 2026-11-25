import Foundation
import Testing

struct BridgePermissionsTests {
    @Test func approvalOptionsUseConversationLanguageAndDefaultToEnglish() throws {
        let schema = BridgeTool.respond.definition["inputSchema"]
        #expect(schema["properties"]["locale"]["type"] == "string" && !schema["required"].elements.contains("locale"))
        let network: BridgeJSON = ["network": ["enabled": .bool(true)]]
        let rpc = BridgeRPCRequest(
            id: .integer(1),
            method: .permissions,
            params: ["cwd": "/project", "permissions": network],
            permissions: .init(),
            project: "/project",
            changedPaths: nil
        )
        let request = BridgePendingRequest(id: "r", source: .rpc(rpc), task: "t", turn: "u")
        for (locale, allow, deny) in [
            (nil as String?, "Allow", "Deny"),
            ("fr-CA", "Allow", "Deny"),
            ("en-GB", "Allow", "Deny"),
            ("zh", "允许", "拒绝"),
            ("zh-CN", "允许", "拒绝"),
            ("zh-Hans", "允许", "拒绝"),
            ("zh-Hant-CN", "Allow", "Deny"),
            ("zh-TW", "Allow", "Deny"),
            ("zh-HK", "Allow", "Deny"),
            ("ru", "Allow", "Deny")
        ] {
            let form = try #require(request.form(approvalOptions: .init(locale: locale)))
            let choices = form["requestedSchema"]["properties"]["decision"]["oneOf"].elements
            #expect(choices.map { $0["title"].text } == [allow, deny])
            try #require(choices.map { $0["const"].text } == ["allow_for_turn", "deny"])
            #expect(try rpc.answer(["action": "accept", "content": ["decision": choices[0]["const"]]]) == ["permissions": network, "scope": "turn"])
            #expect(try rpc.answer(["action": "accept", "content": ["decision": choices[1]["const"]]]) == ["permissions": [:], "scope": "turn"])
        }
    }

    @Test func askingForPermissionsUsesScopedGrantsAndRejectsBlanketEscalation() throws {
        let permissions = BridgePermissions(writable: true)
        let options = permissions.threadOptions(project: "/project", bridgeDirectory: URL(fileURLWithPath: "/bridge"))
        let policy = try #require(options["approvalPolicy"])
        #expect(policy["granular"]["request_permissions"] == .bool(true))
        #expect(policy["granular"]["sandbox_approval"] == .bool(false))
        #expect(policy["granular"]["rules"] == .bool(true))
        let config = try #require(options["config"])
        #expect(config["features.request_permissions_tool"] == .bool(true))
        #expect(config["permissions.codexbar-bridge"]["network"]["enabled"] == .bool(false))
    }

    @Test func approvalDecisionsRespectConfiguredPermissionsAndKeepQuestionsAvailable() throws {
        let offline = BridgePermissions(writable: true, network: .deny)
        let automatic = BridgePermissions(writable: true, network: .allow, approval: .deny)
        func request(_ method: BridgeRPCRequest.Method, _ permissions: BridgePermissions, _ params: BridgeJSON) -> BridgeRPCRequest {
            BridgeRPCRequest(id: .integer(1), method: method, params: params, permissions: permissions, project: "/project", changedPaths: nil)
        }
        let network: BridgeJSON = ["cwd": "/project", "permissions": ["network": ["enabled": .bool(true)]]]
        let command: BridgeJSON = ["cwd": "/project", "command": "pwd"]
        let accept: BridgeJSON = ["action": "accept", "content": ["decision": "allow_for_turn"]]
        let declined = request(.permissions, offline, network)
        #expect(declined.form == nil)
        #expect(throws: BridgeFailure.self) { try declined.answer(accept) }
        #expect(try declined.answer(["action": "decline"]) == ["scope": "turn", "permissions": [:]])
        #expect(try request(.permissions, .init(), network).answer(accept) == ["scope": "turn", "permissions": network["permissions"]])
        #expect(request(.command, offline, command).form == nil)
        #expect(request(.command, automatic, command).form == nil)
        #expect(request(.fileChange, automatic, ["grantRoot": "/project", "reason": "edit"]).form == nil)
        #expect(request(.userInput, automatic, ["questions": [["id": "file", "question": "Which file?"]]]).form != nil)
    }

    @Test func commandAndFileApprovalsRespectTheirRequestedScope() throws {
        let writer = BridgePermissions(writable: true)
        let allowOnce: BridgeJSON = ["action": "accept", "content": ["decision": "allow_once"]]
        func command(_ extras: BridgeJSON) -> BridgeRPCRequest {
            var params = extras.fields ?? [:]
            params["cwd"] = "/project"
            params["command"] = "pwd"
            return BridgeRPCRequest(id: .integer(1), method: .command, params: .object(params), permissions: writer, project: "/project", changedPaths: nil)
        }
        let outside: BridgeJSON = ["fileSystem": ["write": ["/other"]]]
        let denied = command(["additionalPermissions": outside])
        #expect(denied.form == nil)
        #expect(throws: BridgeFailure.self) { try denied.answer(allowOnce) }
        #expect(command(["additionalPermissions": ["network": ["enabled": .bool(true)]]]).form == nil)
        let noOneTimeApproval = command(["availableDecisions": ["cancel"]])
        #expect(noOneTimeApproval.form == nil)
        #expect(throws: BridgeFailure.self) { try noOneTimeApproval.answer(allowOnce) }
        #expect(try command(["availableDecisions": ["accept", "cancel"]]).answer(allowOnce) == ["decision": "accept"])

        let requested: BridgeJSON = ["fileSystem": ["write": ["/project/output"]]]
        let params: BridgeJSON = ["cwd": "/project", "permissions": requested]
        let file = BridgeRPCRequest(id: .integer(2), method: .permissions, params: params, permissions: writer, project: "/project", changedPaths: nil)
        #expect(try file.answer(["action": "accept", "content": ["decision": "allow_for_turn"]]) == ["permissions": requested, "scope": "turn"])
        #expect(!file.isPermitted(by: .init(writable: false)))
    }
}
