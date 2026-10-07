import SwiftUI

/// 实时任务摘要, 使用主面板共享的时间
/// 活动和防睡眠状态由卡片自行观察, 避免刷新整个菜单树
struct ActivityCard: View {
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var presentationState: ActivityCenterPresentationState
    @ObservedObject var keepAliveController: KeepAliveController
    let onTaskCenterTap: (ScreenFrameProvider) -> Void
    @Environment(\.mainPanelAnimationsEnabled) private var allowsAnimations
    @State private var frameProvider = ScreenFrameProvider()
    @State private var isHovered = false

    private var snapshot: ActivitySnapshot {
        activityMonitor.snapshot
    }

    private var showsUnavailableState: Bool {
        !activityMonitor.isActivitySourceHealthy
    }

    private var timelineDate: Date {
        presentationState.timelineDate
    }

    private var isTaskCenterPresented: Bool {
        presentationState.isPresented
    }

    /// 卡片显示"暂无数据"时一并隐藏防睡眠徽标, 保持状态一致
    private var showsKeepAliveBadge: Bool {
        keepAliveController.isActivelyPreventingSleep && !showsUnavailableState
    }

    private var keepAliveHelp: String {
        switch keepAliveController.sleepPreventionSource {
        case .external:
            String(localized: "keep-alive.status.disabled-by-other-source")
        case .codexBar, .none:
            String(localized: "keep-alive.status.active")
        }
    }

    // MARK: - 卡片布局

    var body: some View {
        // 保留同一张卡片的视图身份, 空闲时只禁用交互, 避免打断内容和高度过渡
        Button {
            onTaskCenterTap(frameProvider)
        } label: {
            card(now: timelineDate)
        }
        .buttonStyle(ActivityCardButtonStyle())
        .disabled(!snapshot.hasTaskCenterContent)
        .contentShape(Rectangle())
        .background {
            ScreenFrameReader(provider: frameProvider)
        }
        .onHover { isHovered = $0 }
    }

    private func card(now: Date) -> some View {
        let content = content(at: now)
        return VStack(alignment: .leading, spacing: 0) {
            statusRow(content)
                .frame(height: Metrics.height)
                .id(snapshot.hasTaskCenterContent)
                .transition(.opacity)
            if let usage = content.tokenUsage {
                VStack(spacing: 8) {
                    LiquidGlassDivider()
                    tokenUsageMetrics(usage)
                }
                .frame(height: Metrics.usageHeight - Metrics.height, alignment: .top)
                .transition(.modifier(
                    active: ActivityTokenReveal(progress: 0),
                    identity: ActivityTokenReveal(progress: 1)
                ))
            }
        }
        .padding(.horizontal, MenuMetrics.panelPadding)
        .frame(maxWidth: .infinity)
        .modifier(ActivityCardHeight(height: content.tokenUsage == nil ? Metrics.height : Metrics.usageHeight))
        .activityStatusParticles(cornerRadius: MenuMetrics.panelCornerRadius)
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
        .animation(Metrics.expansionAnimation, value: snapshot.hasTaskCenterContent)
        .animation(Metrics.expansionAnimation, value: content.tokenUsage != nil)
    }

    private func statusRow(_ content: ActivityCardContent) -> some View {
        HStack(spacing: 10) {
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
                    ActivityStatusText(
                        text: detail,
                        tint: content.tint,
                        effect: statusTextEffect
                    )
                }
            }

            Spacer(minLength: 0)

            if content.isAnonymous {
                ActivityAnonymousIcon()
                    .transition(.opacity)
            }

            // 防睡眠只在任务运行期间生效, 所以状态挂在活动卡片上而不是单独占一行
            if showsKeepAliveBadge {
                // 隐藏或关闭动画效果时移除整个旋转视图, 避免保留持续渲染调度
                Group {
                    if allowsAnimations {
                        RotatingKeepAliveSun()
                    } else {
                        Image(systemName: "sun.max.fill")
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.teal)
                .transition(.opacity)
                .help(keepAliveHelp)
            }

            if content.otherTaskCount > 0 {
                Text(verbatim: "+\(content.otherTaskCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    // 必须是具体 Color, 层级样式在 numericText 的过渡层里会被重新解析成别的层级
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .contentTransition(.numericText(value: Double(content.otherTaskCount)))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .transition(.opacity)
                    .help(String(localized: "activity.summary.other-task-count", defaultValue: "\(content.otherTaskCount, specifier: "%lld")"))
            }
        }
        .animation(.codexStatus, value: showsKeepAliveBadge)
        .animation(.codexStatus, value: content.isAnonymous)
        // 任务数变化会让 +N 增删, 防睡眠徽标跟着横移; 动画只作用于状态行
        .animation(.codexStatus, value: content.otherTaskCount)
    }

