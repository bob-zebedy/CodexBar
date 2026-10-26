import SwiftUI

/// 实时任务摘要, 使用主面板共享的时间
/// 活动和防睡眠状态由卡片自行观察, 避免刷新整个菜单树
struct ActivityCard: View {
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var presentationState: ActivityCenterPresentationState
    @ObservedObject var keepAliveController: KeepAliveController
    let onTaskCenterTap: (ScreenFrameProvider) -> Void
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    @State private var frameProvider = ScreenFrameProvider()
    @State private var isHovered = false
    @State private var wrappedHeaderTaskIDs: Set<UUID> = []
    @State private var retainedContent: ActivityCardContent?
    @State private var outgoingContent: ActivityCardContent?

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

    private var currentContent: ActivityCardContent? {
        guard snapshot.hasTaskCenterContent || showsUnavailableState else { return nil }
        var value = content(at: timelineDate)
        value.showsKeepAliveBadge = showsKeepAliveBadge
        value.statusTextEffect = statusTextEffect
        return value
    }

    // MARK: - 卡片布局

    var body: some View {
        // 连接状态提示沿用卡片容器, 无任务记录时禁止打开任务中心
        Button {
            onTaskCenterTap(frameProvider)
        } label: {
            if let content = currentContent ?? retainedContent {
                card(content)
            }
        }
        .buttonStyle(ActivityCardButtonStyle())
        .disabled(!snapshot.hasTaskCenterContent)
        .contentShape(Rectangle())
        .background {
            ScreenFrameReader(provider: frameProvider)
        }
        .onHover { isHovered = $0 }
        .onChange(of: currentContent, initial: true) { _, content in
            // 退场期间保留最后一份展示内容, 不把正在收回的任务替换成空状态
            if let content {
                if allowsAnimations, let previous = retainedContent, content.requiresCrossfade(from: previous) {
                    outgoingContent = previous
                }
                retainedContent = content
            }
        }
        .task(id: outgoingContent) {
            guard outgoingContent != nil else { return }
            // 先保留旧内容的完整一帧, 下一次更新只交接透明度, 不参与自然高度测量
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(allowsAnimations ? .easeInOut(duration: 0.2) : nil) {
                outgoingContent = nil
            }
        }
        .onChange(of: retainedHeaderTaskIDs) { _, retainedIDs in
            wrappedHeaderTaskIDs.formIntersection(retainedIDs)
        }
    }

