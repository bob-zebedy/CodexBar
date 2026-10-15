import Foundation
import Testing

struct LowQuotaObservationTests {
    @Test func newCycleCanNotifyWithoutAnObservedRecoveryAboveThreshold() {
        var observation = NotificationService.LowQuotaObservation()
        let reset = TestFixtures.now
        let firstLow = observation.observe(remainingPercent: 5, resetsAt: reset, thresholdPercent: 10)
        #expect(firstLow)
        let sameCycleLow = observation.observe(remainingPercent: 4, resetsAt: reset, thresholdPercent: 10)
        #expect(!sameCycleLow)
        let nextReset = reset.addingTimeInterval(18000)
        let nextCycleLow = observation.observe(remainingPercent: 5, resetsAt: nextReset, thresholdPercent: 10)
        #expect(nextCycleLow)
        let repeatedNextCycleLow = observation.observe(remainingPercent: 3, resetsAt: nextReset, thresholdPercent: 10)
        #expect(!repeatedNextCycleLow)
    }

    @Test(arguments: [-60.0, -1, 0, 1, 60])
    func resetTimeDriftDoesNotCreateANewCycle(_ drift: TimeInterval) {
        var observation = NotificationService.LowQuotaObservation()
        let firstLow = observation.observe(remainingPercent: 5, resetsAt: TestFixtures.now, thresholdPercent: 10)
        #expect(firstLow)
        let driftedLow = observation.observe(remainingPercent: 5, resetsAt: TestFixtures.now.addingTimeInterval(drift), thresholdPercent: 10)
        #expect(!driftedLow)
        let returnedLow = observation.observe(remainingPercent: 4, resetsAt: TestFixtures.now, thresholdPercent: 10)
        #expect(!returnedLow)
    }

    @Test func thresholdCrossingAndMissingResetRetainTheirMeaning() {
        var observation = NotificationService.LowQuotaObservation()
        let aboveThreshold = observation.observe(remainingPercent: 50, resetsAt: TestFixtures.now, thresholdPercent: 10)
        #expect(!aboveThreshold)
        let atThreshold = observation.observe(remainingPercent: 10, resetsAt: TestFixtures.now, thresholdPercent: 10)
        #expect(atThreshold)
        let missingReset = observation.observe(remainingPercent: 5, resetsAt: nil, thresholdPercent: 10)
        #expect(!missingReset)
        let restoredReset = observation.observe(remainingPercent: 5, resetsAt: TestFixtures.now, thresholdPercent: 10)
        #expect(restoredReset)
    }

    @Test func newCycleAboveThresholdArmsALaterCrossing() {
        var observation = NotificationService.LowQuotaObservation()
        let nextReset = TestFixtures.now.addingTimeInterval(18000)
        let results = [
            observation.observe(remainingPercent: 5, resetsAt: TestFixtures.now, thresholdPercent: 10),
            observation.observe(remainingPercent: 80, resetsAt: nextReset, thresholdPercent: 10),
            observation.observe(remainingPercent: 10, resetsAt: nextReset, thresholdPercent: 10),
            observation.observe(remainingPercent: 9, resetsAt: nextReset, thresholdPercent: 10)
        ]
        #expect(results == [true, false, true, false])
    }
}
