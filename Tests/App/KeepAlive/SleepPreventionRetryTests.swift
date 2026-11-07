import Foundation
import Testing

struct SleepPreventionRetryTests {
    @Test(arguments: [false, true])
    func activityUpdatesCannotBypassBackoffOrExhaustedBudget(requested: Bool) {
        var retry = SleepPreventionRetry()
        let delays: [Duration] = [.seconds(2), .seconds(4)]
        #expect(retry.allowsRequest(isRetry: false))
        retry.recordFailure(for: requested)
        for delay in delays {
            #expect(!retry.allowsRequest(isRetry: false))
            let scheduledDelay = retry.nextDelay(for: requested, delays: delays)
            #expect(scheduledDelay == delay)
            #expect(retry.allowsRequest(isRetry: true))
            retry.recordFailure(for: requested)
        }
        let exhaustedDelay = retry.nextDelay(for: requested, delays: delays)
        #expect(exhaustedDelay == nil)
        #expect(!retry.allowsRequest(isRetry: false))
        #expect(retry.requested == requested)
        #expect(retry.attempt == delays.count)
    }

    @Test(arguments: [false, true])
    func changedFailureTargetStartsFreshBudget(requested: Bool) {
        var retry = SleepPreventionRetry()
        let delays: [Duration] = [.seconds(2)]
        let firstDelay = retry.nextDelay(for: requested, delays: delays)
        #expect(firstDelay == .seconds(2))
        retry.recordFailure(for: requested)
        let exhaustedDelay = retry.nextDelay(for: requested, delays: delays)
        #expect(exhaustedDelay == nil)
        #expect(!retry.allowsRequest(isRetry: false))

        retry.recordFailure(for: !requested)
        #expect(retry.requested == !requested)
        #expect(retry.attempt == 0)
        #expect(!retry.allowsRequest(isRetry: false))
        let changedTargetDelay = retry.nextDelay(for: !requested, delays: delays)
        #expect(changedTargetDelay == .seconds(2))
        #expect(retry.attempt == 1)
    }
}
