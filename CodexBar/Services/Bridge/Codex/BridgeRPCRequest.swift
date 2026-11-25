import Foundation

nonisolated struct BridgeRPCRequest {
    enum Method: String {
        case command = "item/commandExecution/requestApproval"
        case fileChange = "item/fileChange/requestApproval"
        case permissions = "item/permissions/requestApproval"
        case userInput = "item/tool/requestUserInput"
        case elicitation = "mcpServer/elicitation/request"

        var declinedResult: BridgeJSON {
            switch self {
            case .command, .fileChange: ["decision": "decline"]
            case .permissions: ["permissions": [:], "scope": "turn"]
            case .userInput: ["answers": [:]]
            case .elicitation: ["action": "decline", "content": .null, "_meta": .null]
            }
        }

        var isApproval: Bool {
            switch self {
            case .command, .fileChange, .permissions: true
            case .userInput, .elicitation: false
            }
        }
    }

    let id: BridgeJSON
    let method: Method
    let params: BridgeJSON
    var permissions: BridgePermissions
    let project: String
    let changedPaths: [String]?

    static func changedPaths(in item: BridgeJSON, project: String) -> [String]? {
        let changes = item["changes"].elements
        guard !changes.isEmpty, changes.count <= 32 else { return nil }
        var paths: [String] = []
        for change in changes {
            guard let path = change["path"].text, ["add", "delete", "update"].contains(change["kind"]["type"].text) else { return nil }
            for path in [path, change["kind"]["move_path"].text].compactMap(\.self) {
                guard !path.isEmpty, path.utf8.count <= 1024 else { return nil }
                let absolute = path.hasPrefix("/") ? path : (project as NSString).appendingPathComponent(path)
                paths.append(CodexPaths.canonicalPath(absolute))
            }
        }
        return paths
    }

    private var requestContent: String {
        switch method {
        case .command: params["command"].text ?? ""
        case .fileChange:
            ((changedPaths ?? []) + [params["grantRoot"].text].compactMap(\.self)).joined(separator: "\n")
        case .permissions: (try? params["permissions"].jsonText()) ?? ""
        case .elicitation: params["message"].text ?? ""
        case .userInput: params["questions"].elements.compactMap { $0["question"].text }.joined(separator: "\n")
        }
    }

    var summary: String {
        if method.isApproval, let reason = params["reason"].text, reason.contains(where: { !$0.isWhitespace }) {
            return reason
        }
        return requestContent
    }

    enum Form {
        case approval(BridgeApprovalOptions.Scope)
        case input(BridgeJSON)
    }

    private var approvalScope: BridgeApprovalOptions.Scope {
        method == .permissions ? .turn : .once
    }

    private func isWithinProject(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let target = CodexPaths.canonicalPath(path)
        return target == project || target.hasPrefix(project + "/")
    }

    private func permits(_ requestedPermissions: BridgeJSON) -> Bool {
        guard let raw = requestedPermissions.fields, Set(raw.keys).isSubset(of: ["network", "fileSystem"]) else { return false }
        let network = requestedPermissions["network"]
        if network != .null {
            guard permissions.network != .deny || network["enabled"] != .bool(true),
                  let fields = network.fields, Set(fields.keys).isSubset(of: ["enabled"]),
                  [BridgeJSON.null, .bool(true), .bool(false)].contains(network["enabled"]) else { return false }
        }
        let fs = requestedPermissions["fileSystem"]
        if fs == .null {
            return true
        }
        guard let fields = fs.fields, Set(fields.keys).isSubset(of: ["read", "write", "entries", "globScanMaxDepth"]) else { return false }
        for key in ["read", "write"] where fs[key] != .null {
            guard case let .array(paths) = fs[key], paths.allSatisfy({ $0.text.map(isWithinProject) == true }),
                  key == "read" || paths.isEmpty || permissions.writable else { return false }
        }
        if fs["entries"] == .null {
            return true
        }
        guard case let .array(entries) = fs["entries"] else { return false }
        return entries.allSatisfy { entry in
            entry["path"]["type"] == "path" && entry["path"]["path"].text.map(isWithinProject) == true
                && (entry["access"] == "read" || (permissions.writable && entry["access"] == "write"))
        }
    }

    func isPermitted(by permissions: BridgePermissions) -> Bool {
        var request = self
        request.permissions = permissions
        return request.form != nil
    }

    var form: Form? {
        if method.isApproval {
            let cwd = method == .command ? params["cwd"].text : nil
            let details = [requestContent, cwd, params["reason"].text].compactMap(\.self).joined(separator: "\n")
            guard permissions.approval == .ask, !details.isEmpty, details.utf8.count <= 16384 else { return nil }
        }
        switch method {
        case .command:
            let decisions = params["availableDecisions"]
            guard permissions.writable, permissions.network != .deny, params["kind"] == .null || params["kind"] == "command",
                  params["additionalPermissions"] == .null, decisions == .null || decisions.elements.contains("accept"),
                  let cwd = params["cwd"].text, isWithinProject(cwd), let command = params["command"].text, !command.isEmpty else { return nil }
            return .approval(approvalScope)
        case .permissions:
            guard permits(params["permissions"]), params["cwd"].text.map(isWithinProject) == true else { return nil }
            return .approval(approvalScope)
        case .fileChange:
            let root = params["grantRoot"].text
            guard permissions.writable, root != nil || changedPaths != nil,
                  root.map(isWithinProject) != false, changedPaths?.allSatisfy(isWithinProject) != false else { return nil }
            return .approval(approvalScope)
        case .userInput:
            return questionForm.map { .input($0.schema) }
        case .elicitation:
            guard params["mode"] == "form", params["_meta"] == .null, params["requestedSchema"]["type"] == "object" else { return nil }
            return .input(params["requestedSchema"])
        }
    }

    private var questionForm: BridgeQuestionForm? {
        var questions: [BridgeQuestionForm.Question] = []
        var keys = Set<String>()
        for question in params["questions"].elements {
            guard question["isSecret"] != .bool(true), let key = try? question.required("id"),
                  let title = question["question"].text, keys.insert(key).inserted else { return nil }
            let options = question["options"].elements.compactMap { $0["label"].text }
            questions.append(.init(key: key, title: title, options: options, allowsOther: question["isOther"] == .bool(true)))
        }
        return questions.isEmpty ? nil : BridgeQuestionForm(questions)
    }

    func answer(_ response: BridgeJSON) throws -> BridgeJSON {
        guard ["accept", "decline", "cancel"].contains(response["action"].text) else { throw BridgeFailure("invalid_form_response") }
        if response["action"] == "decline" {
            return method.declinedResult
        }
        let content = response["content"]
        let accepted = response["action"] == "accept"
        let approved = accepted && content["decision"].text == approvalScope.rawValue
        guard !approved || form != nil else { throw BridgeFailure("unsupported_approval") }
        switch method {
        case .command, .fileChange:
            return ["decision": .string(approved ? "accept" : "decline")]
        case .permissions:
            return ["permissions": approved ? params["permissions"] : [:], "scope": "turn"]
        case .userInput:
            var answers: [String: BridgeJSON] = [:]
            if accepted {
                guard let form = questionForm else { throw BridgeFailure("invalid_form_response") }
                for question in form.questions {
                    answers[question.key] = try ["answers": [.string(form.answer(question, in: content))]]
                }
            }
            return ["answers": .object(answers)]
        case .elicitation: return ["action": response["action"], "content": accepted ? content : .null, "_meta": .null]
        }
    }
}
