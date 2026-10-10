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
    @State private var wrappedHeaderTaskIDs: Set<UUID> = []

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

    /// 活动源不可用时隐藏防睡眠徽标, 保持状态一致
    private var showsKeepAliveBadge: Bool {
        keepAliveController.isActivelyPreventingSleep && !showsUnavailableState
    }

    // MARK: - 卡片布局

    var body: some View {
        // 连接状态提示沿用卡片容器, 无任务记录时禁止打开任务中心
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
        .onChange(of: retainedHeaderTaskIDs) { _, retainedIDs in
            wrappedHeaderTaskIDs.formIntersection(retainedIDs)
        }
    }

    private func card(now: Date) -> some View {
        let content = content(at: now)
        return VStack(alignment: .leading, spacing: 0) {
            statusRow(content)
                .frame(minHeight: content.detail == nil ? nil : Metrics.height)
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
        .animation(Metrics.expansionAnimation, value: content.detail == nil)
    }

    private func statusRow(_ content: ActivityCardContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: content.symbolName)
                .font(.caption.weight(.semibold))
                .imageScale(.large)
                .foregroundStyle(content.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                statusHeader(content)

                if let detail = content.detail {
                    ActivityStatusText(
                        text: detail, tint: content.tint, effect: statusTextEffect,
                        lineLimit: nil, supplement: content.detailSupplement
                    )
                    .numericTransition(value: [detail, content.detailSupplement], enabled: allowsAnimations)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let recent = content.recent {
                    Text(recent)
                        .font(.caption2)
                        .foregroundStyle(Color.codexSecondaryLabel)
                        .numericTransition(value: recent, enabled: allowsAnimations)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12)
        .padding(.bottom, content.detail == nil ? 8 : 12)
        .animation(.codexStatus, value: showsKeepAliveBadge)
        // 徽标只占用标题行的宽度, 下方状态和附加信息可以使用完整文本区域
        .animation(.codexStatus, value: content.otherTaskCount)
    }

    private func statusHeader(_ content: ActivityCardContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ActivitySummaryText(
                components: content.headerLines,
                primaryLineLimit: 1,
                primaryTruncationMode: .middle,
                supplementaryLineLimit: 1,
                singleLineWidthReserve: Metrics.headerWidthReserve,
                wrappedLayout: wrappedHeaderLayout(for: content.taskID)
            )
            // 换行锁定只属于当前任务, 新任务在首次布局时重新判断
            .id(content.taskID)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.codexLabel)
            .numericTransition(value: content.header, enabled: allowsAnimations)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if content.otherTaskCount > 0 || showsKeepAliveBadge {
                statusBadges(content)
                    .fixedSize()
            }
        }
    }

    private var retainedHeaderTaskIDs: Set<UUID> {
        Set(snapshot.waitingTasks.map(\.id)
            + snapshot.runningTasks.map(\.id)
            + snapshot.recentCompletions.map { $0.taskID ?? $0.id }
            + snapshot.recentTerminations.map { $0.taskID ?? $0.id })
    }

    private func wrappedHeaderLayout(for taskID: UUID?) -> Binding<Bool>? {
        guard let taskID else { return nil }
        return Binding(
            get: { wrappedHeaderTaskIDs.contains(taskID) },
            set: { isWrapped in
                if isWrapped {
                    wrappedHeaderTaskIDs.insert(taskID)
                }
            }
        )
    }

    private func statusBadges(_ content: ActivityCardContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if content.otherTaskCount > 0 {
                Text(verbatim: "+\(content.otherTaskCount)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    // 必须是具体 Color, 层级样式在 numericText 的过渡层里会被重新解析成别的层级
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .numericTransition(value: content.otherTaskCount, comparison: Double(content.otherTaskCount), enabled: allowsAnimations)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .transition(.opacity)
                    .help(String(localized: "activity.summary.other-task-count", defaultValue: "\(content.otherTaskCount, specifier: "%lld")"))
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
            }
        }
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
                    .numericTransition(value: usage.cacheHitRate, comparison: usage.cacheHitRate ?? 0, enabled: allowsAnimations)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            tokenMetric("usage.tokens.reasoning-output", tokens: usage.reasoningOutputTokens)
        }
        .lineLimit(1)
        .animation(allowsAnimations ? .codexStatus : nil, value: usage)
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
        switch snapshot.panelPrimaryActivity {
        case let .waiting(task):
            return activeContent(
                for: task,
                symbolName: "hand.raised.fill",
                tint: .orange,
                waiting: true
            )
        case let .running(task):
            return activeContent(
                for: task,
                symbolName: "bolt.fill",
                tint: .blue,
                waiting: false
            )
        case let .completed(completion):
            let details = ActivityDisplayFormat.historyDetailComponents(
                duration: completion.duration,
                relativeText: ActivityDisplayFormat.completionRelativeText(completion.completedAt, now: now)
            )
            return ActivityCardContent(
                taskID: completion.taskID ?? completion.id,
                symbolName: "checkmark.circle.fill",
                tint: .green,
                detail: nil,
                otherTaskCount: 0,
                tokenUsage: completion.tokenUsage,
                header: [
                    completion.projectName ?? String(localized: "common.codex"),
                    ActivityDisplayFormat.modelMetadata(modelName: completion.modelName, effort: completion.effort)
                ].compactMap(\.self) + details
            )
        case let .terminated(termination):
            let details = ActivityDisplayFormat.historyDetailComponents(
                duration: termination.duration,
                relativeText: ActivityDisplayFormat.terminationRelativeText(termination.terminatedAt, now: now)
            )
            return ActivityCardContent(
                taskID: termination.taskID ?? termination.id,
                symbolName: "xmark.circle.fill",
                tint: .red,
                detail: ActivityLiveLabel(termination.isFailure ? "failed" : "interrupted").text,
                otherTaskCount: 0,
                tokenUsage: termination.tokenUsage,
                header: [
                    termination.projectName ?? String(localized: "common.codex"),
                    ActivityDisplayFormat.modelMetadata(modelName: termination.modelName, effort: termination.effort)
                ].compactMap(\.self) + details
            )
        case .idle:
            return ActivityCardContent(
                symbolName: "moon.zzz.fill",
                tint: .secondary,
                detail: activityMonitor.sourcePresentation?.text,
                otherTaskCount: 0,
                header: [String(localized: "common.codex")]
            )
        }
    }

    private func activeContent(
        for task: ActivityTaskSnapshot,
        symbolName: String,
        tint: Color,
        waiting: Bool
    ) -> ActivityCardContent {
        let summary = ActivityDisplayFormat.liveSummaryComponents(for: task, now: timelineDate, waiting: waiting)
        return ActivityCardContent(
            taskID: task.id,
            symbolName: symbolName,
            tint: tint,
            detail: ActivityDisplayFormat.liveStatus(for: task, waiting: waiting),
            otherTaskCount: otherTaskCount,
            tokenUsage: task.tokenUsage,
            header: [
                task.projectName ?? String(localized: "common.codex"),
                ActivityDisplayFormat.modelMetadata(modelName: task.modelName, effort: task.effort)
            ].compactMap(\.self) + summary.prefix(1),
            recent: ActivityDisplayFormat.recentEvent(for: task),
            detailSupplement: summary.dropFirst().first
        )
    }

    private var otherTaskCount: Int {
        max(0, snapshot.activeCount - 1)
    }

    private var statusTextEffect: ActivityStatusText.Effect {
        guard allowsAnimations else { return .none }
        switch snapshot.panelPrimaryActivity {
        case .running: return .shimmer
        case let .waiting(task): return .ionizing(taskID: task.id)
        case .completed, .terminated, .idle: return .none
        }
    }

    private enum Metrics {
        // 单行排版为时间文案增长预留宽度
        static let headerWidthReserve: CGFloat = 32
        static let height: CGFloat = 58
        static let usageHeight: CGFloat = 108
        static let expansionAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
    }
}

// MARK: - 动画

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
    var taskID: UUID?
    let symbolName: String
    let tint: Color
    let detail: String?
    let otherTaskCount: Int
    var tokenUsage: TokenUsage?
    let header: [String]
    var recent: String?
    var detailSupplement: String?

    var headerLines: [String] {
        [header.first ?? "", header.dropFirst().joined(separator: " • ")]
            .filter { !$0.isEmpty }
    }
}
