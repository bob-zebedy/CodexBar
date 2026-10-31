import Foundation
import os
import Testing
import UserNotifications

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
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
        let first = try session.perform(AppServerRequest<Value>(method: "probe"))
        #expect(first.value == 1)
        #expect(try session.pollChanges() == .account)
        #expect(try session.pollChanges() == nil)
        let second = try session.perform(AppServerRequest<Value>(method: "probe"))
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
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { model.loadState == .notLoggedIn && !model.isRefreshing })
        let maintenanceClock = model.autoRefreshCountdownStartedAt
        #expect(await service.currentConnectionInfo()?.version == "0.162.0")
        login.signal()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { model.snapshot != nil && !model.isRefreshing })
        #expect(model.lastRefreshTrigger == .accountNotification)
        #expect(model.autoRefreshCountdownStartedAt == maintenanceClock)
        logout.signal()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { model.loadState == .notLoggedIn && !model.isRefreshing })
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
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { entered.withLock { $0 } })
        for _ in 0 ..< 20 {
            model.receiveAccountChange(.rateLimits)
            model.receiveAccountChange(.account)
        }
        respond.signal()
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { !model.isRefreshing && model.autoRefreshCountdownStartedAt != nil })
        let maintenanceClock = model.autoRefreshCountdownStartedAt
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { model.lastRefreshTrigger == .accountNotification && !model.isRefreshing })
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
        #expect(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(10)) { changes.contains(.account) })
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

    @Test(arguments: ["window", "account", "logout"])
    func returningQuotaWindowStartsAFreshObservation(disappearance: String) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "Notification.isEnabled")
        preferences.defaults.set(false, forKey: "Notification.isLowQuotaEnabled")
        let phase = OSAllocatedUnfairLock(initialState: 0)
        let resetsAt = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let server = try SharedServerFixture { peer in
            while let request = try? peer.readMessage() {
                let phase = phase.withLock { $0 }
                switch request["method"] as? String {
                case "initialize": try peer.reply(to: request, result: ["userAgent": "codex/0.162.0"])
                case "initialized": continue
                case "account/read":
                    let account: Any = phase == 1 && disappearance == "logout" ? NSNull() : [
                        "type": "chatgpt", "email": phase == 1 && disappearance == "account" ? "b@example.test" : "a@example.test", "planType": "pro"
                    ]
                    try peer.reply(to: request, result: ["account": account])
                case "account/rateLimits/read":
                    let limits: [String: Any] = phase == 1 && disappearance == "window" ? [:] : [
                        "primary": ["usedPercent": phase == 1 ? 20 : 95, "resetsAt": resetsAt, "windowDurationMins": 300]
                    ]
                    try peer.reply(to: request, result: ["rateLimits": limits])
                case "account/usage/read":
                    try peer.reply(to: request, result: ["summary": [:]])
                    if phase == 2 {
                        return
                    }
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let settings = NotificationSettings(defaults: preferences.defaults, readAuthorizationStatus: { .authorized })
        let model = CodexStatusViewModel(service: CodexStatusService(socketURL: server.url, logStorage: nil), defaults: preferences.defaults)
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
        )
        var delivered = 0
        let notifications = NotificationService(
            settings: settings, statusViewModel: model, activityMonitor: monitor, defaults: preferences.defaults,
            delivery: .init(setDelegate: { _ in }, add: { _ in delivered += 1 }, remove: { _ in }), openMenuSurface: {}
        )
        notifications.start()
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { settings.canDeliver })
        for current in 0 ... 2 {
            phase.withLock { $0 = current }
            model.refresh(trigger: .manual)
            try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
            if current == 0 {
                #expect(model.snapshot?.limits.first?.windows.first?.remainingPercent == 5)
                #expect(delivered == 0)
            } else if current == 1 {
                settings.setLowQuotaEnabled(true)
            }
        }
        #expect(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) { delivered == 1 })
        withExtendedLifetime(notifications) {}
        try server.finish()
    }

    @Test(arguments: [false, true], [false, true])
    func quotaSubmissionFailureRespectsWindowLifecycle(lowQuota: Bool, reappears: Bool) async throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "Notification.isEnabled")
        preferences.defaults.set(10, forKey: "Notification.lowQuotaThresholdPercent")
        let phase = OSAllocatedUnfairLock(initialState: 0)
        let resetsAt = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let server = try SharedServerFixture { peer in
            while let request = try? peer.readMessage() {
                let phase = phase.withLock { $0 }
                switch request["method"] as? String {
                case "initialize": try peer.reply(to: request, result: ["userAgent": "codex/0.162.0"])
                case "initialized": continue
                case "account/read":
                    try peer.reply(to: request, result: ["account": ["type": "chatgpt", "email": "a@example.test", "planType": "pro"]])
                case "account/rateLimits/read":
                    let limits: [String: Any] = phase == 2 ? [:] : [
                        "primary": ["usedPercent": phase == 0 ? 20 : (lowQuota ? 95 : 0), "resetsAt": resetsAt, "windowDurationMins": 300]
                    ]
                    try peer.reply(to: request, result: ["rateLimits": limits])
                case "account/usage/read":
                    try peer.reply(to: request, result: ["summary": [:]])
                    if phase == 4 {
                        return
                    }
                default: Issue.record("Unexpected request")
                }
            }
        }
        defer { server.close() }
        let settings = NotificationSettings(defaults: preferences.defaults, readAuthorizationStatus: { .authorized })
        let model = CodexStatusViewModel(service: CodexStatusService(socketURL: server.url, logStorage: nil), defaults: preferences.defaults)
        let monitor = ActivityMonitor(
            protectionSettings: ProtectionSettings(defaults: preferences.defaults),
            protectionStore: ProtectionStore(directoryURL: directory.url), activityDataDirectoryURL: directory.url
        )
        let release = TestCheckpoint()
        defer { release.signal() }
        var attempts = 0
        var delivered = 0
        let notifications = NotificationService(
            settings: settings, statusViewModel: model, activityMonitor: monitor, defaults: preferences.defaults,
            delivery: .init(setDelegate: { _ in }, add: { _ in
                attempts += 1
                if attempts <= 2 {
                    await release.wait()
                    throw CocoaError(.fileWriteUnknown)
                }
                delivered += 1
            }, remove: { _ in }), openMenuSurface: {}
        )
        notifications.start()
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { settings.canDeliver })
        func refresh(_ current: Int) async throws {
            phase.withLock { $0 = current }
            model.refresh(trigger: .manual)
            try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { !model.isRefreshing })
        }
        try await refresh(0)
        #expect(attempts == 0)
        try await refresh(1)
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { attempts == 1 })
        settings.setLowQuotaThresholdPercent(15)
        if reappears {
            try await refresh(2)
            try await refresh(3)
        }
        release.signal()
        try #require(try await waitForCondition(timeout: .seconds(3), pollInterval: .milliseconds(5)) { attempts == 2 })
        try await refresh(4)
        #expect(try await waitForCondition(timeout: .seconds(1), pollInterval: .milliseconds(5)) { delivered == 1 } == !reappears)
        #expect(attempts == (reappears ? 2 : 3))
        withExtendedLifetime(notifications) {}
        try server.finish()
    }

    private nonisolated struct Value: Decodable { let value: Int }
}
