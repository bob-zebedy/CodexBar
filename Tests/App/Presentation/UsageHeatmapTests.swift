import Foundation
import Testing

struct UsageHeatmapTests {
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
            #expect(selection.row == 0)
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
}