    private func tokenUsageMetrics(_ usage: TokenUsage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            tokenMetric("usage.tokens.total", tokens: usage.totalTokens)
            tokenMetric("usage.tokens.input", tokens: usage.inputTokens)
            tokenMetric("usage.tokens.output", tokens: usage.outputTokens)
            tokenMetric("usage.tokens.cached-input", tokens: usage.cachedInputTokens)
            tokenMetric("usage.tokens.cache-write-input", tokens: usage.cacheWriteInputTokens)
            VStack(spacing: 3) {
                Text("usage.tokens.cache-hit-rate")
                    .font(.caption2)
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .minimumScaleFactor(0.65)
                Text(usage.cacheHitRate.map { $0.formatted(.percent.precision(.fractionLength(0 ... 1))) } ?? "—")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.codexLabel)
                    .contentTransition(.numericText(value: usage.cacheHitRate ?? 0))
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            tokenMetric("usage.tokens.reasoning-output", tokens: usage.reasoningOutputTokens)
        }
        .lineLimit(1)
        .animation(.codexStatus, value: usage)
    }

    private func tokenMetric(_ title: LocalizedStringKey, tokens: Int64) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.codexSecondaryLabel)
                .minimumScaleFactor(0.65)
            TokenCountText(tokens: Int(tokens), font: .caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color.codexLabel)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    // MARK: - 展示内容

    private func content(at now: Date) -> ActivityCardContent {
        switch snapshot.primaryActivity {
        case let .waiting(task):
            return activeContent(
                for: task,
                symbolName: "hand.raised.fill",
                tint: .orange,
                fallback: "activity.status.codex-waiting-for-approval",
                detailComponents: ActivityDisplayFormat.waitingDetailComponents(
                    for: task,
                    now: now
                )
            )
        case let .running(task):
            return activeContent(
                for: task,
                symbolName: "bolt.fill",
                tint: .blue,
                fallback: "common.codex",
                detailComponents: ActivityDisplayFormat.runningDetailComponents(
                    for: task,
                    now: now
                )
            )
        case let .completed(completion):
            let details = ActivityDisplayFormat.historyDetailComponents(
                duration: completion.duration,
                relativeText: ActivityDisplayFormat.completionRelativeText(completion.completedAt, now: now)
            )
            return ActivityCardContent(
                symbolName: "checkmark.circle.fill",
                tint: .green,
                title: activityTitle(
                    modelName: completion.modelName,
                    effort: completion.effort,
                    projectName: completion.projectName,
                    fallback: "activity.status.codex-completed"
                ),
                detail: details.joined(separator: " • "),
                otherTaskCount: 0,
                isAnonymous: completion.isAnonymous,
                tokenUsage: completion.tokenUsage
            )
        case let .terminated(termination):
            let details = ActivityDisplayFormat.historyDetailComponents(
                duration: termination.duration,
                relativeText: ActivityDisplayFormat.terminationRelativeText(termination.terminatedAt, now: now)
            )
            return ActivityCardContent(
                symbolName: "xmark.circle.fill",
                tint: .red,
                title: activityTitle(
                    modelName: termination.modelName,
                    effort: termination.effort,
                    projectName: termination.projectName,
                    fallback: "activity.status.codex-stopped"
                ),
                detail: details.joined(separator: " • "),
                otherTaskCount: 0,
                isAnonymous: termination.isAnonymous,
                tokenUsage: termination.tokenUsage
            )
        case .idle:
            return ActivityCardContent(
                symbolName: "moon.zzz.fill",
                tint: .secondary,
                title: showsUnavailableState
                    ? String(localized: "common.empty.no-data")
                    : String(localized: "activity.empty.no-activity"),
                detail: nil,
                otherTaskCount: 0,
                isAnonymous: false
            )
        }
    }

    private func activeContent(
        for task: ActivityTaskSnapshot,
        symbolName: String,
        tint: Color,
        fallback: LocalizedStringResource,
        detailComponents: [String]
    ) -> ActivityCardContent {
        let details = activeDetailComponents(detailComponents, task: task)
        return ActivityCardContent(
            symbolName: symbolName,
            tint: tint,
            title: activityTitle(
                modelName: task.modelName,
                effort: task.effort,
                projectName: task.projectName,
                fallback: fallback
            ),
            detail: details.joined(separator: " • "),
            otherTaskCount: otherTaskCount,
            isAnonymous: task.isAnonymous,
            tokenUsage: task.tokenUsage
        )
    }

    private func activityTitle(
        modelName: String?,
        effort: String?,
        projectName: String?,
        fallback: LocalizedStringResource
    ) -> String {
        [
            ActivityDisplayFormat.modelMetadata(
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
        task: ActivityTaskSnapshot
    ) -> [String] {
        guard let count = task.activeSubagentCount, count > 0 else {
            return components
        }
        var result = components
        result.insert(String(localized: "activity.summary.subagent-count", defaultValue: "\(count, specifier: "%lld")"), at: min(1, result.count))
        return result
    }

    private var otherTaskCount: Int {
        max(0, snapshot.activeCount - 1)
    }

    private var statusTextEffect: ActivityStatusText.Effect {
        guard allowsAnimations else { return .none }
        switch snapshot.primaryActivity {
        case .running: return .shimmer
        case let .waiting(task): return .ionizing(taskID: task.id)
        case .completed, .terminated, .idle: return .none
        }
    }

    private enum Metrics {
        static let height: CGFloat = 58
        static let usageHeight: CGFloat = 108
        static let expansionAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
    }
}

// MARK: - 动画

/// 逐帧更新布局高度, 让相邻区块和窗口同步调整
private struct ActivityCardHeight: AnimatableModifier {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height, alignment: .top)
            .clipped()
    }
}

/// 用展开进度控制显隐, 让动画中途反向时保持连贯
private struct ActivityTokenReveal: AnimatableModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(Double(min(1, max(0, (progress - 0.6) / 0.4))))
            .offset(y: (1 - progress) * 4)
    }
}

private struct RotatingKeepAliveSun: View {
    @State private var isRotating = false

    var body: some View {
        Image(systemName: "sun.max.fill")
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isRotating)
            .onAppear { isRotating = true }
    }
}

// MARK: - 辅助视图与展示模型

/// 悬停和选中效果由卡片绘制, 按钮样式保留原有颜色和透明度
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
    let isAnonymous: Bool
    var tokenUsage: TokenUsage?
}

struct ActivityAnonymousIcon: View {
    var body: some View {
        Image(systemName: "person.crop.circle.dashed")
            // 虚线圆形 symbol 留白较多, 适当放大以接近相邻状态图标的视觉面积
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.orange)
            .help("activity.anonymous.keep-awake-exclusion")
    }
}
