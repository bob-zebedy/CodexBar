import Foundation

actor CodexServiceStatusService {
    static let statusPageURL = URL(string: "https://status.openai.com")!
    private static let endpoint = URL(string: "https://status.openai.com/proxy/status.openai.com")!
    private static let maximumResponseBytes = 256 * 1024
    private let session: URLSession

    init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetch() async throws -> CodexServiceStatus {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard response.expectedContentLength <= Self.maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try CodexServiceStatus(data: data)
    }
}
