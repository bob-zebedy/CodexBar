import Foundation
import Testing

struct CodexQuotaAndIdentityTests {
    @MainActor
    @Test func ordinaryUsagePermissionReachesStatusIconWithoutInferringFromQuota() throws {
        let presentation = StatusItemIconPresentation()
        let cases: [(field: String, allowed: Bool?)] = [
            (#""ordinaryUsageAllowed":false,"#, false),
            (#""ordinaryUsageAllowed":true,"#, true),
            (#""ordinaryUsageAllowed":false,"#, false),
            (#""ordinaryUsageAllowed":null,"#, nil),
            (#""ordinaryUsageAllowed":false,"#, false),
            ("", nil)
        ]
        for (field, allowed) in cases {
            let response = try TestFixtures.decode(AccountRateLimitsResponse.self, """
            {\(field)"rateLimits":{"primary":{"usedPercent":0}}}
            """)
            let snapshot = try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: response)
            #expect(snapshot.ordinaryUsageAllowed == allowed)
            for percent: Int? in [100, 0, nil] {
                presentation.update(
                    symbolName: "person.fill",
                    ordinaryUsageAllowed: snapshot.ordinaryUsageAllowed,
                    percent: percent,
                    isStale: false,
                    animated: false
                )
                #expect(presentation.state.isOrdinaryUsageRestricted == (allowed == false))
            }
        }
    }

    @Test func cachedQuotaRetainsLastExplicitOrdinaryUsagePermission() throws {
        let response = try TestFixtures.decode(AccountRateLimitsResponse.self, #"{"ordinaryUsageAllowed":false,"rateLimits":{}}"#)
        let snapshot = try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: response, isRateLimitsStale: true)
        #expect(snapshot.ordinaryUsageAllowed == false)
        let empty = try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: nil)
        #expect(empty.ordinaryUsageAllowed == nil)
    }

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

    @Test func quotaWindowLabelsUseLargestExactUnitAndFourWeekMonths() {
        let cases: [(minutes: Int, expected: String)] = [
            (1, "1 Mins"),
            (59, "59 Mins"),
            (60, "Hourly"),
            (90, "90 Mins"),
            (300, "5 Hours"),
            (1439, "1439 Mins"),
            (1440, "Daily"),
            (1441, "1441 Mins"),
            (2160, "36 Hours"),
            (6 * 1440, "6 Days"),
            (7 * 1440, "Weekly"),
            (8 * 1440, "8 Days"),
            (14 * 1440, "2 Weeks"),
            (21 * 1440, "3 Weeks"),
            (28 * 1440, "Monthly"),
            (30 * 1440, "30 Days"),
            (35 * 1440, "5 Weeks"),
            (56 * 1440, "2 Months"),
            (57 * 1440, "57 Days")
        ]
        for (minutes, expected) in cases {
            let window = QuotaWindow(kind: .secondary, windowDurationMins: minutes, usedPercent: 0, resetsAt: nil)
            #expect(window.label == expected)
        }
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
        #expect(response.rateLimits.limitID == "codex")
        #expect(response.rateLimitsByLimitID?.count == 4)
        let snapshot = try CodexQuotaSnapshot(accountResponse: accountResponse, rateLimitsResponse: response)
        #expect(snapshot.limits.map(\.limitID) == ["codex", "alpha", "zeta"])
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
        #expect(!CodexUsageSnapshot(summary: summary, dailyBuckets: nil).hasDailyUsageBuckets)
        #expect(CodexUsageSnapshot(summary: summary, dailyBuckets: []).hasDailyUsageBuckets)
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
