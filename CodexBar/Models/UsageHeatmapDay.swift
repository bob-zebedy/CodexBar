import Foundation

/// 热力图单元格模型, 合并 app-server token 数据和本地 Hook 工作流统计
nonisolated struct UsageHeatmapDay: Equatable, Identifiable {
    let startDate: String
    let tokenCount: Int?
    let workflow: WorkflowDailyMetrics

    var id: String {
        startDate
    }

    var tokensForHeatmap: Int {
        tokenCount ?? 0
    }

    static func grid(
        usage: CodexUsageSnapshot,
        workflow: WorkflowSnapshot,
        showsWorkflow: Bool,
        columnCount: Int,
        today: Date
    ) -> [UsageHeatmapDay?] {
        let todayTokenCount = usage.tokenCount(on: today)
        // Hook 开启时当天工作流统计可见
        // Hook 关闭时只在 token bucket 已返回时展示今天
        let endingDaysAgo = showsWorkflow || todayTokenCount != nil ? 0 : 1
        let tokenDays = usage.recentWeekGrid(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        let workflowDays = workflow.recentWeekGrid(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )

        return merge(
            tokenDays: tokenDays,
            workflowDays: workflowDays,
            todayString: CodexDateFormat.dayString(from: today),
            todayTokenCount: todayTokenCount
        )
    }

    private static func merge(
        tokenDays: [DailyUsageBucket?],
        workflowDays: [WorkflowDailyMetrics?],
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
                workflow: workflowDay ?? .empty(startDate: startDate)
            )
        }
    }
}
