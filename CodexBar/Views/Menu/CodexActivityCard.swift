import SwiftUI

/// Hook 开启时常驻的固定高度活动摘要，只在菜单面板可见时逐秒更新时间。
struct CodexActivityCard: View {
    let snapshot: CodexActivitySnapshot
    let isTimelineActive: Bool

    var body: some View {
        if isTimelineActive, needsPerSecondUpdates {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                card(now: timeline.date)
            }
        } else {
            card(now: Date())
        }
    }

    /// 空闲文案不随时间变化，不需要逐秒重算。
    private var needsPerSecondUpdates: Bool {
        snapshot.primaryActivity != .idle
    }

    private func card(now: Date) -> some View {
        let content = content(at: now)
        return HStack(spacing: 10) {
            Image(systemName: content.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(content.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(content.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(content.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            if content.otherTaskCount > 0 {
                Text("+\(content.otherTaskCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .help("另有 \(content.otherTaskCount) 个任务")
                    .accessibilityLabel("另有 \(content.otherTaskCount) 个任务")
            }
        }
        .padding(.horizontal, MenuMetrics.panelPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.height, maxHeight: Metrics.height)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
    }

    private func content(at now: Date) -> ActivityCardContent {
        switch snapshot.primaryActivity {
        case let .waiting(task):
            let details = [
                task.toolName ?? "等待下一步操作",
                "已等待 \(CodexActivityDurationFormat.text(for: now.timeIntervalSince(task.stateChangedAt)))"
            ]
            return ActivityCardContent(
                symbolName: "hand.raised.fill",
                tint: .orange,
                title: task.projectName ?? "Codex 等待批准",
                detail: details.joined(separator: " • "),
                otherTaskCount: otherTaskCount
            )
        case let .running(task):
            var titles = [task.projectName ?? "Codex"]
            if let modelName = task.modelName {
                titles.append(modelName)
            }

            var details: [String] = []
            if task.showsPreciseDuration, let startedAt = task.startedAt {
                details.append("已运行 \(CodexActivityDurationFormat.text(for: now.timeIntervalSince(startedAt)))")
            } else {
                details.append("正在运行")
            }
            details.append(Self.eventText(for: task))
            return ActivityCardContent(
                symbolName: "bolt.fill",
                tint: .blue,
                title: titles.joined(separator: " • "),
                detail: details.joined(separator: " • "),
                otherTaskCount: otherTaskCount
            )
        case let .completed(completion, _):
            var details: [String] = []
            if let duration = completion.duration {
                details.append("耗时 \(CodexActivityDurationFormat.text(for: duration))")
            }
            details.append(Self.completionRelativeText(completion.completedAt, now: now))
            return ActivityCardContent(
                symbolName: "checkmark.circle.fill",
                tint: .green,
                title: completion.projectName ?? "Codex 任务已完成",
                detail: details.joined(separator: " • "),
                otherTaskCount: 0
            )
        case .idle:
            return ActivityCardContent(
                symbolName: "waveform.path",
                tint: .secondary,
                title: "暂无 Codex 活动",
                detail: "Codex Hook 正在监测",
                otherTaskCount: 0
            )
        }
    }

    private var otherTaskCount: Int {
        max(0, snapshot.activeCount - 1)
    }

    private static func eventText(for task: CodexActivityTaskSnapshot) -> String {
        switch task.latestEvent {
        case .promptSubmitted:
            "正在思考"
        case .toolStarted:
            task.toolName.map { "调用工具 \($0)" } ?? "调用工具"
        case .toolFinished:
            task.toolName.map { "调用工具 \($0) 完成" } ?? "调用工具完成"
        case .compactionStarted:
            "压缩上下文"
        case .compactionFinished:
            "上下文压缩完成"
        case .subagentStarted:
            "启动子智能体"
        case .subagentFinished:
            "子智能体完成"
        case .approvalRequested:
            "等待批准"
        }
    }

    private static func completionRelativeText(_ completedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(completedAt)))
        if seconds < 10 {
            return "刚刚完成"
        }
        if seconds < 60 {
            return "\(seconds) 秒前完成"
        }
        return "\(seconds / 60) 分钟前完成"
    }

    private enum Metrics {
        static let height: CGFloat = 58
    }
}

private struct ActivityCardContent {
    let symbolName: String
    let tint: Color
    let title: String
    let detail: String
    let otherTaskCount: Int
}
