import Foundation

nonisolated enum CodexResetCreditsService {
    enum FetchError: Error {
        case invalidResponse
        case unauthorized
    }

    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let timeout: TimeInterval = 4

    static func fetchExpirationDates(environment: [String: String]) async throws -> [Date] {
        let credentials = try CodexOAuthCredentials.load(environment: environment)
        let request = makeRequest(credentials: credentials)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200 ... 299:
            return try decodeExpirationDates(from: data)
        case 401, 403:
            throw FetchError.unauthorized
        default:
            throw FetchError.invalidResponse
        }
    }

    private static func makeRequest(credentials: CodexOAuthCredentials) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        if let accountId = credentials.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        return request
    }

    private static func decodeExpirationDates(from data: Data) throws -> [Date] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeISO8601Date)
        let payload = try decoder.decode(RateLimitResetCreditsResponse.self, from: data)
        let now = Date()

        return payload.credits
            .compactMap { credit in
                guard credit.status == "available",
                      let expiresAt = credit.expiresAt,
                      expiresAt > now else {
                    return nil
                }

                return expiresAt
            }
            .sorted()
    }

    private static func decodeISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let date = CodexDateFormat.iso8601FractionalDate(from: raw)
            ?? CodexDateFormat.iso8601InternetDateTimeDate(from: raw) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(raw)"
        )
    }
}

private nonisolated extension CodexResetCreditsService {
    struct RateLimitResetCreditsResponse: Decodable {
        let credits: [RateLimitResetCredit]
    }

    struct RateLimitResetCredit: Decodable {
        let status: String
        let expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case status
            case expiresAt = "expires_at"
        }
    }

    struct CodexOAuthCredentials {
        let accessToken: String
        let accountId: String?

        static func load(environment: [String: String]) throws -> Self {
            let authURL = authFileURL(environment: environment)
            let data = try Data(contentsOf: authURL)
            let authFile = try JSONDecoder().decode(CodexAuthFile.self, from: data)
            guard let accessToken = authFile.tokens?.accessToken, !accessToken.isEmpty else {
                throw FetchError.invalidResponse
            }

            return Self(accessToken: accessToken, accountId: authFile.tokens?.accountId)
        }

        private static func authFileURL(environment: [String: String]) -> URL {
            if let codexHome = nonEmptyEnvironmentValue("CODEX_HOME", in: environment) {
                return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
            }

            let home = nonEmptyEnvironmentValue("HOME", in: environment) ?? NSHomeDirectory()
            let homeURL = URL(fileURLWithPath: home)
            return homeURL
                .appendingPathComponent(".codex")
                .appendingPathComponent("auth.json")
        }

        private static func nonEmptyEnvironmentValue(
            _ key: String,
            in environment: [String: String]
        ) -> String? {
            let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
    }

    struct CodexAuthFile: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            private enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }
    }
}
