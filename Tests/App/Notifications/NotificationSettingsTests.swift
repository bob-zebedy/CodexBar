import Foundation
import Testing
import UserNotifications

struct NotificationSettingsTests {
    @Test(arguments: [UNAuthorizationStatus.authorized, .provisional])
    func temporaryFailurePreservesPreferencesAndRecovers(status: UNAuthorizationStatus) async throws {
        let fixture = try AuthorizationFixture(status: status)
        defer { fixture.cleanUp() }
        try await fixture.confirmAuthorization()
        fixture.settings.setTaskCompletionEnabled(false)

        fixture.client.status = .notDetermined
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.client.pendingSleep != nil }
        #expect(fixture.settings.authorizationState == .unavailable)
        #expect(fixture.settings.isEnabled)
        #expect(fixture.preferences.defaults.bool(forKey: "Notification.isEnabled"))
        #expect(!fixture.settings.isTaskCompletionEnabled)
        #expect(!fixture.settings.canShowOptions)
        #expect(!fixture.settings.needsAuthorization)
        #expect(!fixture.settings.canDeliver)
        #expect(fixture.settings.authorizationMessage == String(localized: "settings.notifications.system.permission-unavailable"))

        fixture.client.status = status
        fixture.client.resumeSleep()
        try await fixture.wait { fixture.settings.canDeliver }
        #expect(fixture.settings.authorizationMessage == nil)
        #expect(fixture.client.delays == [.seconds(1)])
        #expect(fixture.client.requestCount == 0)
        #expect(!fixture.settings.isTaskCompletionEnabled)
    }

    @Test(arguments: [UNAuthorizationStatus.notDetermined, .authorized, .denied])
    func enablingReadsCurrentStatusBeforeRequesting(status: UNAuthorizationStatus) async throws {
        let fixture = try AuthorizationFixture(status: status, enabled: false)
        defer { fixture.cleanUp() }
        #expect(!fixture.settings.needsAuthorization)
        #expect(fixture.settings.authorizationMessage == nil)
        fixture.settings.setEnabled(true)
        let expectedState: NotificationSettings.AuthorizationState = status == .denied ? .denied : .authorized
        try await fixture.wait { fixture.settings.authorizationState == expectedState }
        #expect(fixture.client.requestCount == (status == .notDetermined ? 1 : 0))
        #expect(fixture.settings.isEnabled)
        #expect(fixture.settings.needsAuthorization == (status == .denied))
        #expect(fixture.settings.canDeliver == (status != .denied))
    }

    @Test func ordinaryRefreshNeverRequestsInitialPermission() async throws {
        let fixture = try AuthorizationFixture(status: .notDetermined)
        defer { fixture.cleanUp() }
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.settings.authorizationState == .notDetermined }
        #expect(fixture.settings.isEnabled)
        #expect(fixture.settings.needsAuthorization)
        #expect(fixture.settings.authorizationMessage == String(localized: "settings.notifications.system.permission-disabled"))
        #expect(!fixture.settings.canDeliver)
        #expect(fixture.client.requestCount == 0)
        #expect(fixture.client.delays.isEmpty)
    }

    @Test func rejectingInitialPromptIsAConfirmedDenial() async throws {
        let fixture = try AuthorizationFixture(status: .notDetermined, enabled: false)
        defer { fixture.cleanUp() }
        fixture.client.requestGranted = false
        fixture.settings.setEnabled(true)
        try await fixture.wait { fixture.settings.authorizationState == .denied }
        #expect(fixture.settings.needsAuthorization)
        #expect(!fixture.settings.canDeliver)
        #expect(!fixture.settings.canShowOptions)
        #expect(fixture.client.requestCount == 1)
        #expect(fixture.client.delays.isEmpty)
    }

    @Test func explicitDenialClosesOptionsWithoutChangingPreference() async throws {
        let fixture = try AuthorizationFixture()
        defer { fixture.cleanUp() }
        try await fixture.confirmAuthorization()
        fixture.client.status = .denied
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.settings.authorizationState == .denied }
        #expect(fixture.settings.isEnabled)
        #expect(fixture.settings.needsAuthorization)
        #expect(!fixture.settings.canShowOptions)
        #expect(!fixture.settings.canDeliver)
        #expect(fixture.client.requestCount == 0)
        #expect(fixture.client.delays.isEmpty)
    }

    @Test func recoveryHasFiniteRetriesAndCanRestartOnLaterRefresh() async throws {
        let fixture = try AuthorizationFixture()
        defer { fixture.cleanUp() }
        try await fixture.confirmAuthorization()
        fixture.client.suspendsSleep = false
        fixture.client.status = .notDetermined
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.client.readCount == 5 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.client.readCount == 5)
        #expect(fixture.client.delays == [.seconds(1), .seconds(3), .seconds(10)])
        #expect(fixture.settings.authorizationState == .unavailable)
        #expect(!fixture.settings.canDeliver)
        #expect(fixture.client.requestCount == 0)

        fixture.client.status = .authorized
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.settings.canDeliver }
        #expect(fixture.client.readCount == 6)
    }

    @Test func denialAfterFailureReplacesUnconfirmedMessage() async throws {
        let fixture = try AuthorizationFixture()
        defer { fixture.cleanUp() }
        try await fixture.confirmAuthorization()
        fixture.client.status = .notDetermined
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.client.pendingSleep != nil }
        #expect(fixture.settings.authorizationMessage == String(localized: "settings.notifications.system.permission-unavailable"))
        #expect(!fixture.settings.needsAuthorization)

        fixture.client.status = .denied
        fixture.client.resumeSleep()
        try await fixture.wait { fixture.settings.authorizationState == .denied }
        #expect(fixture.settings.authorizationMessage == String(localized: "settings.notifications.system.permission-disabled"))
        #expect(fixture.settings.needsAuthorization)
        #expect(!fixture.settings.canShowOptions)
        #expect(!fixture.settings.canDeliver)
        #expect(fixture.settings.isEnabled)
        #expect(fixture.preferences.defaults.bool(forKey: "Notification.isEnabled"))
        #expect(fixture.client.requestCount == 0)
    }

    @Test func togglingAfterFailureDoesNotRequestPermissionAgain() async throws {
        let fixture = try AuthorizationFixture()
        defer { fixture.cleanUp() }
        try await fixture.confirmAuthorization()
        fixture.client.status = .notDetermined
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.client.pendingSleep != nil }
        fixture.settings.setEnabled(false)
        fixture.client.resumeSleep()
        fixture.settings.setEnabled(true)
        try await fixture.wait { fixture.client.delays.count == 2 }
        #expect(fixture.settings.authorizationState == .unavailable)
        #expect(fixture.client.requestCount == 0)
        #expect(fixture.settings.isEnabled)
        #expect(!fixture.settings.canShowOptions)
        #expect(!fixture.settings.canDeliver)
        #expect(!fixture.settings.needsAuthorization)
    }

    @Test func failedAuthorizationRequestIsUnavailableUntilConfirmed() async throws {
        let fixture = try AuthorizationFixture(status: .notDetermined, enabled: false)
        defer { fixture.cleanUp() }
        fixture.client.requestError = NSError(domain: UNErrorDomain, code: 1)
        fixture.settings.setEnabled(true)
        try await fixture.wait { fixture.client.pendingSleep != nil }
        #expect(fixture.settings.authorizationState == .unavailable)
        #expect(fixture.settings.isEnabled)
        #expect(!fixture.settings.needsAuthorization)
        #expect(!fixture.settings.canDeliver)
        #expect(!fixture.settings.canShowOptions)
        #expect(fixture.settings.authorizationMessage == String(localized: "settings.notifications.system.permission-unavailable"))

        fixture.settings.setEnabled(false)
        fixture.client.resumeSleep()
        fixture.settings.setEnabled(true)
        try await fixture.wait { fixture.client.delays.count == 2 }
        #expect(fixture.client.requestCount == 1)
        fixture.client.status = .authorized
        fixture.client.resumeSleep()
        try await fixture.wait { fixture.settings.canDeliver }
        #expect(fixture.settings.canShowOptions)
    }

    @Test func staleQueryCannotOverwriteNewerDecision() async throws {
        let fixture = try AuthorizationFixture()
        defer { fixture.cleanUp() }
        fixture.client.suspendsRead = true
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.client.pendingRead != nil }

        fixture.client.suspendsRead = false
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.settings.canDeliver }
        fixture.client.resumeRead(.denied)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.settings.canDeliver)
        #expect(!fixture.settings.needsAuthorization)
    }

    @Test func disablingCancelsRecoveryAndLaterReadsDoNotEnablePreference() async throws {
        let fixture = try AuthorizationFixture()
        defer { fixture.cleanUp() }
        try await fixture.confirmAuthorization()
        fixture.client.status = .notDetermined
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.client.pendingSleep != nil }
        fixture.settings.setEnabled(false)
        #expect(fixture.settings.authorizationMessage == nil)
        fixture.client.status = .authorized
        fixture.client.resumeSleep()
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.client.readCount == 2)

        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.settings.authorizationState == .authorized }
        #expect(!fixture.settings.isEnabled)
        #expect(!fixture.preferences.defaults.bool(forKey: "Notification.isEnabled"))
        #expect(!fixture.settings.canDeliver)
        #expect(!fixture.settings.canShowOptions)
    }

    @Test func refreshDuringEnableQueryPreservesRequestIntent() async throws {
        let fixture = try AuthorizationFixture(status: .notDetermined, enabled: false)
        defer { fixture.cleanUp() }
        fixture.client.suspendsRead = true
        fixture.settings.setEnabled(true)
        try await fixture.wait { fixture.client.pendingRead != nil }
        fixture.client.suspendsRead = false
        fixture.settings.refreshAuthorizationStatus()
        try await fixture.wait { fixture.settings.canDeliver }
        fixture.client.resumeRead(.denied)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fixture.client.requestCount == 1)
        #expect(fixture.settings.canDeliver)
    }

    @Test func pendingSystemPromptSurvivesRefreshWithoutOverwritingManualDisable() async throws {
        let fixture = try AuthorizationFixture(status: .notDetermined, enabled: false)
        defer { fixture.cleanUp() }
        fixture.client.suspendsRequest = true
        fixture.settings.setEnabled(true)
        try await fixture.wait { fixture.client.pendingRequest != nil }
        fixture.settings.refreshAuthorizationStatus()
        fixture.settings.setEnabled(false)
        fixture.settings.setEnabled(true)
        fixture.settings.setEnabled(false)
        fixture.settings.refreshAuthorizationStatus()
        #expect(fixture.client.readCount == 1)
        #expect(fixture.client.requestCount == 1)

        fixture.client.status = .authorized
        fixture.client.resumeRequest()
        try await fixture.wait { fixture.settings.authorizationState == .authorized }
        #expect(!fixture.settings.isEnabled)
        #expect(!fixture.preferences.defaults.bool(forKey: "Notification.isEnabled"))
        #expect(!fixture.settings.canDeliver)
        #expect(!fixture.settings.canShowOptions)
    }
}

