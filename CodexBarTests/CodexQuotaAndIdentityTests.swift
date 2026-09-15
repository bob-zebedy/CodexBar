import Foundation
import Testing

struct CodexQuotaAndIdentityTests {
    @Test func resetCandidatesRequireExplicitStatusTypeAndExpiration() throws {
        let summary = try TestFixtures.decode(RateLimitResetCreditsSummary.self, """
        {"availableCount":5,"credits":[
          {"id":"valid","status":"available","resetType":"codexRateLimits","expiresAt":200},
          {"id":"used","status":"redeemed","resetType":"codexRateLimits","expiresAt":300},
          {"id":"other","status":"available","resetType":"other","expiresAt":400},
          {"id":"missing-expiration","status":"available","resetType":"codexRateLimits"},
          {"id":"expired","status":"available","resetType":"codexRateLimits","expiresAt":100}
        ]}
        """)
        #expect(summary.autoResetCandidates?.map(\.id) == ["valid", "expired"])
        #expect(summary.availableExpirationDates(now: Date(timeIntervalSince1970: 100)) == [200, 400].map { Date(timeIntervalSince1970: $0) })
    }

    @Test func unavailableCreditDetailsDifferFromExplicitEmptyList() throws {
        let missing = try TestFixtures.decode(RateLimitResetCreditsSummary.self, #"{"availableCount":1}"#)
        let empty = try TestFixtures.decode(RateLimitResetCreditsSummary.self, #"{"availableCount":0,"credits":[]}"#)
        #expect(missing.autoResetCandidates == nil)
        #expect(empty.autoResetCandidates == [])
        #expect(empty.availableExpirationDates(now: TestFixtures.now) == nil)
    }

    @Test func quotaWindowsClampPercentageAndKeepMissingDistinctFromZero() {
        for (used, remaining) in [(-10, 100), (0, 100), (35, 65), (100, 0), (125, 0)] {
            let window = QuotaWindow(kind: .primary, windowDurationMins: 300, usedPercent: used, resetsAt: nil)
            #expect(window.remainingPercent == remaining)
            #expect(window.hasData)
        }
        #expect(!QuotaWindow(kind: .primary, windowDurationMins: nil, usedPercent: nil, resetsAt: nil).hasData)
    }

    @Test func primaryLimitPrecedesAlphabeticalLimitsAndUsesMatchingCredits() throws {
        let response = try TestFixtures.decode(AccountRateLimitsResponse.self, """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":99}},
         "rateLimitsByLimitId":{
          "alpha":{"primary":{"usedPercent":10}},
          "codex":{"primary":{"usedPercent":20},"credits":{"balance":"12","hasCredits":true,"unlimited":false}},
          "empty":{},
          "zeta":{"secondary":{"usedPercent":30}}
         }}
        """)
        let snapshot = try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: response)
        #expect(snapshot.limits.map(\.limitId) == ["codex", "alpha", "zeta"])
        #expect(snapshot.codexLimit?.window(ofKind: .primary)?.usedPercent == 20)
        #expect(snapshot.credits?.balance == "12")
    }

    @Test func validAccountWithoutQuotaIsDisplayableButNotTrusted() throws {
        let snapshot = try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: nil)
        #expect(snapshot.limits.isEmpty)
        #expect(!snapshot.hasTrustedData)
        #expect(throws: (any Error).self) {
            try CodexQuotaSnapshot(accountResponse: AccountReadResponse(account: nil), rateLimitsResponse: nil)
        }
    }

    @Test func staleQuotaCannotCountAsTrustedData() throws {
        let response = try TestFixtures.decode(AccountRateLimitsResponse.self, #"{"rateLimits":{"primary":{"usedPercent":10}}}"#)
        #expect(try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: response).hasTrustedData)
        #expect(try !CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: response, isRateLimitsStale: true).hasTrustedData)
    }

    @Test func usageBucketsSumDuplicatesAndPreserveUnavailableState() throws {
        let summary = try TestFixtures.decode(UsageSummary.self, "{}")
        let date = try #require(CodexDateFormat.dayDate(from: "2026-09-15"))
        let usage = CodexUsageSnapshot(summary: summary, dailyBuckets: [DailyUsageBucket(startDate: "2026-09-15", tokens: 2), DailyUsageBucket(startDate: "2026-09-15", tokens: 3)])
        #expect(usage.tokenCount(on: date) == 5)
        #expect(!CodexUsageSnapshot(summary: summary, dailyBuckets: nil).hasAppServerData)
        #expect(CodexUsageSnapshot(summary: summary, dailyBuckets: []).hasAppServerData)
    }

    @Test func autoResetUUIDMatchesIndependentUUIDv5Vector() {
        #expect(AutoResetIdentity.idempotencyKey(forCreditID: "credit-123") == "d0a84206-ba45-5a3b-9287-d1e14138cc5d")
        #expect(AutoResetIdentity.idempotencyKey(forCreditID: "credit-123") != AutoResetIdentity.idempotencyKey(forCreditID: "credit-124"))
    }

    @Test func accountIdentityNormalizesEmailAndSeparatesAccountTypes() {
        let first = CodexAccount(type: "chatgpt", email: " User@Example.COM \n", planType: "plus")
        let second = CodexAccount(type: "chatgpt", email: "user@example.com", planType: "pro")
        #expect(AutoResetIdentity.accountIdentity(for: first) == AutoResetIdentity.accountIdentity(for: second))
        #expect(AutoResetIdentity.accountIdentity(for: first) == "chatgpt\u{0}user@example.com")
        #expect(AutoResetIdentity.notificationToken(accountIdentity: "ab", creditID: "c") != AutoResetIdentity.notificationToken(accountIdentity: "a", creditID: "bc"))
    }

    private var accountResponse: AccountReadResponse {
        AccountReadResponse(account: CodexAccount(type: "chatgpt", email: "user@example.com", planType: "plus"))
    }
}
