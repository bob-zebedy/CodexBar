import Foundation

nonisolated struct BridgePermissions: Codable, Equatable, Sendable {
    enum Network: String, CaseIterable, Codable, Sendable {
        case deny, ask, allow
    }

    enum Approval: String, CaseIterable, Codable, Sendable {
        case ask, deny

        var policy: BridgeJSON {
            guard self == .ask else { return "never" }
            // 沙箱外命令审批无法授予本轮网络或文件访问权限, 由 Codex 按具体权限发起申请
            return ["granular": [
                "sandbox_approval": .bool(false),
                "request_permissions": .bool(true),
                "rules": .bool(true),
                "skill_approval": .bool(true),
                "mcp_elicitations": .bool(true)
            ]]
        }
    }

    private static let profileName = "codexbar-bridge"

    var writable = false
    var network = Network.ask
    var approval = Approval.ask

    var isValid: Bool {
        network != .ask || approval == .ask
    }

    func jsonText() throws -> String {
        guard isValid else { throw BridgeFailure("invalid_configuration") }
        let data = try JSONEncoder().encode(self)
        guard let json = String(data: data, encoding: .utf8) else { throw BridgeFailure("invalid_json") }
        return json
    }

    static func decode(_ json: String) throws -> Self {
        guard let permissions = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)), permissions.isValid else {
            throw BridgeFailure("invalid_configuration")
        }
        return permissions
    }

    func threadOptions(project: String, bridgeDirectory: URL) -> [String: BridgeJSON] {
        // 将凭据目录设为不可读, 让 Codex 在命中已有命令放行规则时仍保留沙盒
        var filesystem: [String: BridgeJSON] = ["/": "read", CodexPaths.canonicalPath(bridgeDirectory.path): "none"]
        if writable {
            filesystem[":project_roots"] = "write"
        }
        return [
            "cwd": .string(project),
            "config": [
                "default_permissions": .string(Self.profileName),
                "permissions.\(Self.profileName)": [
                    "filesystem": .object(filesystem),
                    "network": ["enabled": .bool(network == .allow)]
                ],
                "features.request_permissions_tool": .bool(approval == .ask)
            ],
            "approvalPolicy": approval.policy,
            "approvalsReviewer": "user"
        ]
    }

    func validate(_ result: BridgeJSON, project: String) throws {
        let sandbox = result["sandbox"]
        guard result["cwd"].text.map(CodexPaths.canonicalPath) == project,
              result["approvalPolicy"] == approval.policy, result["approvalsReviewer"] == "user",
              result["activePermissionProfile"]["id"].text == Self.profileName,
              sandbox["networkAccess"] == .bool(network == .allow),
              sandbox["type"] == (writable ? "workspaceWrite" : "readOnly") else { throw BridgeFailure("policy_mismatch") }
        if writable {
            guard sandbox["excludeTmpdirEnvVar"] == .bool(true), sandbox["excludeSlashTmp"] == .bool(true),
                  case let .array(roots) = sandbox["writableRoots"],
                  roots.allSatisfy({ $0.text.map(CodexPaths.canonicalPath) == project }) else { throw BridgeFailure("policy_mismatch") }
        }
    }
}
