import Combine
import SwiftUI

/// 活动卡片与任务中心共享的显隐和逐秒时间状态。
@MainActor
final class CodexActivityCenterPresentationState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var timelineDate = Date()
    private var timelineTask: Task<Void, Never>?

    func setTimelineActive(_ isActive: Bool) {
        guard isActive else {
            timelineTask?.cancel()
            timelineTask = nil
            return
        }
        guard timelineTask == nil else {
            return
        }

        timelineDate = Date()
        timelineTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let fraction = now.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1)
                try? await Task.sleep(for: .seconds(max(0.01, 1 - fraction)))
                guard let self, !Task.isCancelled else {
                    return
                }
                timelineDate = Date()
            }
        }
    }
}

/// 点击活动卡片时传给 AppKit 控制器的定位信息。
@MainActor
struct CodexActivityCenterPanelContext {
    let anchorProvider: ScreenFrameProvider
    let preferredSide: UsageHeatmapDetailSide
}

/// 并发任务中心，实时展示全部等待、运行、最近完成和最近终止任务。
struct CodexActivityCenterView: View {
    @ObservedObject var activityMonitor: CodexActivityMonitor
    @ObservedObject var presentationState: CodexActivityCenterPresentationState

    var body: some View {
        content(now: presentationState.timelineDate)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
    }

    static var initialPanelSize: CGSize {
        CGSize(width: Metrics.panelWidth, height: Metrics.preferredPanelHeight)
    }

    static var panelCornerRadius: CGFloat {
        Metrics.cornerRadius
    }

