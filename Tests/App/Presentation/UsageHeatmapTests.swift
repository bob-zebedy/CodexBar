import Foundation
import Testing

struct UsageHeatmapTests {
    @Test(arguments: [UsageHeatmapMode.daily, .weekly])
    func pointerReconciliationKeepsSelectionAndFollowsAnotherCell(mode: UsageHeatmapMode) throws {
        let today = try #require(CodexDateFormat.dayDate(from: "2026-10-24"))
        let days = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 30, today: today)
        let original = try #require(UsageHeatmapSelection.at(column: 28, row: 3, in: days, mode: mode))
        let position = try #require(UsageHeatmap.Metrics.gridPosition(at: CGPoint(x: 426, y: 51)))
        #expect(UsageHeatmapSelection.at(column: position.column, row: position.row, in: days, mode: mode) == original)

        let next = try #require(UsageHeatmap.Metrics.gridPosition(at: CGPoint(x: 441, y: 96)))
        let updated = try #require(UsageHeatmapSelection.at(column: next.column, row: next.row, in: days, mode: mode))
        #expect(updated != original)
        #expect(updated.highlights(column: 29, row: 6, in: days, mode: mode))
    }

    @Test func pointerReconciliationRejectsOutsideAndInvalidCoordinates() {
        for point in [
            CGPoint(x: -1.5, y: 6), CGPoint(x: 6, y: -1.5),
            CGPoint(x: 448.5, y: 6), CGPoint(x: 6, y: 103.5)
        ] {
            #expect(UsageHeatmap.Metrics.gridPosition(at: point) == nil)
        }
        for coordinate in [CGFloat.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            #expect(UsageHeatmap.Metrics.gridPosition(at: CGPoint(x: coordinate, y: 6)) == nil)
            #expect(UsageHeatmap.Metrics.gridPosition(at: CGPoint(x: 6, y: coordinate)) == nil)
        }
    }

    @Test func pointerReconciliationPreservesEdgesAndMidpointSnapping() {
        for (point, column, row) in [
            (CGPoint(x: 0, y: 0), 0, 0),
            (CGPoint(x: 446, y: 101), 29, 6),
            (CGPoint(x: -1.499, y: -1.499), 0, 0),
            (CGPoint(x: 448.499, y: 103.499), 29, 6),
            (CGPoint(x: 13.499, y: 13.499), 0, 0),
            (CGPoint(x: 13.5, y: 13.5), 1, 1),
            (CGPoint(x: 433.499, y: 88.499), 28, 5),
            (CGPoint(x: 433.5, y: 88.5), 29, 6)
        ] {
            let position = UsageHeatmap.Metrics.gridPosition(at: point)
            #expect(position?.column == column && position?.row == row)
        }
    }

    @Test(arguments: [UsageHeatmapMode.daily, .weekly])
    func stationaryPointerSelectsNewDateAfterWeekChanges(mode: UsageHeatmapMode) throws {
        let before = try #require(CodexDateFormat.dayDate(from: "2026-10-24"))
        let after = try #require(CodexDateFormat.dayDate(from: "2026-10-25"))
        let oldDays = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 30, today: before)
        let newDays = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 30, today: after)
        let position = try #require(UsageHeatmap.Metrics.gridPosition(at: CGPoint(x: 426, y: 51)))
        let original = try #require(UsageHeatmapSelection.at(column: position.column, row: position.row, in: oldDays, mode: mode))
        let updated = try #require(UsageHeatmapSelection.at(column: position.column, row: position.row, in: newDays, mode: mode))

        #expect(original.dateID == (mode == .daily ? "2026-10-14" : "2026-10-11"))
        #expect(updated.dateID == (mode == .daily ? "2026-10-21" : "2026-10-18"))
        #expect(original.currentColumn(in: newDays) == position.column - 1)
        #expect(!original.highlights(column: position.column, row: position.row, in: newDays, mode: mode))
        #expect(updated.highlights(column: position.column, row: position.row, in: newDays, mode: mode))
        let period = try #require(updated.period(in: newDays, weeks: UsageHeatmapPeriod.weeks(in: newDays), mode: mode))
        #expect(period.startDate == updated.dateID)
        #expect(period.endDate == (mode == .daily ? "2026-10-21" : "2026-10-24"))
    }

    @Test(arguments: ["2026-10-18", "2026-10-20", "2026-10-24"])
    func currentWeekAlwaysHasSevenSelectableRowsWhileDailyFutureStaysEmpty(todayKey: String) throws {
        let today = try #require(CodexDateFormat.dayDate(from: todayKey))
        let days = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 2, today: today)
        let weeks = UsageHeatmapPeriod.weeks(in: days)
        let week = try #require(weeks.last ?? nil)
        #expect(week.startDate == "2026-10-18")
        #expect(week.endDate == "2026-10-24")
        for row in 0 ..< CodexWeekGrid.rowCount {
            let selection = try #require(UsageHeatmapSelection.at(column: 1, row: row, in: days, mode: .weekly))
            #expect(selection.dateID == week.startDate)
            #expect(selection.period(in: days, weeks: weeks, mode: .weekly) == week)
            #expect(selection.highlights(column: 1, row: row, in: days, mode: .weekly))
            #expect(!selection.highlights(column: 0, row: row, in: days, mode: .weekly))
            let dailySelection = UsageHeatmapSelection.at(column: 1, row: row, in: days, mode: .daily)
            #expect((dailySelection != nil) == (days[7 + row] != nil))
        }
    }

    @Test func weekAggregatesAllMetricsAndWeightsCacheHitRateByInputTokens() throws {
        let first = day(
            "2026-10-18",
            tokens: 100,
            count: 2,
            models: ["model-a": 5, "model-b": 4],
            usage: usage(input: 100, cached: 80, written: 10, output: 20, reasoning: 5)
        )
        let second = day(
            "2026-10-19",
            tokens: 200,
            count: 3,
            models: ["model-c": 5, "model-b": 4],
            usage: usage(input: 900, cached: 90, written: 20, output: 80, reasoning: 15)
        )
        let week = try #require(UsageHeatmapPeriod.weeks(in: [first, second, nil, nil, nil, nil, nil]).first ?? nil)
        #expect(week.tokenState == .available(300))
        #expect(week.activityData.threadCount == 5)
        #expect(week.activityData.turnCount == 10)
        #expect(week.activityData.toolCallCount == 15)
        #expect(week.activityData.approvalRequestedCount == 20)
        #expect(week.activityData.contextCompactionCount == 25)
        #expect(week.activityData.subagentCount == 30)
        #expect(week.activityData.mostUsedModel == "model-b")
        #expect(week.tokenUsage?.inputTokens == 1000)
        #expect(week.tokenUsage?.cachedInputTokens == 170)
        #expect(week.tokenUsage?.cacheWriteInputTokens == 30)
        #expect(week.tokenUsage?.outputTokens == 100)
        #expect(week.tokenUsage?.reasoningOutputTokens == 20)
        #expect(week.tokenUsage?.totalTokens == 1100)
        #expect(week.tokenUsage?.cacheHitRate == 0.17)
        #expect(week.endDate == "2026-10-24")
    }

    @Test(arguments: [(0, 0), (1, 1), (100, 1), (101, 2), (300, 3), (301, 4), (699, 7), (700, 7), (800, 7)])
    func histogramHeightUsesWeeklyTokensRelativeToPeak(tokens: Int, expectedRows: Int) throws {
        let week = try #require(UsageHeatmapPeriod(days: [day("2026-10-18", tokens: tokens)]))
        #expect(week.filledRowCount(peakTokens: 700) == expectedRows)
        #expect(week.filledRowCount(peakTokens: 0) == 0)
    }

    @Test(arguments: [0, 100])
    func currentWeekShowsAvailableUsageAndAddsTodayWhenItArrives(knownTokens: Int) throws {
        let today = try #require(CodexDateFormat.dayDate(from: "2026-10-20"))
        let summary = try TestFixtures.decode(UsageSummary.self, "{}")
        let buckets = [DailyUsageBucket(startDate: "2026-10-18", tokens: knownTokens)]
        let usage = CodexUsageSnapshot(summary: summary, dailyBuckets: buckets)
        let days = UsageHeatmapDay.grid(usage: usage, history: .empty, columnCount: 1, today: today)
        let selection = try #require(UsageHeatmapSelection.at(column: 0, row: 6, in: days, mode: .weekly))
        let week = try #require(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: .weekly))
        #expect(days[2]?.tokenState == .pending)
        #expect(week.tokenState == .available(knownTokens))
        #expect(week.filledRowCount(peakTokens: 700) == (knownTokens > 0 ? 1 : 0))

        let updatedUsage = CodexUsageSnapshot(summary: summary, dailyBuckets: buckets + [DailyUsageBucket(startDate: "2026-10-20", tokens: 50)])
        let updatedDays = UsageHeatmapDay.grid(usage: updatedUsage, history: .empty, columnCount: 1, today: today)
        let updatedWeek = try #require(selection.period(in: updatedDays, weeks: UsageHeatmapPeriod.weeks(in: updatedDays), mode: .weekly))
        #expect(updatedWeek.tokenState == .available(knownTokens + 50))
        #expect(updatedWeek.startDate == "2026-10-18")
        #expect(updatedWeek.endDate == "2026-10-24")
    }

    @Test func pendingDaysPreserveAvailableTokensWhileUnavailableDataStaysUnknown() throws {
        let known = day("2026-10-18", tokens: 100, usage: usage(input: 100))
        let pending = UsageHeatmapDay(startDate: "2026-10-19", tokenState: .pending, activityData: .unavailable(startDate: "2026-10-19"))
        let unavailable = UsageHeatmapDay(startDate: "2026-10-20", tokenState: .unavailable, activityData: .empty(startDate: "2026-10-20"))
        let period = try #require(UsageHeatmapPeriod(days: [known, pending]))
        #expect(period.tokenState == .available(100))
        #expect(period.activityData.threadCount == nil)
        #expect(period.activityData.toolCallCount == nil)
        #expect(period.tokenUsage == known.tokenUsage)
        #expect(UsageHeatmapPeriod(days: [pending])?.tokenState == .pending)
        #expect(UsageHeatmapPeriod(days: [pending, unavailable])?.tokenState == .unavailable)
        #expect(UsageHeatmapPeriod(days: [unavailable, known])?.tokenState == .unavailable)
        #expect(UsageHeatmapPeriod(days: [unavailable])?.tokenUsage == nil)
        #expect(UsageHeatmapPeriod(days: []) == nil)
    }

    @Test(arguments: [("2026-01-01", "2025-12-28", "2026-01-03"), ("2026-03-31", "2026-03-29", "2026-04-04")])
    func fullWeekRangeCrossesMonthAndYearBoundaries(todayKey: String, start: String, end: String) throws {
        let today = try #require(CodexDateFormat.dayDate(from: todayKey))
        let days = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 1, today: today)
        let week = try #require(UsageHeatmapPeriod.weeks(in: days).first ?? nil)
        #expect(week.startDate == start)
        #expect(week.endDate == end)
    }

    @Test func selectedWeekUsesFreshDataAndDoesNotIncludeNeighboringColumns() throws {
        let first = day("2026-10-11", tokens: 900)
        let current = day("2026-10-18", tokens: 20)
        var days: [UsageHeatmapDay?] = [first, nil, nil, nil, nil, nil, nil, current, nil, nil, nil, nil, nil, nil]
        let selection = try #require(UsageHeatmapSelection.at(column: 1, row: 6, in: days, mode: .weekly))
        #expect(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: .weekly)?.tokenState == .available(20))
        #expect(selection.highlights(column: 1, row: 6, in: days, mode: .weekly))
        days[8] = day("2026-10-19", tokens: 30)
        #expect(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: .weekly)?.tokenState == .available(50))
        #expect(selection.highlights(column: 1, row: 6, in: days, mode: .weekly))
        #expect(selection.period(in: days, weeks: [], mode: .daily)?.tokenState == .available(20))
        days.removeFirst(7)
        #expect(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: .weekly)?.tokenState == .available(50))
        #expect(selection.highlights(column: 0, row: 6, in: days, mode: .weekly))
        #expect(!selection.highlights(column: 1, row: 6, in: days, mode: .weekly))
        #expect(selection.period(in: [], weeks: [], mode: .weekly) == nil)
    }

    @Test(arguments: [UsageHeatmapMode.daily, .weekly])
    func selectionHighlightAndDetailSideFollowDateAcrossColumns(mode: UsageHeatmapMode) throws {
        let today = try #require(CodexDateFormat.dayDate(from: "2026-10-24"))
        var days = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: UsageHeatmap.Metrics.columnCount, today: today)
        let originalColumn = UsageHeatmap.Metrics.columnCount / 2
        let selectedRow = 3
        let selection = try #require(UsageHeatmapSelection.at(column: originalColumn, row: selectedRow, in: days, mode: mode))
        let initialColumn = try #require(selection.currentColumn(in: days))
        #expect(initialColumn == originalColumn)
        #expect(UsageHeatmap.Metrics.preferredDetailSide(for: initialColumn) == .right)
        let initialPeriod = try #require(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: mode))

        days.removeFirst(CodexWeekGrid.rowCount)

        let currentColumn = try #require(selection.currentColumn(in: days))
        #expect(currentColumn == originalColumn - 1)
        #expect(UsageHeatmapSelection.at(column: currentColumn, row: selectedRow, in: days, mode: mode) == selection)
        #expect(UsageHeatmap.Metrics.preferredDetailSide(for: currentColumn) == .left)
        #expect(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: mode) == initialPeriod)
        for row in 0 ..< CodexWeekGrid.rowCount {
            #expect(selection.highlights(column: currentColumn, row: row, in: days, mode: mode) == (mode == .weekly || row == selectedRow))
            #expect(!selection.highlights(column: originalColumn, row: row, in: days, mode: mode))
        }
    }

    @Test(arguments: [UsageHeatmapMode.daily, .weekly])
    func selectionLeavingGridHasNoHighlightOrDetailEvenWhenColumnIsReused(mode: UsageHeatmapMode) throws {
        let today = try #require(CodexDateFormat.dayDate(from: "2026-10-24"))
        var days = UsageHeatmapDay.grid(usage: nil, history: .empty, columnCount: 2, today: today)
        let selection = try #require(UsageHeatmapSelection.at(column: 0, row: 3, in: days, mode: mode))
        #expect(selection.highlights(column: 0, row: 3, in: days, mode: mode))

        days.removeFirst(CodexWeekGrid.rowCount)

        #expect(selection.day(in: days) == nil)
        #expect(selection.currentColumn(in: days) == nil)
        #expect(selection.period(in: days, weeks: UsageHeatmapPeriod.weeks(in: days), mode: mode) == nil)
        for row in 0 ..< CodexWeekGrid.rowCount {
            #expect(!selection.highlights(column: 0, row: row, in: days, mode: mode))
        }
        #expect(selection.currentColumn(in: []) == nil)
        #expect(!selection.highlights(column: 0, row: 0, in: [], mode: mode))
    }

    @Test func overflowDoesNotPublishWrappedWeeklyTotals() throws {
        let first = day("2026-10-18", tokens: Int.max, usage: usage(input: Int64.max))
        let second = day("2026-10-19", tokens: 1, usage: usage(input: 1))
        let week = try #require(UsageHeatmapPeriod(days: [first, second]))
        #expect(week.tokenState == .unavailable)
        #expect(week.tokenUsage == nil)
    }

    @Test func invalidGridPositionsCannotSelectAnotherWeek() {
        let days: [UsageHeatmapDay?] = [day("2026-10-18", tokens: 1), nil, nil, nil, nil, nil, nil]
        for mode in [UsageHeatmapMode.daily, .weekly] {
            #expect(UsageHeatmapSelection.at(column: -1, row: 0, in: days, mode: mode) == nil)
            #expect(UsageHeatmapSelection.at(column: 1, row: 0, in: days, mode: mode) == nil)
            #expect(UsageHeatmapSelection.at(column: 0, row: 7, in: days, mode: mode) == nil)
            #expect(UsageHeatmapSelection.at(column: 0, row: -1, in: days, mode: mode) == nil)
            #expect(UsageHeatmapSelection.at(column: 0, row: 0, in: [], mode: mode) == nil)
        }
    }

    private func day(_ date: String, tokens: Int, count: Int = 0, models: [String: Int] = [:], usage: TokenUsage? = nil) -> UsageHeatmapDay {
        UsageHeatmapDay(
            startDate: date,
            tokenState: .available(tokens),
            activityData: ActivityDataMetrics(
                startDate: date, threadCount: count, turnCount: count * 2, toolCallCount: count * 3,
                approvalRequestedCount: count * 4, contextCompactionCount: count * 5, subagentCount: count * 6,
                modelCounts: models
            ),
            tokenUsage: usage
        )
    }

    private func usage(input: Int64, cached: Int64 = 0, written: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) -> TokenUsage {
        TokenUsage(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: written,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: input + output
        )
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

    @Test func heatmapSelectionReadsLatestDayDataByDate() {
        let date = "2026-09-15"
        let selection = UsageHeatmapSelection(dateID: date)
        let initial = UsageHeatmapDay(startDate: date, tokenState: .pending, activityData: .empty(startDate: date))
        let updated = UsageHeatmapDay(
            startDate: date, tokenState: .available(120), activityData: .unavailable(startDate: date), tokenUsage: .zero
        )
        let unrelated = UsageHeatmapDay(startDate: "2026-09-14", tokenState: .available(5), activityData: .empty(startDate: "2026-09-14"))
        #expect(selection.day(in: [initial, unrelated]) == initial)
        #expect(selection.day(in: [nil, unrelated, updated]) == updated)
        #expect(selection.day(in: [nil, unrelated]) == nil)
        #expect(selection.day(in: []) == nil)
    }

    @Test func partialSourcesKeepKnownValuesVisible() {
        let now = Date()
        let date = HistoryStorage.dateKey(for: now)
        var aggregate = ActivityDataAggregate(date: date)
        aggregate.turnCount = 3
        var snapshot = HistorySnapshot(activityData: [aggregate.metrics])
        snapshot.isActivityDataComplete = false
        let day = UsageHeatmapDay.grid(usage: nil, history: snapshot, columnCount: 1, today: now).compactMap(\.self).first { $0.startDate == date }
        #expect(day?.activityData.turnCount == 3)
    }

    @Test func heatmapSeparatesAccountIntensityFromLocalDailyMetrics() throws {
        let day = HistoryStorage.dateKey(for: TestFixtures.now)
        var history = HistorySnapshot.empty
        history.tokenUsageByDate = [day: TokenUsage(
            inputTokens: 100, cachedInputTokens: 20, cacheWriteInputTokens: 5,
            outputTokens: 10, reasoningOutputTokens: 2, totalTokens: 110
        )]
        let grid = UsageHeatmapDay.grid(usage: nil, history: history, columnCount: 2, today: TestFixtures.now)
        let today = try #require(grid.compactMap(\.self).first { $0.startDate == day })
        #expect(today.tokenState == .unavailable)
        #expect(today.tokenUsage?.totalTokens == 110)
        #expect(today.activityData.turnCount == 0)
    }
}
