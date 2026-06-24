import Foundation

nonisolated struct CodexAccount: Decodable, Equatable {
    let type: String
    let email: String?
    let planType: String?

    var hasEmail: Bool {
        email?.isEmpty == false
    }

    var displayName: String {
        if let email, hasEmail {
            return email
        }

        switch type {
        case "apiKey":
            return "API Key"
        case "chatgpt":
            return "ChatGPT"
        case "amazonBedrock":
            return "Amazon Bedrock"
        default:
            return type
        }
    }
}

nonisolated struct AccountReadResponse: Decodable {
    let account: CodexAccount?
}
