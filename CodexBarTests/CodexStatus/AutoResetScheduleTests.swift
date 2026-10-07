import Foundation
import Testing

struct AutoResetScheduleTests {
    private let start = Date(timeIntervalSince1970: 1800000000)

    @Test(arguments: [900.0, 1800, 21600])
    func initialBudgetSurvivesRepeatedRefreshesAndEntersAdaptiveCooldown(_ lead: Double) throws {
        let expiration = start.addingTimeInterval(lead)
        var schedule = AutoResetSchedule()
        for (index, offset) in [0.0, 15, 45, 105, 225].enumerated() {
            let now = start.addingTimeInterval(offset)
            let observed1 = schedule.begin(expirationDate: expiration, leadTime: lead, now: now)
            let attempt = try #require(observed1)
            #expect(attempt.phase == .initial)
            schedule.finish(attempt, transientFailure: true, leadTime: lead, now: now)
            if index < 4 {
                let expected = start.addingTimeInterval([15, 45, 105, 225][index])
                for _ in 0 ..< 20 {
                    let observed2 = schedule.plan(expirationDate: expiration, leadTime: lead, now: now)
                    #expect(observed2?.evaluationDate == expected)
                }
            }
        }
        let cooldownEnd = start.addingTimeInterval(300 + min(900, lead / 3))
        let observed3 = schedule.plan(expirationDate: expiration, leadTime: lead, now: start.addingTimeInterval(300))
        #expect(observed3?.evaluationDate == cooldownEnd)
        let observed4 = schedule.begin(expirationDate: expiration, leadTime: lead, now: cooldownEnd.addingTimeInterval(-1))
        #expect(observed4 == nil)
        let observed5 = schedule.begin(expirationDate: expiration, leadTime: lead, now: cooldownEnd)
        let attempt = try #require(observed5)
        #expect(attempt.phase == .cooldown)
        schedule.finish(attempt, transientFailure: true, leadTime: lead, now: cooldownEnd)
        let observed6 = schedule.plan(expirationDate: expiration, leadTime: lead, now: cooldownEnd)
        #expect(observed6?.wakeDate == expiration.addingTimeInterval(-180))
    }

    @Test func nothingToResetWaitsWithoutOpeningFaultWindowAgain() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(900)
        let observed7 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start)
        let attempt = try #require(observed7)
        schedule.finish(attempt, transientFailure: false, leadTime: 900, now: start)
        let observed8 = schedule.plan(expirationDate: expiration, leadTime: 900, now: start)
        #expect(observed8?.evaluationDate == start.addingTimeInterval(300))
        let observed9 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(300))
        let next = try #require(observed9)
        #expect(next.phase == .cooldown)
    }

    @Test func finalRoundOverridesCooldownAndStopsBeforeExpiration() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(900)
        let observed10 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start)
        let initial = try #require(observed10)
        schedule.finish(initial, transientFailure: false, leadTime: 900, now: start)
        let observed11 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(600))
        let ordinary = try #require(observed11)
        schedule.finish(ordinary, transientFailure: true, leadTime: 900, now: start.addingTimeInterval(600))
        let observed12 = schedule.plan(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(600))
        #expect(observed12?.evaluationDate == expiration.addingTimeInterval(-180))
        for offset in [720.0, 735, 765] {
            let now = start.addingTimeInterval(offset)
            let observed13 = schedule.begin(expirationDate: expiration, leadTime: 900, now: now)
            let attempt = try #require(observed13)
            #expect(attempt.phase == .final)
            #expect(attempt.deadline == expiration.addingTimeInterval(-60))
            schedule.finish(attempt, transientFailure: true, leadTime: 900, now: now)
        }
        let observed14 = schedule.plan(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(800))
        #expect(observed14 == nil)
        let observed15 = schedule.begin(expirationDate: expiration, leadTime: 900, now: expiration.addingTimeInterval(-60))
        #expect(observed15 == nil)
    }

    @Test func lateLaunchUsesOnlyRemainingFinalBudget() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(100)
        let observed16 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start)
        let attempt = try #require(observed16)
        #expect(attempt.phase == .final)
        schedule.finish(attempt, transientFailure: true, leadTime: 900, now: start.addingTimeInterval(35))
        let observed17 = schedule.plan(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(35))
        #expect(observed17 == nil)
    }

    @Test func inFlightOrdinaryAttemptCoversFinalPoint() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(900)
        let observed18 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(710))
        let attempt = try #require(observed18)
        schedule.finish(attempt, transientFailure: true, leadTime: 900, now: start.addingTimeInterval(730))
        schedule.coverFinalIfNeeded(attempt, expirationDate: expiration, transientFailure: false, now: start.addingTimeInterval(730))
        let observed19 = schedule.plan(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(730))
        #expect(observed19 == nil)
    }

    @Test func faultAcrossFinalPointUsesRemainingFinalAttempts() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(900)
        let value = schedule.begin(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(710))
        let attempt = try #require(value)
        schedule.finish(attempt, transientFailure: true, leadTime: 900, now: start.addingTimeInterval(730))
        schedule.coverFinalIfNeeded(attempt, expirationDate: expiration, transientFailure: true, now: start.addingTimeInterval(730))
        let plan = schedule.plan(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(730))
        #expect(plan?.evaluationDate == start.addingTimeInterval(745))
        let next = schedule.begin(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(745))
        #expect(next?.phase == .final)
    }

    @Test func extendingExpirationRearmsFinalWithoutRestoringInitialBudget() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(180)
        let observed20 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start)
        let attempt = try #require(observed20)
        schedule.finish(attempt, transientFailure: false, leadTime: 900, now: start)
        let extended = start.addingTimeInterval(1800)
        let observed21 = schedule.plan(expirationDate: extended, leadTime: 900, now: start)
        let plan = try #require(observed21)
        #expect(plan.wakeDate == extended.addingTimeInterval(-180))
        let observed22 = schedule.begin(expirationDate: extended, leadTime: 900, now: plan.evaluationDate)
        let next = try #require(observed22)
        #expect(next.phase != .initial)
    }

    @Test func clockRollbackCannotReopenFinishedFinalRound() throws {
        var schedule = AutoResetSchedule()
        let expiration = start.addingTimeInterval(180)
        let observed23 = schedule.begin(expirationDate: expiration, leadTime: 900, now: start)
        let attempt = try #require(observed23)
        schedule.finish(attempt, transientFailure: false, leadTime: 900, now: start)
        let observed24 = schedule.plan(expirationDate: expiration, leadTime: 900, now: start.addingTimeInterval(-600))
        #expect(observed24 == nil)
    }
}
