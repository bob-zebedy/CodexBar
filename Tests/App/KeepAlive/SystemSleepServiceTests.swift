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
        for _ in 0 ..< 100 where !didDeclare {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(didDeclare)
        #expect(service.endPreventingDisplaySleep() == kIOReturnError)
        #expect(!service.isPreventingDisplaySleep)
        #expect(service.hasDisplaySleepResources)
        for _ in 0 ..< 100 where service.hasDisplaySleepResources {
            try await Task.sleep(for: .milliseconds(1))
        }
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
        for _ in 0 ..< 100 where releases < 3 {
            try await Task.sleep(for: .milliseconds(1))
        }
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