private final class AuthorizationFixture {
    let preferences: TestPreferences
    let client: AuthorizationClient
    let settings: NotificationSettings

    init(status: UNAuthorizationStatus = .authorized, enabled: Bool = true) throws {
        preferences = try TestPreferences()
        preferences.defaults.set(enabled, forKey: "Notification.isEnabled")
        client = AuthorizationClient(status: status)
        settings = NotificationSettings(
            defaults: preferences.defaults,
            readAuthorizationStatus: client.read,
            requestSystemAuthorization: client.request,
            sleep: client.sleep
        )
    }

    func confirmAuthorization() async throws {
        settings.refreshAuthorizationStatus()
        try await wait { self.settings.canDeliver }
    }

    func wait(_ condition: () -> Bool) async throws {
        try #require(try await waitForCondition(timeout: .seconds(2), pollInterval: .milliseconds(5), condition))
    }

    func cleanUp() {
        settings.setEnabled(false)
        client.resumeRead(.notDetermined)
        client.resumeSleep()
        client.resumeRequest()
        preferences.remove()
    }
}

private final class AuthorizationClient {
    var status: UNAuthorizationStatus
    var requestError: NSError?
    var requestGranted = true
    var suspendsRead = false
    var suspendsSleep = true
    var suspendsRequest = false
    var readCount = 0
    var requestCount = 0
    var delays: [Duration] = []
    var pendingRead: CheckedContinuation<UNAuthorizationStatus, Never>?
    var pendingSleep: CheckedContinuation<Void, Never>?
    var pendingRequest: CheckedContinuation<Bool, any Error>?

    init(status: UNAuthorizationStatus) {
        self.status = status
    }

    func read() async -> UNAuthorizationStatus {
        readCount += 1
        if suspendsRead {
            return await withCheckedContinuation { pendingRead = $0 }
        }
        return status
    }

    func request() async throws -> Bool {
        requestCount += 1
        if suspendsRequest {
            return try await withCheckedThrowingContinuation { pendingRequest = $0 }
        }
        if let requestError {
            throw requestError
        }
        status = requestGranted ? .authorized : .denied
        return requestGranted
    }

    func sleep(for duration: Duration) async throws {
        delays.append(duration)
        if suspendsSleep {
            await withCheckedContinuation { pendingSleep = $0 }
        }
        try Task.checkCancellation()
    }

    func resumeRead(_ status: UNAuthorizationStatus) {
        let continuation = pendingRead
        pendingRead = nil
        continuation?.resume(returning: status)
    }

    func resumeSleep() {
        let continuation = pendingSleep
        pendingSleep = nil
        continuation?.resume()
    }

    func resumeRequest() {
        let continuation = pendingRequest
        pendingRequest = nil
        continuation?.resume(returning: true)
    }
}
