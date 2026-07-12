import Combine
import SwiftUI

/// 活动卡片与任务中心共享的显隐状态，控制选中外观和逐秒时间更新。
@MainActor
final class CodexActivityCenterPresentationState: ObservableObject {
    @Published var isPresented = false
}

/// 点击活动卡片时传给 AppKit 控制器的定位信息。
nonisolated struct CodexActivityCenterPanelContext: Equatable {
    let alignmentScreenFrame: CGRect?
    let preferredSide: UsageHeatmapDetailSide
}

/// 并发任务中心，实时展示全部等待、运行、最近完成和最近终止任务。
struct CodexActivityCenterView: View {
    @ObservedObject var activityMonitor: CodexActivityMonitor
    @ObservedObject var presentationState: CodexActivityCenterPresentationState
    let panelSize: CGSize

    var body: some View {
        Group {
            if presentationState.isPresented, needsPerSecondUpdates {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    content(now: timeline.date)
                }
            } else {
                content(now: Date())
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .sidePanelChrome(cornerRadius: Metrics.cornerRadius)
        .animation(.codexStatus, value: activityMonitor.snapshot)
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
        let sectionCounts = [
            snapshot.waitingTasks.count,
            snapshot.runningTasks.count,
            snapshot.recentCompletions.count,
            snapshot.recentTerminations.count
        ].filter { $0 > 0 }
        let contentHeight = Metrics.headerHeight
            + Metrics.dividerHeight
            + Metrics.verticalPadding * 2
            + CGFloat(sectionCounts.count) * Metrics.sectionHeaderHeight
            + CGFloat(sectionCounts.reduce(0, +)) * (Metrics.rowHeight + Metrics.rowSpacing)
            + CGFloat(max(0, sectionCounts.count - 1)) * Metrics.sectionSpacing
        let desiredHeight = max(Metrics.minimumPanelHeight, contentHeight)

        return CGSize(
            width: Metrics.panelWidth,
            height: min(maximumHeight, desiredHeight)
        )
    }

    private var needsPerSecondUpdates: Bool {
        activityMonitor.snapshot.hasTaskCenterContent
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            LiquidGlassDivider()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
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
        static let minimumPanelHeight: CGFloat = 180
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
    }
}
