import Darwin
import Foundation

nonisolated struct CodexProxyConfiguration: Codable, Equatable, Sendable {
    enum Transport: String, Codable, CaseIterable, Sendable {
        case http
        case https
    }

    enum InputField: Hashable {
        case host
        case port
        case username
    }

    enum ValidationKind {
        case required
        case format
    }

    struct ValidationIssue: Equatable {
        let field: InputField
        let kind: ValidationKind

        var title: String {
            switch (field, kind) {
            case (.host, .required): String(localized: "proxy.validation.host.required")
            case (.port, .required): String(localized: "proxy.validation.port.required")
            case (.username, .required): String(localized: "proxy.validation.username.required")
            case (.host, .format): String(localized: "proxy.validation.host.invalid")
            case (.port, .format): String(localized: "proxy.validation.port.invalid")
            case (.username, .format): String(localized: "proxy.validation.username.invalid")
            }
        }
    }

    var isEnabled = false
    var transport = Transport.http
    var host = ""
    var port = ""
    var usesAuthentication = false
    var username = ""

    var validationIssues: [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ValidationIssue(field: .host, kind: .required))
        }
        if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ValidationIssue(field: .port, kind: .required))
        }
        if usesAuthentication, username.isEmpty {
            issues.append(ValidationIssue(field: .username, kind: .required))
        }
        guard issues.isEmpty else { return issues }
        if (try? normalizedHost()) == nil {
            issues.append(ValidationIssue(field: .host, kind: .format))
        }
        if validPort == nil {
            issues.append(ValidationIssue(field: .port, kind: .format))
        }
        if !isUsernameValid {
            issues.append(ValidationIssue(field: .username, kind: .format))
        }
        return issues
    }

    func validated() throws -> Self {
        if let issue = validationIssues.first {
            throw issue.field == .username ? CodexProxyError.missingUsername : CodexProxyError.invalidAddress
        }
        var result = self
        result.host = try normalizedHost()
        guard let portNumber = validPort else { throw CodexProxyError.invalidAddress }
        result.port = String(portNumber)
        return result
    }

    private var validPort: Int? {
        guard let number = Int(port.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1 ... 65535).contains(number) else { return nil }
        return number
    }

    private var isUsernameValid: Bool {
        !usesAuthentication || (!username.isEmpty && !username.contains(":")
            && !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }))
    }

    private func normalizedHost() throws -> String {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty,
              !host.contains(where: \.isWhitespace),
              !host.contains(where: { "/?#@\\%".contains($0) }) else {
            throw CodexProxyError.invalidAddress
        }
        if host.contains(":") || host.contains("[") {
            let address = host.hasPrefix("[") && host.hasSuffix("]")
                ? String(host.dropFirst().dropLast()) : host
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, address, &bytes) == 1 else { throw CodexProxyError.invalidAddress }
            host = "[\(address)]"
        } else {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
            guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                throw CodexProxyError.invalidAddress
            }
        }
        guard let components = URLComponents(string: "\(transport.rawValue)://\(host):1"),
              components.host != nil, components.port == 1,
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.url != nil else {
            throw CodexProxyError.invalidAddress
        }
        return host
    }

    func environment(overriding base: [String: String], password: String) throws -> [String: String] {
        guard isEnabled else { return base }
        let configuration = try validated()
        var components = URLComponents(string: "\(transport.rawValue)://\(configuration.host):\(configuration.port)")!
        if usesAuthentication {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            components.percentEncodedUser = username.addingPercentEncoding(withAllowedCharacters: allowed)
            components.percentEncodedPassword = password.addingPercentEncoding(withAllowedCharacters: allowed)
        }
        guard let address = components.url?.absoluteString else { throw CodexProxyError.invalidAddress }
        var environment = base
        // 协议专用变量优先于系统设置, 清理继承的旁路和 WebSocket 变量以保持单一出口
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "WS_PROXY", "WSS_PROXY"] {
            environment[key] = address
            environment[key.lowercased()] = address
        }
        environment["NO_PROXY"] = "localhost,127.0.0.1,::1"
        environment["no_proxy"] = environment["NO_PROXY"]
        return environment
    }
}

nonisolated enum CodexProxyError: LocalizedError {
    case invalidAddress
    case missingUsername
    case invalidStoredConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "proxy.error.invalid-endpoint")
        case .missingUsername: String(localized: "proxy.error.invalid-username")
        case .invalidStoredConfiguration: String(localized: "proxy.error.configuration-unreadable")
        }
    }
}