    static func panelSize(
        maximumHeight: CGFloat,
        snapshot: CodexActivitySnapshot
    ) -> CGSize {
        let visibleSectionCounts = [
            snapshot.waitingTasks.count,
            snapshot.runningTasks.count,
            snapshot.recentCompletions.count,
            snapshot.recentTerminations.count
        ].filter { $0 > 0 }
        let rowCount = visibleSectionCounts.reduce(0, +)
        let contentHeight = Metrics.headerHeight
            + Metrics.dividerHeight
            + Metrics.verticalPadding * 2
            + CGFloat(visibleSectionCounts.count) * Metrics.sectionHeaderHeight
            + CGFloat(rowCount) * (Metrics.rowHeight + Metrics.rowSpacing)
            + CGFloat(max(0, visibleSectionCounts.count - 1)) * Metrics.sectionSpacing

        return CGSize(
            width: Metrics.panelWidth,
            height: min(maximumHeight, contentHeight)
        )
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            LiquidGlassDivider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    if !activityMonitor.snapshot.waitingTasks.isEmpty {
                        taskSection(
                            title: "等待确认",
                            symbolName: "hand.raised.fill",
                            tint: .orange,
                            tasks: activityMonitor.snapshot.waitingTasks,
                            now: now,
                            isWaiting: true
                        )
                    }

                    if !activityMonitor.snapshot.runningTasks.isEmpty {
                        taskSection(
                            title: "运行中",
                            symbolName: "bolt.fill",
                            tint: .blue,
                            tasks: activityMonitor.snapshot.runningTasks,
                            now: now,
                            isWaiting: false
                        )
                    }

                    if !activityMonitor.snapshot.recentCompletions.isEmpty {
                        completionSection(now: now)
                    }

                    if !activityMonitor.snapshot.recentTerminations.isEmpty {
                        terminationSection(now: now)
                    }
                }
                .animation(.codexStatus, value: activityMonitor.snapshot)
                .padding(.horizontal, Metrics.horizontalPadding)
                .padding(.vertical, Metrics.verticalPadding)
            }
            .scrollIndicators(.never)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("任务中心")
                .font(.caption.weight(.semibold))

            Spacer(minLength: 8)

            Text(headerSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(height: Metrics.headerHeight)
    }

    private var headerSummary: String {
        let snapshot = activityMonitor.snapshot
        var components = [String]()
        if snapshot.waitingCount > 0 {
            components.append("等待 \(snapshot.waitingCount)")
        }
        if snapshot.runningCount > 0 {
            components.append("运行 \(snapshot.runningCount)")
        }
        if snapshot.activeCount == 0 {
            if !snapshot.recentCompletions.isEmpty {
                components.append("最近完成 \(snapshot.recentCompletions.count)")
            }
            if !snapshot.recentTerminations.isEmpty {
                components.append("最近终止 \(snapshot.recentTerminations.count)")
            }
        }
        return components.joined(separator: " · ")
    }

    private func taskSection(
        title: String,
        symbolName: String,
        tint: Color,
        tasks: [CodexActivityTaskSnapshot],
        now: Date,
        isWaiting: Bool
    ) -> some View {
        section(title: title, count: tasks.count) {
            ForEach(tasks) { task in
                taskRow(
                    task,
                    symbolName: symbolName,
                    tint: tint,
                    now: now,
                    isWaiting: isWaiting
                )
            }
        }
    }

    private func completionSection(now: Date) -> some View {
        section(title: "最近完成", count: activityMonitor.snapshot.recentCompletions.count) {
            ForEach(activityMonitor.snapshot.recentCompletions) { completion in
                completionRow(completion, now: now)
            }
        }
    }

    private func terminationSection(now: Date) -> some View {
        section(title: "最近终止", count: activityMonitor.snapshot.recentTerminations.count) {
            ForEach(activityMonitor.snapshot.recentTerminations) { termination in
                terminationRow(termination, now: now)
            }
        }
    }

    private func section(
        title: String,
        count: Int,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(height: Metrics.sectionHeaderHeight)

            content()
        }
    }

    private func taskRow(
        _ task: CodexActivityTaskSnapshot,
        symbolName: String,
        tint: Color,
        now: Date,
        isWaiting: Bool
    ) -> some View {
        row(
            symbolName: symbolName,
            tint: tint,
            projectName: task.projectName,
            modelName: task.modelName,
            detail: taskDetail(task, now: now, isWaiting: isWaiting)
        )
    }

    private func completionRow(_ completion: CodexActivityCompletion, now: Date) -> some View {
        row(
            symbolName: "checkmark.circle.fill",
            tint: .green,
            projectName: completion.projectName,
            modelName: completion.modelName,
            detail: historyDetail(
                duration: completion.duration,
                relativeText: CodexActivityDisplayFormat.completionRelativeText(
                    completion.completedAt,
                    now: now
                )
            )
        )
    }

    private func terminationRow(_ termination: CodexActivityTermination, now: Date) -> some View {
        row(
            symbolName: "xmark.circle.fill",
            tint: .secondary,
            projectName: termination.projectName,
            modelName: termination.modelName,
            detail: historyDetail(
                duration: termination.duration,
                relativeText: CodexActivityDisplayFormat.terminationRelativeText(
                    termination.terminatedAt,
                    now: now
                )
            )
        )
    }

    private func row(
        symbolName: String,
        tint: Color,
        projectName: String?,
        modelName: String?,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Metrics.symbolWidth, height: Metrics.titleLineHeight)

            VStack(alignment: .leading, spacing: 3) {
                titleLine(projectName: projectName, modelName: modelName)

                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.rowHeight, alignment: .top)
        .transition(Metrics.contentTransition)
    }

    private func titleLine(projectName: String?, modelName: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(projectName ?? "Codex")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let modelName {
                Text(modelName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(height: Metrics.titleLineHeight)
    }

    private func taskDetail(
        _ task: CodexActivityTaskSnapshot,
        now: Date,
        isWaiting: Bool
    ) -> String {
        let components = isWaiting
            ? CodexActivityDisplayFormat.waitingDetailComponents(for: task, now: now)
            : CodexActivityDisplayFormat.runningDetailComponents(for: task, now: now)
        return components.joined(separator: " · ")
    }

    private func historyDetail(duration: TimeInterval?, relativeText: String) -> String {
        CodexActivityDisplayFormat.historyDetailComponents(
            duration: duration,
            relativeText: relativeText
        ).joined(separator: " · ")
    }

    private enum Metrics {
        static let panelWidth: CGFloat = 312
        static let preferredPanelHeight: CGFloat = 360
        static let headerHeight: CGFloat = 42
        static let dividerHeight: CGFloat = 1
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        static let sectionSpacing: CGFloat = 14
        static let sectionHeaderHeight: CGFloat = 14
        static let rowSpacing: CGFloat = 9
        static let rowHeight: CGFloat = 33
        static let symbolWidth: CGFloat = 16
        static let titleLineHeight: CGFloat = 16
        static let cornerRadius: CGFloat = 12
        static let contentTransition = AnyTransition.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        )
    }
}