    private func card(_ content: ActivityCardContent) -> some View {
        cardContent(content)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ActivityCardNaturalHeightKey.self, value: geometry.size.height)
                }
            }
            .opacity(outgoingContent == nil ? 1 : 0)
            .overlay(alignment: .topLeading) {
                if let outgoingContent {
                    cardContent(outgoingContent)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // 外层可以收起整个区域, 内部文字始终按自然高度排版
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
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
    }

    private func cardContent(_ content: ActivityCardContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            statusRow(content)
                // 换行只向下增加高度, 避免居中留白改变首行和图标的位置
                .frame(minHeight: content.detail == nil ? nil : Metrics.height, alignment: .top)
                // 切换任务时重新建立文本状态, 不让前一个任务的数字过渡穿过新布局
                .id(content.taskID)
                .transition(.identity)
            if let tokenUsage = content.tokenUsage {
                VStack(spacing: 8) {
                    LiquidGlassDivider()
                    tokenUsageMetrics(tokenUsage)
                }
                .frame(height: Metrics.usageHeight - Metrics.height, alignment: .top)
            }
        }
        .padding(.horizontal, MenuMetrics.panelPadding)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        // 内容只上报自然高度, 显示和尺寸变化都由区域容器统一驱动
        .transaction { $0.animation = nil }
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
                        text: detail, tint: content.tint, effect: allowsAnimations ? content.statusTextEffect : .none,
                        lineLimit: nil, supplement: content.detailSupplement
                    )
                    .font(MenuMetrics.bodyFont)
                    .numericTransition(value: [detail, content.detailSupplement])
                    .fixedSize(horizontal: false, vertical: true)
                    .clipped()
                }
                if let recent = content.recent {
                    Text(recent)
                        .font(MenuMetrics.bodyFont)
                        .foregroundStyle(Color.codexSecondaryLabel)
                        .numericTransition(value: recent)
                        .fixedSize(horizontal: false, vertical: true)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12)
        .padding(.bottom, content.detail == nil ? 8 : 12)
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
            .font(MenuMetrics.titleFont)
            .foregroundStyle(Color.codexLabel)
            .numericTransition(value: content.header)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .leading)
            if content.otherTaskCount > 0 || content.showsKeepAliveBadge {
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
            .union([retainedContent?.taskID].compactMap(\.self))
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
                    .font(MenuMetrics.badgeFont)
                    // 必须是具体 Color, 层级样式在 numericText 的过渡层里会被重新解析成别的层级
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .numericTransition(value: content.otherTaskCount, comparison: Double(content.otherTaskCount))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .transition(.opacity)
                    .help(String(localized: "activity.summary.other-task-count", defaultValue: "\(content.otherTaskCount, specifier: "%lld")"))
            }
            // 防睡眠由任务状态驱动, 徽标跟随活动卡片展示
            if content.showsKeepAliveBadge {
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
        .animation(.codexStatus, value: content.showsKeepAliveBadge)
        .animation(.codexStatus, value: content.otherTaskCount)
    }

    private func tokenUsageMetrics(_ tokenUsage: TokenUsage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            tokenMetric("usage.token-usage.total", tokens: tokenUsage.totalTokens)
            tokenMetric("usage.token-usage.output", tokens: tokenUsage.outputTokens)
            tokenMetric("usage.token-usage.input", tokens: tokenUsage.inputTokens)
            tokenMetric("usage.token-usage.reasoning-output", tokens: tokenUsage.reasoningOutputTokens)
            tokenMetric("usage.token-usage.cache-write-input", tokens: tokenUsage.cacheWriteInputTokens)
            tokenMetric("usage.token-usage.cached-input", tokens: tokenUsage.cachedInputTokens)
            VStack(spacing: 3) {
                Text("usage.token-usage.cache-hit-rate")
                    .font(MenuMetrics.bodyFont)
                    .foregroundStyle(Color.codexSecondaryLabel)
                    .minimumScaleFactor(0.65)
                Text(tokenUsage.cacheHitRate.map { $0.formatted(.percent.precision(.fractionLength(0 ... 1))) } ?? "—")
                    .font(MenuMetrics.valueFont)
                    .foregroundStyle(Color.codexLabel)
                    .numericTransition(value: tokenUsage.cacheHitRate, comparison: tokenUsage.cacheHitRate ?? 0)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .lineLimit(1)
        .animation(allowsAnimations ? .codexStatus : nil, value: tokenUsage)
    }

    private func tokenMetric(_ title: LocalizedStringKey, tokens: Int64) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(MenuMetrics.bodyFont)
                .foregroundStyle(Color.codexSecondaryLabel)
                .minimumScaleFactor(0.65)
            TokenCountText(tokens: Int(tokens), font: MenuMetrics.valueFont)
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
                symbolName: "bubble.left.and.exclamationmark.bubble.right",
                tint: .red,
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
    }
}

// MARK: - 动画

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

private struct ActivityCardContent: Equatable {
    var taskID: UUID?
    let symbolName: String
    let tint: Color
    let detail: String?
    let otherTaskCount: Int
    var tokenUsage: TokenUsage?
    let header: [String]
    var recent: String?
    var detailSupplement: String?
    var showsKeepAliveBadge = false
    var statusTextEffect = ActivityStatusText.Effect.none

    func requiresCrossfade(from previous: Self) -> Bool {
        taskID != previous.taskID || symbolName != previous.symbolName
            || (tokenUsage == nil) != (previous.tokenUsage == nil)
            || (detail == nil) != (previous.detail == nil)
            || (recent == nil) != (previous.recent == nil)
    }

    var headerLines: [String] {
        [header.first ?? "", header.dropFirst().joined(separator: " • ")]
            .filter { !$0.isEmpty }
    }
}
