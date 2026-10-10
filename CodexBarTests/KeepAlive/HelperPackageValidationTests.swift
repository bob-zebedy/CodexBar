import Foundation
import Testing

struct HelperPackageValidationTests {
    @Test func concurrentRefreshesShareOneInspection() async throws {
        let probe = PackageInspectionProbe()
        let validation = HelperPackageValidation { await probe.inspect() }
        defer { validation.cancel() }
        var completions = 0
        validation.onValidated = { completions += 1 }
        validation.refresh()
        validation.refresh()
        try await probe.waitForRequests(1)
        #expect(validation.fingerprint == nil)
        await probe.finish(0, fingerprint: "current")
        for _ in 0 ..< 100 where completions == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await probe.count == 1)
        #expect(completions == 1)
        #expect(validation.fingerprint == "current")
    }

    @Test func cancelledInspectionCannotOverwriteReplacement() async throws {
        let probe = PackageInspectionProbe()
        let validation = HelperPackageValidation { await probe.inspect() }
        defer { validation.cancel() }
        var completions = 0
        validation.onValidated = { completions += 1 }
        validation.refresh()
        try await probe.waitForRequests(1)
        validation.cancel()
        validation.refresh()
        try await probe.waitForRequests(2)
        await probe.finish(1, fingerprint: "new")
        for _ in 0 ..< 100 where completions == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        await probe.finish(0, fingerprint: "old")
        try await Task.sleep(for: .milliseconds(20))
        #expect(validation.fingerprint == "new")
        #expect(completions == 1)
    }

    @Test func failedInspectionClearsPreviousFingerprint() async throws {
        let probe = PackageInspectionProbe()
        let validation = HelperPackageValidation { await probe.inspect() }
        defer { validation.cancel() }
        validation.refresh()
        try await probe.waitForRequests(1)
        await probe.finish(0, fingerprint: "valid")
        for _ in 0 ..< 100 where validation.fingerprint == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(validation.fingerprint == "valid")
        validation.refresh()
        #expect(validation.fingerprint == nil)
        try await probe.waitForRequests(2)
        await probe.finish(1, fingerprint: "invalid", issue: .invalid)
        for _ in 0 ..< 100 where validation.issue == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(validation.issue == .invalid)
        #expect(validation.fingerprint == nil)
    }

    @Test func registrationUsesInspectedFingerprintAndPreservesPendingReset() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let defaults = preferences.defaults
        _ = HelperConfiguration.beginUpdate(defaults: defaults, requiresSleepReset: true, fingerprint: "first")
        HelperConfiguration.recordRegistration(defaults: defaults, status: .enabled, fingerprint: "first")
        #expect(!HelperConfiguration.registrationNeedsRefresh(defaults: defaults, fingerprint: "first"))
        #expect(HelperConfiguration.registrationNeedsRefresh(defaults: defaults, fingerprint: "second"))
        _ = HelperConfiguration.beginUpdate(defaults: defaults, requiresSleepReset: false, fingerprint: "second")
        HelperConfiguration.recordRegistration(defaults: defaults, status: .requiresApproval, fingerprint: "second")
        HelperConfiguration.completeUpdate("first", defaults: defaults)
        #expect(HelperConfiguration.pendingUpdateIdentifier(defaults: defaults, fingerprint: "second") == "second")
        HelperConfiguration.completeUpdate("second", defaults: defaults)
        #expect(HelperConfiguration.pendingUpdateIdentifier(defaults: defaults, fingerprint: "second") == nil)
    }
}

private actor PackageInspectionProbe {
    private var replies: [CheckedContinuation<HelperPackageSnapshot, Never>?] = []
    var count: Int {
        replies.count
    }

    func inspect() async -> HelperPackageSnapshot {
        await withCheckedContinuation { replies.append($0) }
    }

    func finish(_ index: Int, fingerprint: String, issue: HelperPackageIssue? = nil) {
        replies[index]?.resume(returning: HelperPackageSnapshot(issue: issue, fingerprint: fingerprint))
        replies[index] = nil
    }

    func waitForRequests(_ count: Int) async throws {
        for _ in 0 ..< 100 where replies.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(replies.count == count)
    }
}
