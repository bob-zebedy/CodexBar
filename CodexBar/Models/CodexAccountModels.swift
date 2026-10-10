/// app-server account/read 的账号信息, 只保留菜单面板需要展示的字段
nonisolated struct CodexAccount: Decodable, Equatable {
    let type: String
    let email: String?
    let planType: String?

    var hasEmail: Bool {
        email?.isEmpty == false
    }

    var displayName: String {
        if let email, !email.isEmpty {
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

/// account/read 允许 account 为空, 由上层转换为`未登录`状态
nonisolated struct AccountReadResponse: Decodable {
    let account: CodexAccount?

    init(account: CodexAccount?) {
        self.account = account
    }

    private enum CodingKeys: String, CodingKey { case account }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 缺字段是无效响应, 只有显式 null 才表示没有账户
        account = try container.decodeNil(forKey: .account) ? nil : container.decode(CodexAccount.self, forKey: .account)
    }
}
