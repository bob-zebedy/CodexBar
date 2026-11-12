import Foundation
import Testing

struct PowerHelperPackageValidationTests {
    @Test func concurrentRefreshesShareOneInspection() async throws {
        let probe = PackageInspectionProbe()
        let validation = PowerHelperPackageValidation { await probe.inspect() }
        defer { validation.cancel() }
        var completions = 0
        validation.onValidated = { completions += 1 }
        validation.refresh()
        validation.refresh()
        try await probe.waitForRequests(1)
        #expect(validation.fingerprint == nil)
        await probe.finish(0, fingerprint: "current")
        #expect(try await waitForCondition(timeout: .milliseconds(500), pollInterval: .milliseconds(5)) { completions != 0 })
        #expect(await probe.count == 1)
        #expect(completions == 1)
        #expect(validation.fingerprint == "current")
    }

    @Test func cancelledInspectionCannotOverwriteReplacement() async throws {
        let probe = PackageInspectionProbe()
        let validation = PowerHelperPackageValidation { await probe.inspect() }
        defer { validation.cancel() }
        var completions = 0
        validation.onValidated = { completions += 1 }
        validation.refresh()
        try await probe.waitForRequests(1)
        validation.cancel()
        validation.refresh()
        try await probe.waitForRequests(2)
        await probe.finish(1, fingerprint: "new")
        #expect(try await waitForCondition(timeout: .milliseconds(500), pollInterval: .milliseconds(5)) { completions != 0 })
        await probe.finish(0, fingerprint: "old")
        try await Task.sleep(for: .milliseconds(20))
        #expect(validation.fingerprint == "new")
        #expect(completions == 1)
    }

    @Test func failedInspectionClearsPreviousFingerprint() async throws {
        let probe = PackageInspectionProbe()
        let validation = PowerHelperPackageValidation { await probe.inspect() }
        defer { validation.cancel() }
        validation.refresh()
        try await probe.waitForRequests(1)
        await probe.finish(0, fingerprint: "valid")
        #expect(try await waitForCondition(timeout: .milliseconds(500), pollInterval: .milliseconds(5)) { validation.fingerprint != nil })
        #expect(validation.fingerprint == "valid")
        validation.refresh()
        #expect(validation.fingerprint == nil)
        try await probe.waitForRequests(2)
        await probe.finish(1, fingerprint: "invalid", issue: .invalid)
        #expect(try await waitForCondition(timeout: .milliseconds(500), pollInterval: .milliseconds(5)) { validation.issue != nil })
        #expect(validation.issue == .invalid)
        #expect(validation.fingerprint == nil)
    }

    @Test func registrationUsesInspectedFingerprintAndPreservesPendingReset() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        _ = PowerHelperConfiguration.beginUpdate(defaults: defaults, requiresSleepReset: true, fingerprint: "first")
        PowerHelperConfiguration.recordRegistration(defaults: defaults, status: .enabled, fingerprint: "first")
        #expect(!PowerHelperConfiguration.registrationNeedsRefresh(defaults: defaults, fingerprint: "first"))
        #expect(PowerHelperConfiguration.registrationNeedsRefresh(defaults: defaults, fingerprint: "second"))
        _ = PowerHelperConfiguration.beginUpdate(defaults: defaults, requiresSleepReset: false, fingerprint: "second")
        PowerHelperConfiguration.recordRegistration(defaults: defaults, status: .requiresApproval, fingerprint: "second")
        PowerHelperConfiguration.completeUpdate("first", defaults: defaults)
        #expect(PowerHelperConfiguration.pendingUpdateIdentifier(defaults: defaults, fingerprint: "second") == "second")
        PowerHelperConfiguration.completeUpdate("second", defaults: defaults)
        #expect(PowerHelperConfiguration.pendingUpdateIdentifier(defaults: defaults, fingerprint: "second") == nil)
    }
}

private actor PackageInspectionProbe {
    private var replies: [CheckedContinuation<PowerHelperPackageSnapshot, Never>?] = []
    var count: Int {
        replies.count
    }

    func inspect() async -> PowerHelperPackageSnapshot {
        await withCheckedContinuation { replies.append($0) }
    }

    func finish(_ index: Int, fingerprint: String, issue: PowerHelperPackageIssue? = nil) {
        replies[index]?.resume(returning: PowerHelperPackageSnapshot(issue: issue, fingerprint: fingerprint))
        replies[index] = nil
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0 ..< 100 where replies.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(replies.count == count)
    }
}
