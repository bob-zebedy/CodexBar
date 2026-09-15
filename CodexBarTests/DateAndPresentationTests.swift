import Foundation
import Testing

struct DateAndPresentationTests {
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
        let grid = UsageHeatmapDay.grid(usage: usage, workflow: .empty, showsWorkflow: true, columnCount: 2, today: today).compactMap(\.self)
        #expect(grid.last?.tokenState == .pending)
        #expect(grid.first?.tokenState == .available(0))
        let unavailable = UsageHeatmapDay.grid(usage: nil, workflow: .empty, showsWorkflow: true, columnCount: 2, today: today).compactMap(\.self)
        #expect(unavailable.allSatisfy { $0.tokenState == .unavailable })
        let hiddenToday = UsageHeatmapDay.grid(usage: usage, workflow: .empty, showsWorkflow: false, columnCount: 2, today: today).compactMap(\.self)
        #expect(!hiddenToday.contains { $0.startDate == "2026-09-15" })
    }

    @Test func statusItemTerminalExpiresAtTenSecondsWhileCardKeepsHistory() {
        let completion = CodexActivityCompletion(id: UUID(), isAnonymous: false, projectName: nil, modelName: nil, effort: nil, completedAt: TestFixtures.now, duration: 30)
        let snapshot = CodexActivitySnapshot(waitingTasks: [], runningTasks: [], recentCompletions: [completion], recentTerminations: [])
        #expect(snapshot.statusItemActivity(at: TestFixtures.now.addingTimeInterval(9.999)) == .completed(completion))
        #expect(snapshot.statusItemActivity(at: TestFixtures.now.addingTimeInterval(10)) == .idle)
        #expect(snapshot.primaryActivity == .completed(completion))
        #expect(snapshot.hasTaskCenterContent)
        #expect(!snapshot.hasActiveTasks)
    }

    @Test func waitingTaskTakesPriorityAndAnonymousTasksRemainVisible() {
        let waiting = task(isAnonymous: true)
        let running = task(isAnonymous: false)
        let snapshot = CodexActivitySnapshot(waitingTasks: [waiting], runningTasks: [running], recentCompletions: [], recentTerminations: [])
        #expect(snapshot.primaryActivity == .waiting(waiting))
        #expect(snapshot.activeCount == 2)
        #expect(snapshot.statusItemActivityExpiration == nil)
    }

    private func task(isAnonymous: Bool) -> CodexActivityTaskSnapshot {
        CodexActivityTaskSnapshot(
            id: UUID(), isAnonymous: isAnonymous, latestEvent: .promptSubmitted,
            projectName: nil, modelName: nil, effort: nil, toolName: nil,
            startedAt: TestFixtures.now, stateChangedAt: TestFixtures.now,
            showsPreciseDuration: !isAnonymous, activeSubagentCount: nil
        )
    }
}
