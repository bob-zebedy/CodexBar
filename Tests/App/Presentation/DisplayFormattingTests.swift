import Foundation
import Testing

struct DisplayFormattingTests {
    @Test(arguments: [
        (1000, 1.0, "K"),
        (1049, 1.0, "K"),
        (1050, 1.1, "K"),
        (999949, 999.9, "K"),
        (999950, 1000.0, "K"),
        (1000000, 1.0, "M"),
        (554400000, 554.4, "M"),
        (999950000, 1000.0, "M"),
        (1000000000, 1.0, "B"),
        (1100000000, 1.1, "B")
    ])
    func tokenCountsPreserveUnitThresholdsAndJoinLocalizedNumbers(tokens: Int, number: Double, unit: String) {
        let expectedNumber = number.formatted(.number.precision(.fractionLength(0 ... 1)).locale(.autoupdatingCurrent))
        #expect(TokenCountFormatter.text(from: tokens) == expectedNumber + unit)
    }

    @Test(arguments: [Int.min, -1000, -1, 0, 999])
    func tokenCountsBelowAbbreviationThresholdStayPlainIntegers(tokens: Int) {
        #expect(TokenCountFormatter.text(from: tokens) == String(tokens))
    }

    @Test(arguments: [
        (-1.0, "0 秒"),
        (0.0, "0 秒"),
        (21.0, "21 秒"),
        (59.6, "1 分钟 0 秒"),
        (80.0, "1 分钟 20 秒"),
        (3599.6, "1 小时 0 分钟"),
        (4800.0, "1 小时 20 分钟")
    ])
    func chineseDurationSeparatesValuesAndUnits(interval: TimeInterval, expected: String) {
        #expect(CodexDurationFormat.activityText(for: interval, locale: Locale(identifier: "zh_CN")) == expected)
    }

    @Test(arguments: ["en_US", "fr_FR"])
    func durationPreservesExistingLocalizedSeparators(localeIdentifier: String) {
        let locale = Locale(identifier: localeIdentifier)
        let expected = Duration.seconds(80).formatted(
            .units(allowed: [.minutes, .seconds], width: .abbreviated, zeroValueUnits: .show(length: 1), fractionalPart: .hide(rounded: .down))
                .locale(locale)
        )
        #expect(CodexDurationFormat.activityText(for: 80, locale: locale) == expected)
    }

    @Test(arguments: ["2026-02-29", "2026-04-31", "2026-00-10", "2026-13-01", "2026-1-01", "2026-01-1", "0000-01-01", "garbage"])
    func dateKeysRejectImpossibleOrNoncanonicalDates(_ value: String) {
        #expect(CodexDateFormat.dayDate(from: value) == nil)
    }

    @Test func leapDayRoundTrips() throws {
        let date = try #require(CodexDateFormat.dayDate(from: "2024-02-29"))
        #expect(CodexDateFormat.dayString(from: date) == "2024-02-29")
    }
}
