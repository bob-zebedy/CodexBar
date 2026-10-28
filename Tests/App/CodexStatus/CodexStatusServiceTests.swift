import Foundation
import os
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodexStatusServiceTests {
    @Test(arguments: ["business", "unsupported", "invalidPayload"], [false, true])
    func supplementalFailurePreservesCacheAndUnsupportedMethodPolicy(failure: String, hasCache: Bool) async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let rounds = hasCache ? 2 : 1
            for round in 0 ..< rounds {
                let account = try peer.readMessage()
                #expect(account["method"] as? String == "account/read")
                try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
                let fails = round == rounds - 1
                for method in ["account/rateLimits/read", "account/usage/read"] {
                    let attempts = fails && failure == "business" && method == "account/rateLimits/read" ? 2 : 1
                    for _ in 0 ..< attempts {
                        let request = try peer.readMessage()
                        #expect(request["method"] as? String == method)
                        if !fails {
                            let result: [String: Any] = method == "account/rateLimits/read"
                                ? ["rateLimits": [:], "ordinaryUsageAllowed": true]
                                : ["summary": ["lifetimeTokens": 123], "dailyUsageBuckets": []]
                            try peer.reply(to: request, result: result)
                        } else if failure == "invalidPayload" {
                            try peer.reply(to: request, result: [:])
                        } else {
                            try peer.send(["id": #require(request["id"]), "error": [
                                "code": failure == "unsupported" ? -32601 : -32000,
                                "message": failure == "unsupported" ? "unsupported" : "upstream network request failed"
                            ]])
                        }
                    }
                }
            }
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        if hasCache {
            guard case .data = await service.fetchOutcome().outcome else {
                Issue.record("Initial read did not populate the cache")
                return
            }
        }
        let result = await service.fetchOutcome()
        guard case let .data(snapshot) = result.outcome else {
            Issue.record("Supplemental failure discarded the account snapshot")
            return
        }
        let usesCache = hasCache && failure != "unsupported"
        let step: CodexFetchTrace.StepResult = failure == "unsupported" ? .skipped : (usesCache ? .cached : .failed)
        #expect(result.trace.rateLimits == step && result.trace.usage == step)
        #expect(result.trace.failureStage == nil)
        #expect(snapshot.isRateLimitsStale == usesCache && snapshot.isUsageStale == usesCache)
        #expect(snapshot.ordinaryUsageAllowed == (usesCache ? true : nil))
        #expect(snapshot.usage?.summary.lifetimeTokens == (usesCache ? 123 : nil))
        try server.finish()
    }

    @Test(arguments: ["account/rateLimits/read", "account/usage/read"], ["none", "account/rateLimits/read", "account/usage/read"])
    func accountChangeDuringAuthRefreshDiscardsOldData(authMethod: String, failedRead: String) async throws {
        let server = try SharedServerFixture { peer in
            func respond(_ method: String, _ result: [String: Any]) throws {
                let request = try peer.readMessage()
                try #require(request["method"] as? String == method)
                try peer.reply(to: request, result: result)
            }
            try respond("initialize", ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let firstAccount: [String: Any] = ["account": ["type": "chatgpt", "email": "a@example.test", "planType": "pro"]]
            let secondAccount: [String: Any] = ["account": ["type": "chatgpt", "email": "b@example.test", "planType": "pro"]]
            try respond("account/read", firstAccount)
            try respond("account/rateLimits/read", ["rateLimits": [:], "ordinaryUsageAllowed": true])
            try respond("account/usage/read", ["summary": ["lifetimeTokens": 123]])
            try respond("account/read", firstAccount)
            if authMethod == "account/usage/read" {
                try respond("account/rateLimits/read", ["rateLimits": [:], "ordinaryUsageAllowed": true])
            }
            let unauthorized = try peer.readMessage()
            try #require(unauthorized["method"] as? String == authMethod)
            try peer.send(["id": #require(unauthorized["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
            let refresh = try peer.readMessage()
            try #require(refresh["method"] as? String == "account/read")
            #expect((refresh["params"] as? [String: Any])?["refreshToken"] as? Bool == true)
            try peer.reply(to: refresh, result: secondAccount)
            try respond("account/rateLimits/read", failedRead == "account/rateLimits/read" ? [:] : ["rateLimits": [:], "ordinaryUsageAllowed": false])
            try respond("account/usage/read", failedRead == "account/usage/read" ? [:] : ["summary": ["lifetimeTokens": 456]])
            try respond("account/read", secondAccount)
            try respond("account/rateLimits/read", [:])
            try respond("account/usage/read", [:])
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        guard case .data = await service.fetchOutcome().outcome else {
            Issue.record("Initial read did not populate the cache")
            return
        }
        let result = await service.fetchOutcome()
        guard case let .data(snapshot) = result.outcome else {
            Issue.record("Account change did not restart supplemental reads")
            return
        }
        #expect(snapshot.account.email == "b@example.test")
        #expect(snapshot.ordinaryUsageAllowed == (failedRead == "account/rateLimits/read" ? nil : false))
        #expect(snapshot.usage?.summary.lifetimeTokens == (failedRead == "account/usage/read" ? nil : 456))
        #expect(!snapshot.isRateLimitsStale && !snapshot.isUsageStale)
        #expect(result.trace.account == .refreshed)
        #expect(result.trace.rateLimits == (failedRead == "account/rateLimits/read" ? .failed : .ok))
        #expect(result.trace.usage == (failedRead == "account/usage/read" ? .failed : .ok))
        guard case let .data(cached) = await service.fetchOutcome().outcome else {
            Issue.record("New account cache was unavailable")
            return
        }
        #expect(cached.account == snapshot.account)
        #expect(cached.ordinaryUsageAllowed == snapshot.ordinaryUsageAllowed)
        #expect(cached.usage?.summary.lifetimeTokens == snapshot.usage?.summary.lifetimeTokens)
        #expect(cached.isRateLimitsStale == (failedRead != "account/rateLimits/read"))
        #expect(cached.isUsageStale == (failedRead != "account/usage/read"))
        try server.finish()
    }

    @Test(arguments: ["account/rateLimits/read", "account/usage/read"])
    func accountChangeDoesNotRenewAuthenticationBudget(authMethod: String) async throws {
        let server = try SharedServerFixture { peer in
            try peer.reply(to: peer.readMessage(), result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            try peer.reply(to: peer.readMessage(), result: ["account": ["type": "chatgpt", "email": "a@example.test", "planType": "pro"]])
            if authMethod == "account/usage/read" {
                try peer.reply(to: peer.readMessage(), result: ["rateLimits": [:], "ordinaryUsageAllowed": true])
            }
            let unauthorized = try peer.readMessage()
            try #require(unauthorized["method"] as? String == authMethod)
            let error: [String: Any] = ["code": -32000, "message": "codex account authentication required"]
            try peer.send(["id": #require(unauthorized["id"]), "error": error])
            let refresh = try peer.readMessage()
            try #require(refresh["method"] as? String == "account/read")
            #expect((refresh["params"] as? [String: Any])?["refreshToken"] as? Bool == true)
            try peer.reply(to: refresh, result: ["account": ["type": "chatgpt", "email": "b@example.test", "planType": "pro"]])
            let retried = try peer.readMessage()
            try #require(retried["method"] as? String == "account/rateLimits/read")
            try peer.send(["id": #require(retried["id"]), "error": error])
        }
        defer { server.close() }
        let result = await CodexStatusService(socketURL: server.url, logStorage: nil).fetchOutcome()
        guard case .authenticationRequired = result.outcome else {
            Issue.record("Account change renewed the authentication budget")
            return
        }
        #expect(result.trace.account == .refreshed)
        #expect(result.trace.failureStage == .snapshot)
        #expect(result.trace.rateLimits == nil && result.trace.usage == nil && result.trace.resetCredits == nil)
        try server.finish()
    }

    @Test(arguments: [false, true])
    func quotaReadsShareOneAuthenticationRefreshBudget(repeatsOnSameMethod: Bool) async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let account = try peer.readMessage()
            try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
            let limits = try peer.readMessage()
            #expect(limits["method"] as? String == "account/rateLimits/read")
            try peer.send(["id": #require(limits["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
            let refresh = try peer.readMessage()
            #expect(refresh["method"] as? String == "account/read")
            #expect((refresh["params"] as? [String: Any])?["refreshToken"] as? Bool == true)
            try peer.reply(to: refresh, result: ["account": ["type": "apiKey"]])
            let retried = try peer.readMessage()
            #expect(retried["method"] as? String == "account/rateLimits/read")
            let secondFailure: [String: Any]
            if repeatsOnSameMethod {
                secondFailure = retried
            } else {
                try peer.reply(to: retried, result: ["rateLimits": [:]])
                secondFailure = try peer.readMessage()
                #expect(secondFailure["method"] as? String == "account/usage/read")
            }
            try peer.send(["id": #require(secondFailure["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
        }
        defer { server.close() }
        let result = await CodexStatusService(socketURL: server.url, logStorage: nil).fetchOutcome()
        guard case .authenticationRequired = result.outcome else {
            Issue.record("Repeated authentication failure was not propagated")
            return
        }
        #expect(result.trace.failureStage == .snapshot)
        #expect(result.trace.rateLimits == (repeatsOnSameMethod ? nil : .ok))
        #expect(result.trace.usage == nil)
        try server.finish()
    }

    @Test(arguments: [
        ("serverError", true), ("invalidPayload", true), ("signedOut", true),
        ("signedOut", false), ("authentication", false), ("serverError", false),
        ("invalidPayload", false), ("connectionClosed", false)
    ])
    func authenticationRefreshFailurePreservesOutcomeAndRejectsCache(failure: String, hasCache: Bool) async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let rounds = hasCache ? 2 : 1
            for round in 0 ..< rounds {
                let account = try peer.readMessage()
                #expect(account["method"] as? String == "account/read")
                try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
                let limits = try peer.readMessage()
                #expect(limits["method"] as? String == "account/rateLimits/read")
                if round < rounds - 1 {
                    try peer.reply(to: limits, result: ["rateLimits": [:], "ordinaryUsageAllowed": true])
                    let usage = try peer.readMessage()
                    #expect(usage["method"] as? String == "account/usage/read")
                    try peer.reply(to: usage, result: ["summary": ["lifetimeTokens": 123]])
                } else {
                    try peer.send(["id": #require(limits["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
                    for _ in 0 ..< (failure == "serverError" ? 2 : 1) {
                        let refresh = try peer.readMessage()
                        #expect(refresh["method"] as? String == "account/read")
                        #expect((refresh["params"] as? [String: Any])?["refreshToken"] as? Bool == true)
                        switch failure {
                        case "signedOut": try peer.reply(to: refresh, result: ["account": NSNull()])
                        case "invalidPayload": try peer.reply(to: refresh, result: [:])
                        case "connectionClosed": return
                        default:
                            try peer.send(["id": #require(refresh["id"]), "error": [
                                "code": -32000, "message": failure == "authentication" ? "codex account authentication required" : "upstream network request failed"
                            ]])
                        }
                    }
                }
            }
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        if hasCache {
            guard case .data = await service.fetchOutcome().outcome else {
                Issue.record("Initial read did not populate the cache")
                return
            }
        }
        let result = await service.fetchOutcome()
        #expect(result.trace.rateLimits == nil && result.trace.usage == nil)
        #expect(result.trace.failureStage == .snapshot)
        if !hasCache {
            #expect(result.trace.connection == .new)
        }
        switch result.outcome {
        case .notLoggedIn: #expect(failure == "signedOut")
        case .authenticationRequired: #expect(failure == "authentication")
        case .initializationFailed: #expect(["serverError", "invalidPayload", "connectionClosed"].contains(failure))
        default: Issue.record("Authentication refresh failure was hidden or misclassified")
        }
        try server.finish()
    }

    @Test(arguments: ["authentication", "invalidPayload", "unsupportedVersion"], [false, true])
    func connectionFailurePreservesFetchStageAndOperationError(failure: String, readsConfiguration: Bool) async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": failure == "unsupportedVersion" ? "codex/0.161.0" : "codex/0.162.0"])
            guard failure != "unsupportedVersion" else { return }
            #expect(try peer.readMessage()["method"] as? String == "initialized")
            let account = try peer.readMessage()
            #expect(account["method"] as? String == "account/read")
            if failure == "authentication" {
                try peer.send(["id": #require(account["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
            } else {
                try peer.reply(to: account, result: [:])
            }
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        if readsConfiguration {
            do {
                _ = try await service.areTUINotificationsEnabled()
                Issue.record("Configuration read accepted an uninitialized connection")
            } catch let error as CodexStatusError {
                switch error {
                case .authenticationRequired: #expect(failure == "authentication")
                case .unsupportedVersion: #expect(failure == "unsupportedVersion")
                case .serverConnectionClosed: #expect(failure == "invalidPayload")
                default: Issue.record("Unexpected connection error")
                }
            }
        } else {
            let result = await service.fetchOutcome()
            switch result.outcome {
            case .authenticationRequired: #expect(failure == "authentication")
            case .unsupportedVersion: #expect(failure == "unsupportedVersion")
            case .initializationFailed: #expect(failure == "invalidPayload")
            default: Issue.record("Unexpected fetch outcome")
            }
            #expect(result.trace.failureStage == (failure == "authentication" ? .account : .connect))
            #expect(result.trace.connection == nil)
        }
        #expect(await service.currentConnectionInfo() == nil)
        try server.finish()
    }

    @Test func autoResetAuthenticationRetryKeepsCreditIdentityAndFreshAccountCheck() async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            #expect(try peer.readMessage()["method"] as? String == "initialized")
            for refreshToken in [false, false] {
                let account = try peer.readMessage()
                #expect(account["method"] as? String == "account/read")
                #expect((account["params"] as? [String: Any])?["refreshToken"] as? Bool == refreshToken)
                try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
            }
            let first = try peer.readMessage()
            #expect(first["method"] as? String == "account/rateLimitResetCredit/consume")
            try peer.send(["id": #require(first["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
            for refreshToken in [true, false] {
                let account = try peer.readMessage()
                #expect(account["method"] as? String == "account/read")
                #expect((account["params"] as? [String: Any])?["refreshToken"] as? Bool == refreshToken)
                try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
            }
            let retried = try peer.readMessage()
            #expect(retried["method"] as? String == "account/rateLimitResetCredit/consume")
            for request in [first, retried] {
                let params = try #require(request["params"] as? [String: String])
                #expect(params == ["creditId": "credit", "idempotencyKey": "same-key"])
            }
            try peer.reply(to: retried, result: ["outcome": "reset"])
            let account = try peer.readMessage()
            #expect(account["method"] as? String == "account/read")
            try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
            let limits = try peer.readMessage()
            #expect(limits["method"] as? String == "account/rateLimits/read")
            try peer.reply(to: limits, result: ["rateLimits": [:], "rateLimitResetCredits": ["availableCount": 0, "credits": []]])
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        let result = try await service.consumeResetCredit(
            id: "credit", idempotencyKey: "same-key", expectedAccountIdentity: "apiKey\u{0}",
            expirationDate: Date().addingTimeInterval(600),
            budget: AppServerRequestBudget(deadline: Date().addingTimeInterval(5))
        )
        #expect(result.outcome == .reset)
        #expect(result.refreshedRead?.availableCount == 0)
        try server.finish()
    }

    @Test func missingAccountFieldIsNotSignedOut() throws {
        #expect(throws: DecodingError.self) { try TestFixtures.decode(AccountReadResponse.self, "{}") }
        #expect(try TestFixtures.decode(AccountReadResponse.self, "{\"account\":null}").account == nil)
    }
}
