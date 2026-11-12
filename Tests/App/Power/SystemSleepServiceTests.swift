import Foundation
import IOKit
import IOKit.pwr_mgt
import Testing

struct SystemSleepServiceTests {
    @Test(arguments: [false, true])
    func failedReleaseRemainsPendingUntilRetrySucceeds(userActivityFails: Bool) async throws {
        var releaseCounts: [IOPMAssertionID: Int] = [:]
        var didDeclare = false
        let failedID: IOPMAssertionID = userActivityFails ? 2 : 1
        let service = SystemSleepService(
            createAssertion: { _, _, id in id = 1
                return kIOReturnSuccess
            },
            releaseAssertion: { id in
                releaseCounts[id, default: 0] += 1
                return id == failedID && releaseCounts[id] == 1 ? kIOReturnError : kIOReturnSuccess
            },
            declareActivity: { _, id in id = 2
                didDeclare = true
                return kIOReturnSuccess
            },
            displayReleaseRetryDelays: [.milliseconds(1)]
        )
        #expect(service.beginPreventingDisplaySleep() == kIOReturnSuccess)
        #expect(try await waitForCondition(timeout: .milliseconds(100), pollInterval: .milliseconds(1)) { didDeclare })
        #expect(didDeclare)
        #expect(service.endPreventingDisplaySleep() == kIOReturnError)
        #expect(!service.isPreventingDisplaySleep)
        #expect(service.hasDisplaySleepResources)
        #expect(try await waitForCondition(timeout: .milliseconds(100), pollInterval: .milliseconds(1)) { !service.hasDisplaySleepResources })
        #expect(!service.hasDisplaySleepResources)
        #expect(releaseCounts[failedID] == 2)
        #expect(releaseCounts[userActivityFails ? 1 : 2] == 1)
    }

    @Test func releaseRetriesAreBoundedAndNotFoundCountsAsReleased() async throws {
        var releases = 0
        var result = kIOReturnError
        let service = SystemSleepService(
            createAssertion: { _, _, id in id = 1
                return kIOReturnSuccess
            },
            releaseAssertion: { _ in releases += 1
                return result
            },
            declareActivity: { _, _ in kIOReturnSuccess },
            displayReleaseRetryDelays: [.milliseconds(1), .milliseconds(1)]
        )
        #expect(service.beginPreventingDisplaySleep() == kIOReturnSuccess)
        #expect(service.endPreventingDisplaySleep() == kIOReturnError)
        #expect(try await waitForCondition(timeout: .milliseconds(100), pollInterval: .milliseconds(1)) { releases >= 3 })
        try await Task.sleep(for: .milliseconds(10))
        #expect(releases == 3)
        #expect(service.hasDisplaySleepResources)
        result = kIOReturnNotFound
        #expect(service.endPreventingDisplaySleep() == kIOReturnSuccess)
        #expect(!service.hasDisplaySleepResources)
    }

    @Test func reenableCancelsPendingRelease() async throws {
        var releases = 0
        let service = SystemSleepService(
            createAssertion: { _, _, id in id = 1
                return kIOReturnSuccess
            },
            releaseAssertion: { _ in releases += 1
                return kIOReturnError
            },
            declareActivity: { _, _ in kIOReturnSuccess },
            displayReleaseRetryDelays: [.milliseconds(1)]
        )
        #expect(service.beginPreventingDisplaySleep() == kIOReturnSuccess)
        #expect(service.endPreventingDisplaySleep() == kIOReturnError)
        #expect(service.beginPreventingDisplaySleep() == kIOReturnSuccess)
        try await Task.sleep(for: .milliseconds(10))
        #expect(releases == 1)
        #expect(service.isPreventingDisplaySleep)
        _ = service.endPreventingDisplaySleep()
    }
}
