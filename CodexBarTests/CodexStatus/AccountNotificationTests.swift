import Foundation
import os
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AccountNotificationTests {
    @Test func repeatedNotificationsKeepFirstDeadlineAndRespectCooldown() {
        var schedule = AccountNotificationSchedule()
        let now = ContinuousClock.now
        schedule.receive(.rateLimits, at: now)
        schedule.receive(.rateLimits, at: now.advanced(by: .milliseconds(500)))
        #expect(schedule.readyAt == now.advanced(by: .seconds(1)))
        schedule.didStartRefresh(at: now.advanced(by: .seconds(1)))
        schedule.receive(.rateLimits, at: now.advanced(by: .seconds(2)))
        schedule.receive(.rateLimits, at: now.advanced(by: .seconds(9)))
        #expect(schedule.readyAt == now.advanced(by: .seconds(11)))
    }

    @Test func accountChangeBypassesQuotaCooldownAndKeepsPriority() {
        var schedule = AccountNotificationSchedule()
        let now = ContinuousClock.now
        schedule.didStartRefresh(at: now)
        schedule.receive(.rateLimits, at: now)
        schedule.receive(.account, at: now.advanced(by: .seconds(1)))
        schedule.receive(.rateLimits, at: now.advanced(by: .seconds(1)))
        #expect(schedule.readyAt == now.advanced(by: .seconds(2)))
    }

    @Test func anyRefreshConsumesEarlierSignalsButKeepsLaterChanges() {
        var schedule = AccountNotificationSchedule()
        let now = ContinuousClock.now
        schedule.receive(.account, at: now)
        schedule.didStartRefresh(at: now)
        #expect(schedule.readyAt == nil)
        schedule.receive(.rateLimits, at: now.advanced(by: .seconds(2)))
        #expect(schedule.readyAt == now.advanced(by: .seconds(10)))
        schedule.receive(.account, at: now.advanced(by: .seconds(3)))
        #expect(schedule.readyAt == now.advanced(by: .seconds(4)))
    }

    @Test func accountSessionCoalescesInterleavedAndIdleNotifications() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            for _ in 0 ..< 20 {
                try peer.send(["method": "account/rateLimits/updated", "params": [:]])
            }
            try peer.send(["method": "account/updated", "params": [:]])
            try peer.reply(to: request, result: ["value": 1])
            let next = try peer.readMessage()
            try peer.reply(to: next, result: ["value": 2])
            try peer.send(["method": "account/rateLimits/updated", "params": [:]])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let session = try AccountSession(socketURL: server.url, logStorage: nil)
        defer { session.close() }
        let first = try session.request("probe", as: Value.self)
        #expect(first.value == 1)
        #expect(try session.pollChanges() == .account)
        #expect(try session.pollChanges() == nil)
        let second = try session.request("probe", as: Value.self)
        #expect(second.value == 2)
        #expect(try session.pollChanges() == .rateLimits)
        #expect(try session.pollChanges() == nil)
        release.signal()
        try server.finish()
    }

    @Test func signedOutConnectionReceivesLoginAndRefreshesWithoutNewHandshake() async throws {
        let release = DispatchSemaphore(value: 0)
        let login = DispatchSemaphore(value: 0)
        let logout = DispatchSemaphore(value: 0)
        defer { release.signal()
            login.signal()
            logout.signal()
        }
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            #expect(try peer.readMessage()["method"] as? String == "initialized")
            let initialAccount = try peer.readMessage()
            try peer.reply(to: initialAccount, result: ["account": NSNull()])
            #expect(login.wait(timeout: .now() + 5) == .success)
            try peer.send(["method": "account/updated", "params": ["authMode": "apikey"]])
            let account = try peer.readMessage()
            #expect(account["method"] as? String == "account/read")
            try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
            for method in ["account/rateLimits/read", "account/usage/read"] {
                let request = try peer.readMessage()
                #expect(request["method"] as? String == method)
                try peer.send(["id": #require(request["id"]), "error": ["code": -32601, "message": "unsupported"]])
            }
            #expect(logout.wait(timeout: .now() + 5) == .success)
            try peer.send(["method": "account/updated", "params": ["authMode": NSNull()]])
            let signedOut = try peer.readMessage()
            #expect(signedOut["method"] as? String == "account/read")
            try peer.reply(to: signedOut, result: ["account": NSNull()])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let suite = "AccountNotificationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        let model = CodexStatusViewModel(service: service, defaults: defaults)
        model.startAutoRefresh()
        try await eventually { model.loadState == .notLoggedIn && !model.isRefreshing }
        let maintenanceClock = model.autoRefreshCountdownStartedAt
        #expect(await service.currentConnectionInfo()?.version == "0.162.0")
        login.signal()
        try await eventually { model.snapshot != nil && !model.isRefreshing }
        #expect(model.lastRefreshTrigger == .accountNotification)
        #expect(model.autoRefreshCountdownStartedAt == maintenanceClock)
        logout.signal()
        try await eventually { model.loadState == .notLoggedIn && !model.isRefreshing }
        #expect(model.snapshot == nil)
        #expect(model.autoRefreshCountdownStartedAt == maintenanceClock)
        #expect(await service.currentConnectionInfo()?.version == "0.162.0")
        release.signal()
        try server.finish()
    }

    @Test func notificationDuringRefreshRunsOnceAfterwardWithoutMovingMaintenanceClock() async throws {
        let entered = OSAllocatedUnfairLock(initialState: false)
        let respond = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { respond.signal()
            release.signal()
        }
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let first = try peer.readMessage()
            entered.withLock { $0 = true }
            #expect(respond.wait(timeout: .now() + 5) == .success)
            try peer.reply(to: first, result: ["account": NSNull()])
            let second = try peer.readMessage()
            #expect(second["method"] as? String == "account/read")
            try peer.reply(to: second, result: ["account": NSNull()])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        let suite = "AccountNotificationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CodexStatusViewModel(service: CodexStatusService(socketURL: server.url, logStorage: nil), defaults: defaults)
        model.refresh(trigger: .manual)
        try await eventually { entered.withLock { $0 } }
        for _ in 0 ..< 20 {
            model.receiveAccountChange(.rateLimits)
            model.receiveAccountChange(.account)
        }
        respond.signal()
        try await eventually { !model.isRefreshing && model.autoRefreshCountdownStartedAt != nil }
        let maintenanceClock = model.autoRefreshCountdownStartedAt
        try await eventually { model.lastRefreshTrigger == .accountNotification && !model.isRefreshing }
        #expect(model.autoRefreshCountdownStartedAt == maintenanceClock)
        #expect(model.loadState == .notLoggedIn)
        release.signal()
        try server.finish()
    }

    @Test func closedConnectionRequestsRecoveryOnlyOnce() async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let account = try peer.readMessage()
            try peer.reply(to: account, result: ["account": NSNull()])
            try peer.sendRaw(Data(), opcode: 8)
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        _ = await service.fetchOutcome()
        #expect(await service.pollAccountChanges() == .account)
        #expect(await service.pollAccountChanges() == nil)
        #expect(await service.currentConnectionInfo() == nil)
        try server.finish()
    }

    @Test func activityConnectionForwardsAccountChangesWithoutActivityEvents() async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let loaded = try peer.readMessage()
            try peer.send(["method": "account/rateLimits/updated", "params": [:]])
            try peer.send(["method": "account/updated", "params": [:]])
            try peer.reply(to: loaded, result: ["data": []])
            _ = release.wait(timeout: .now() + 5)
        }
        defer { server.close() }
        var changes: [AccountChange] = []
        var updates: [ActivityUpdate] = []
        let reader = AppServerActivityReader(
            probe: ActivityReaderProbe(), socketURL: server.url, logStorage: nil,
            tokenUsageHistory: TokenUsageHistoryStore(directoryURL: directory.url),
            activityDataRecorder: ActivityDataRecorder(directoryURL: directory.url),
            onAccountChange: { changes.append($0) },
            onBatch: { updates.append($0) }
        )
        await reader.start()
        try await eventually { changes.contains(.account) }
        await reader.stop()
        #expect(!updates.isEmpty)
        #expect(updates.allSatisfy {
            $0.graph.tasks.isEmpty && $0.graph.completions.isEmpty && $0.graph.terminations.isEmpty
                && $0.transitions.isEmpty && $0.terminalEvents.isEmpty
        })
        #expect(!FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("Events").path))
        release.signal()
        try server.finish()
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 300 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition was not reached")
    }

    private nonisolated struct Value: Decodable { let value: Int }
}

