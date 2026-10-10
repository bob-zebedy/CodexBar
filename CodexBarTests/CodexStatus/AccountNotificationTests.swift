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
        var events: [ActivityRecord] = []
        let reader = AppServerActivityReader(
            lifecycleCache: SessionLifecycleCache(), socketURL: server.url, logStorage: nil,
            tokenHistory: TokenHistoryStore(directoryURL: directory.url),
            recorder: ActivityRecorder(directoryURL: directory.url),
            onAccountChange: { changes.append($0) },
            onBatch: { batch in
                switch batch {
                case let .live(values), let .snapshotEvents(values): events += values
                default: break
                }
            }
        )
        await reader.start()
        try await eventually { changes.contains(.account) }
        await reader.stop()
        #expect(events.isEmpty)
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
        let outcome = await service.fetchOutcome().outcome
        switch outcome {
        case .notLoggedIn: #expect(result == "signedOut")
        case .authenticationRequired: #expect(result == "authentication")
        case .initializationFailed: #expect(["serverError", "invalidPayload", "connectionClosed"].contains(result))
        default: Issue.record("Unexpected fetch outcome")
        }
        try server.finish()
    }
}
