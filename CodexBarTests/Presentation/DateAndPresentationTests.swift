import Foundation
import Testing

struct DateAndPresentationTests {
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

    @Test func weekGridStartsSundayAndLeavesFutureDaysBlankAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        calendar.firstWeekday = 2
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let grid = CodexWeekGrid.dates(columnCount: 2, today: today, calendar: calendar)
        #expect(grid.count == 14)
        #expect(grid.compactMap(\.self).count == 10)
        #expect(try calendar.component(.weekday, from: #require(grid[0])) == 1)
        #expect(try calendar.component(.weekday, from: #require(grid[7])) == 1)
        #expect(grid.suffix(4).allSatisfy { $0 == nil })
        #expect(CodexWeekGrid.dates(columnCount: 0, today: today, calendar: calendar).isEmpty)
    }

    @Test func heatmapDistinguishesTodayPendingFromUnavailableAndHistoricalZero() throws {
        let today = try #require(CodexDateFormat.dayDate(from: "2026-09-15"))
        let summary = try TestFixtures.decode(UsageSummary.self, "{}")
        let usage = CodexUsageSnapshot(summary: summary, dailyBuckets: [])
        let grid = UsageHeatmapDay.grid(usage: usage, history: .empty, columnCount: 2, today: today).compactMap(\.self)
        #expect(grid.last?.tokenState == .pending)
        #expect(grid.first?.tokenState == .available(0))
        let unavailable = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 2, today: today).compactMap(\.self)
        #expect(unavailable.allSatisfy { $0.tokenState == .unavailable })
    }

    @Test func statusItemTerminalExpiresAtTenSecondsWhileCardKeepsHistory() {
        let completion = ActivityCompletion(id: UUID(), projectName: nil, modelName: nil, effort: nil, completedAt: TestFixtures.now, duration: 30)
        let snapshot = ActivitySnapshot(waitingTasks: [], runningTasks: [], recentCompletions: [completion], recentTerminations: [])
        #expect(snapshot.statusItemActivity(at: TestFixtures.now.addingTimeInterval(9.999)) == .completed(completion))
        #expect(snapshot.statusItemActivity(at: TestFixtures.now.addingTimeInterval(10)) == .idle)
        #expect(snapshot.primaryActivity == .completed(completion))
        #expect(snapshot.hasTaskCenterContent)
        #expect(!snapshot.hasActiveTasks)
    }

    @Test func waitingTaskTakesPriorityOverRunningTask() {
        let waiting = task()
        let running = task()
        let snapshot = ActivitySnapshot(waitingTasks: [waiting], runningTasks: [running], recentCompletions: [], recentTerminations: [])
        #expect(snapshot.primaryActivity == .waiting(waiting))
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.statusItemActivityExpiration == nil)
    }

    private func task() -> ActivityTaskSnapshot {
        ActivityTaskSnapshot(
            id: UUID(),
            projectName: nil, modelName: nil, effort: nil,
            startedAt: TestFixtures.now, stateChangedAt: TestFixtures.now,
            activeSubagentCount: nil
        )
    }

    @Test(arguments: [false, true])
    func accountFailureKeepsLiveTaskIcon(waiting: Bool) {
        let task = task()
        let activity = ActivitySnapshot(
            waitingTasks: waiting ? [task] : [], runningTasks: waiting ? [] : [task],
            recentCompletions: [], recentTerminations: []
        )
        let state = StatusIconState(usesErrorImage: true, ordinaryUsageAllowed: nil, progress: nil, activity: activity)
        #expect(state.symbolName(at: TestFixtures.now) == (waiting ? "person.badge.key.fill" : "person.badge.clock.fill"))
        let idle = StatusIconState(usesErrorImage: true, ordinaryUsageAllowed: nil, progress: nil, activity: .empty)
        #expect(idle.symbolName(at: TestFixtures.now) == "person.slash.fill")
    }
}
