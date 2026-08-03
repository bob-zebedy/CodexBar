import SwiftUI

/// Hook 开启时常驻的固定高度活动摘要, 使用菜单面板共享的逐秒时间
/// 在卡片内部观察 activityMonitor 与逐秒时间, 让 1Hz 失效范围只覆盖本卡片而不是整个菜单树
/// keepAliveController 同理, 它的 helperStatus 等字段与菜单树无关却会无条件发信号
struct CodexActivityCard: View {
    @ObservedObject var activityMonitor: CodexActivityMonitor
    @ObservedObject var presentationState: CodexActivityCenterPresentationState
    @ObservedObject var keepAliveController: KeepAliveController
    let showsUnavailableState: Bool
    let onTaskCenterTap: (ScreenFrameProvider) -> Void
    @State private var frameProvider = ScreenFrameProvider()
    @State private var isHovered = false

    private var snapshot: CodexActivitySnapshot {
        showsUnavailableState ? .empty : activityMonitor.snapshot
    }

    private var timelineDate: Date {
        presentationState.timelineDate
    }

    private var isTaskCenterPresented: Bool {
        presentationState.isPresented
    }

    /// 额度数据不可用时卡片整体退到"暂无数据", 徽标属于活动信息, 必须跟着一起收
    /// 否则会出现"暂无数据"配上防睡眠徽标的自相矛盾画面
    private var showsKeepAliveBadge: Bool {
        keepAliveController.isActivelyPreventingSleep && !showsUnavailableState
    }

    var body: some View {
        Group {
            if snapshot.hasTaskCenterContent {
                Button {
                    onTaskCenterTap(frameProvider)
                } label: {
                    card(now: timelineDate)
                }
                .buttonStyle(ActivityCardButtonStyle())
                .contentShape(Rectangle())
            } else {
                card(now: timelineDate)
            }
        }
        .background {
            ScreenFrameReader(provider: frameProvider)
        }
        .onHover { isHovered = $0 }
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
                    .foregroundStyle(Color.codexLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail = content.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            if showsKeepAliveBadge {
                // 防睡眠只在任务运行期间生效, 所以状态挂在活动卡片上而不是单独占一行
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.teal)
                    .transition(.opacity)
                    .help("已防止系统睡眠")
            }

            if content.otherTaskCount > 0 {
                Text(verbatim: "+\(content.otherTaskCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    // 必须是具体 Color, 层级样式在 numericText 的过渡层里会被重新解析成别的层级
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .numericRollTransition(value: Double(content.otherTaskCount))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .transition(.opacity)
                    .help("另有 \(content.otherTaskCount) 个任务")
            }
        }
        .animation(.codexStatus, value: showsKeepAliveBadge)
        // 任务数变化会让 +N 增删, 咖啡杯跟着横移; 两者一起纳入动画上下文才不会跳
        .animation(.codexStatus, value: content.otherTaskCount)
        .padding(.horizontal, MenuMetrics.panelPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.height, maxHeight: Metrics.height)
        .liquidGlassSurface(cornerRadius: MenuMetrics.panelCornerRadius)
        .overlay {
            RoundedRectangle(cornerRadius: MenuMetrics.panelCornerRadius, style: .continuous)
                .strokeBorder(
                    isTaskCenterPresented
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(isHovered && snapshot.hasTaskCenterContent ? 0.14 : 0),
                    lineWidth: 1
                )
                .animation(.codexStatus, value: isHovered)
                .animation(.codexStatus, value: isTaskCenterPresented)
        }
    }

    private func content(at now: Date) -> ActivityCardContent {
        switch snapshot.primaryActivity {
        case let .waiting(task):
            let details = activeDetailComponents(
                CodexActivityDisplayFormat.waitingDetailComponents(for: task, now: now),
                task: task
            )
            return ActivityCardContent(
                symbolName: "hand.raised.fill",
                tint: .orange,
                title: activityTitle(
                    modelName: task.modelName,
                    effort: task.effort,
                    projectName: task.projectName,
                    fallback: "Codex 等待批准"
                ),
                detail: details.joined(separator: " • "),
                otherTaskCount: otherTaskCount
            )
        case let .running(task):
            let details = activeDetailComponents(
                CodexActivityDisplayFormat.runningDetailComponents(for: task, now: now),
                task: task
            )
            return ActivityCardContent(
                symbolName: "bolt.fill",
                tint: .blue,
                title: activityTitle(
                    modelName: task.modelName,
                    effort: task.effort,
                    projectName: task.projectName,
                    fallback: "Codex"
                ),
                detail: details.joined(separator: " • "),
                otherTaskCount: otherTaskCount
            )
        case let .completed(completion, _):
            let details = CodexActivityDisplayFormat.historyDetailComponents(
                duration: completion.duration,
                relativeText: CodexActivityDisplayFormat.completionRelativeText(completion.completedAt, now: now)
            )
            return ActivityCardContent(
                symbolName: "checkmark.circle.fill",
                tint: .green,
                title: activityTitle(
                    modelName: completion.modelName,
                    effort: completion.effort,
                    projectName: completion.projectName,
                    fallback: "Codex 任务已完成"
                ),
                detail: details.joined(separator: " • "),
                otherTaskCount: 0
            )
        case let .terminated(termination):
            let details = CodexActivityDisplayFormat.historyDetailComponents(
                duration: termination.duration,
                relativeText: CodexActivityDisplayFormat.terminationRelativeText(termination.terminatedAt, now: now)
            )
            return ActivityCardContent(
                symbolName: "xmark.circle.fill",
                tint: .secondary,
                title: activityTitle(
                    modelName: termination.modelName,
                    effort: termination.effort,
                    projectName: termination.projectName,
                    fallback: "Codex 任务已终止"
                ),
                detail: details.joined(separator: " • "),
                otherTaskCount: 0
            )
        case .idle:
            return ActivityCardContent(
                symbolName: "moon.zzz.fill",
                tint: .secondary,
                title: showsUnavailableState
                    ? String(localized: "暂无数据")
                    : String(localized: "暂无 Codex 活动"),
                detail: nil,
                otherTaskCount: 0
            )
        }
    }

    private func activityTitle(
        modelName: String?,
        effort: String?,
        projectName: String?,
        fallback: LocalizedStringResource
    ) -> String {
        [
            CodexActivityDisplayFormat.modelMetadata(
                modelName: modelName,
                effort: effort
            ),
            projectName ?? String(localized: fallback)
        ]
        .compactMap(\.self)
        .joined(separator: " • ")
    }

    private func activeDetailComponents(
        _ components: [String],
        task: CodexActivityTaskSnapshot
    ) -> [String] {
        guard let count = task.activeSubagentCount, count > 0 else {
            return components
        }
        var result = components
        result.insert(String(localized: "\(count) 个子 Agent"), at: min(1, result.count))
        return result
    }

    private var otherTaskCount: Int {
        max(0, snapshot.activeCount - 1)
    }

    private enum Metrics {
        static let height: CGFloat = 58
    }
}

/// 卡片自行处理 hover/选中描边, 按钮样式不再修改 label 的前景色或透明度
private struct ActivityCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct ActivityCardContent {
    let symbolName: String
    let tint: Color
    let title: String
    let detail: String?
    let otherTaskCount: Int
}