extension AccountNotificationTests {
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

    @Test(arguments: ["serverError", "invalidPayload", "signedOut"])
    func failedAuthenticationRefreshCannotFallBackToSupplementalCache(failure: String) async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            for round in 0 ..< 2 {
                let account = try peer.readMessage()
                #expect(account["method"] as? String == "account/read")
                try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
                let limits = try peer.readMessage()
                #expect(limits["method"] as? String == "account/rateLimits/read")
                if round == 0 {
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
                        default:
                            try peer.send(["id": #require(refresh["id"]), "error": ["code": -32000, "message": "upstream network request failed"]])
                        }
                    }
                }
            }
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        guard case .data = await service.fetchOutcome().outcome else {
            Issue.record("Initial read did not populate the cache")
            return
        }
        let result = await service.fetchOutcome()
        #expect(result.trace.rateLimits == nil && result.trace.usage == nil)
        #expect(result.trace.failureStage == .snapshot)
        switch result.outcome {
        case .notLoggedIn: #expect(failure == "signedOut")
        case .initializationFailed: #expect(failure != "signedOut")
        default: Issue.record("Authentication refresh failure was hidden by cached data")
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

    @Test(arguments: ["signedOut", "authentication", "serverError", "invalidPayload", "connectionClosed"])
    func refreshFailureKeepsAuthenticationSeparateFromReadFailure(result: String) async throws {
        let server = try SharedServerFixture { peer in
            let initialize = try peer.readMessage()
            try peer.reply(to: initialize, result: ["userAgent": "codex/0.162.0"])
            _ = try peer.readMessage()
            let account = try peer.readMessage()
            try peer.reply(to: account, result: ["account": ["type": "apiKey"]])
            let limits = try peer.readMessage()
            #expect(limits["method"] as? String == "account/rateLimits/read")
            try peer.send(["id": #require(limits["id"]), "error": ["code": -32000, "message": "codex account authentication required"]])
            for _ in 0 ..< (result == "serverError" ? 2 : 1) {
                let refresh = try peer.readMessage()
                #expect(refresh["method"] as? String == "account/read")
                #expect((refresh["params"] as? [String: Any])?["refreshToken"] as? Bool == true)
                switch result {
                case "signedOut": try peer.reply(to: refresh, result: ["account": NSNull()])
                case "invalidPayload": try peer.reply(to: refresh, result: [:])
                case "connectionClosed": return
                default:
                    try peer.send(["id": #require(refresh["id"]), "error": [
                        "code": -32000, "message": result == "authentication" ? "codex account authentication required" : "upstream network request failed"
                    ]])
                }
            }
        }
        defer { server.close() }
        let service = CodexStatusService(socketURL: server.url, logStorage: nil)
        let fetched = await service.fetchOutcome()
        #expect(fetched.trace.failureStage == .snapshot)
        #expect(fetched.trace.connection == .new)
        switch fetched.outcome {
        case .notLoggedIn: #expect(result == "signedOut")
        case .authenticationRequired: #expect(result == "authentication")
        case .initializationFailed: #expect(["serverError", "invalidPayload", "connectionClosed"].contains(result))
        default: Issue.record("Unexpected fetch outcome")
        }
        try server.finish()
    }
}
