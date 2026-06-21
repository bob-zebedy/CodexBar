import Foundation

nonisolated struct UsageHeatmapDay: Equatable, Identifiable {
    let startDate: String
    let tokenCount: Int?
    let workflowStats: WorkflowDailyStats
    
    var id: String { startDate }
    
    var tokensForHeatmap: Int {
        tokenCount ?? 0
    }
    
    static func grid(
        usage: CodexUsageSnapshot,
        workflowStats: WorkflowStatsSnapshot,
        showsWorkflowStats: Bool,
        columnCount: Int,
        today: Date
    ) -> [UsageHeatmapDay?] {
        let todayTokenCount = usage.tokenCount(on: today)
        let endingDaysAgo = showsWorkflowStats || todayTokenCount != nil ? 0 : 1
        let tokenDays = usage.recentWeekGrid(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        let workflowDays = workflowStats.recentWeekGrid(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        
        return merge(
            tokenDays: tokenDays,
            workflowDays: workflowDays,
            todayString: DateFormatter.codexDay.string(from: today),
            todayTokenCount: todayTokenCount
        )
    }
    
    private static func merge(
        tokenDays: [DailyUsageBucket?],
        workflowDays: [WorkflowDailyStats?],
        todayString: String,
        todayTokenCount: Int?
    ) -> [UsageHeatmapDay?] {
        zip(tokenDays, workflowDays).map { tokenDay, workflowDay in
            guard let startDate = tokenDay?.startDate ?? workflowDay?.startDate else {
                return nil
            }
            
            return UsageHeatmapDay(
                startDate: startDate,
                tokenCount: startDate == todayString ? todayTokenCount : tokenDay?.tokens ?? 0,
                workflowStats: workflowDay ?? .empty(startDate: startDate)
            )
        }
    }
}
