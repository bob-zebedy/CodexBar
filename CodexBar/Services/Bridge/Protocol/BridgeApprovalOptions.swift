import Foundation

nonisolated struct BridgeApprovalOptions {
    enum Scope: String {
        case once = "allow_once"
        case turn = "allow_for_turn"
    }

    var locale: String?

    func schema(for scope: Scope) -> BridgeJSON {
        let language = Locale.Language(identifier: locale ?? "en")
        let titles: (allow: BridgeJSON, deny: BridgeJSON) = if language.languageCode?.identifier == "zh", language.script?.identifier == "Hans" {
            (scope == .once ? "允许一次" : "允许", "拒绝")
        } else {
            (scope == .once ? "Allow once" : "Allow", "Deny")
        }
        let allow = BridgeJSON.string(scope.rawValue)
        let decision: BridgeJSON = ["type": "string", "oneOf": [["const": allow, "title": titles.allow], ["const": "deny", "title": titles.deny]]]
        return ["type": "object", "properties": ["decision": decision], "required": ["decision"]]
    }
}
