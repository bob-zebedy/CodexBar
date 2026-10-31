import SwiftUI

/// 实时任务摘要, 使用主面板共享的时间
/// 活动和防睡眠状态由卡片自行观察, 避免刷新整个菜单树
struct ActivityCard: View {
    @ObservedObject var activityMonitor: ActivityMonitor
    @ObservedObject var centerPresentation: ActivityCenterPresentationState
    @ObservedObject var cardPresentation: ActivityCardPresentationState
    @ObservedObject var keepAliveController: KeepAliveController
    let onTaskCenterTap: (ActivityCenterPanelAnchor) -> Void
    @Environment(\.contentAnimationsEnabled) private var allowsAnimations
    @State private var frameProvider = ActivityCenterPanelAnchor()
    @State private var isHovered = false
    @State private var wrappedHeaderKeys: Set<HeaderWrappingKey> = []
    @State private var retainedContent: ActivityCardContent?
    @State private var outgoingContent: ActivityCardContent?
    @State private var cardSize = CGSize.zero
    @State private var swipe = ActivityCardSwipe()
    @State private var swipeContent: ActivityCardSwipeContent?
    @State private var gestureOwner = UUID()
    @State private var incomingOffset: CGFloat = 0
    @State private var outgoingOffset: CGFloat = 0
    @State private var incomingOpacity = 1.0
    @State private var outgoingOpacity = 1.0
    @State private var animationGeneration = 0

    private var selection: ActivityCardSelection {
        cardPresentation.selection
    }

    private var cardWidth: CGFloat {
        cardSize.width
    }

    private var snapshot: ActivitySnapshot {
        activityMonitor.snapshot
    }

    private var showsUnavailableState: Bool {
        !activityMonitor.isActivitySourceHealthy
    }

    private var timelineDate: Date {
        centerPresentation.timelineDate
    }

    private var isTaskCenterPresented: Bool {
        centerPresentation.isPresented
    }

    /// 活动源不可用时隐藏防睡眠徽标, 保持状态一致
    private var showsKeepAliveBadge: Bool {
        keepAliveController.isActivelyPreventingSleep && !showsUnavailableState
    }

    private var currentContent: ActivityCardContent? {
        guard selection.current != nil || showsUnavailableState else { return nil }
        return displayContent(for: showsUnavailableState ? .idle : (selection.current ?? .idle))
    }

    private func displayContent(for activity: CodexPrimaryActivity) -> ActivityCardContent {
        var value = content(for: activity, at: timelineDate)
        value.selectionID = activity.cardSelectionID
        value.showsKeepAliveBadge = showsKeepAliveBadge
        value.positionText = selection.positionText(for: value.selectionID)
        value.hasPin = selection.pinnedID != nil && selection.current != nil
        value.isPinned = selection.pinnedID != nil && selection.pinnedID == value.selectionID
        return value
    }

    // MARK: - 卡片布局

    var body: some View {
        // 连接状态提示沿用卡片容器, 无任务记录时禁止打开任务中心
        Button {
            onTaskCenterTap(frameProvider)
        } label: {
            if let content = retainedContent ?? currentContent {
                card(content)
            }
        }
        .buttonStyle(ActivityCardButtonStyle())
        .disabled(!snapshot.hasTaskCenterContent)
        .contentShape(Rectangle())
        .background {
            ActivityCenterPanelAnchorReader(anchor: frameProvider)
            ActivityCardEvents(
                isEnabled: selection.isVisible && selection.current != nil && !showsUnavailableState,
                onSwipe: handleSwipe,
                onTogglePin: {
                    cancelSwipe()
                    cardPresentation.togglePin()
                }
            )
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.frame(in: .named(ActivityCenterPanelAnchor.coordinateSpace)).minY
        } action: { frameProvider.updateTopOffset($0) }
        .onHover { isHovered = $0 }
        .onChange(of: currentContent, initial: true) { _, content in updateContent(content) }
        .onChange(of: allowsAnimations) { _, enabled in
            if !enabled {
                completeSwipe()
                settleTransition()
                cardPresentation.setGestureActive(false, owner: gestureOwner)
                retainedContent = currentContent
            }
        }
        .onChange(of: selection.isVisible) { _, visible in
            if !visible {
                cancelSwipe()
            }
        }
        .onChange(of: selection.isGestureActive) { _, active in
            if !active {
                cancelSwipe()
            }
        }
        .onDisappear { cancelSwipe() }
        .task(id: swipe.settlement) {
            guard let settlement = swipe.settlement else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, settlement.duration - Date().timeIntervalSince(settlement.startedAt))))
            } catch { return }
            guard swipe.settlement == settlement else { return }
            completeSwipe()
        }
        .onChange(of: retainedHeaderTaskIDs) { _, retainedIDs in
            wrappedHeaderKeys = wrappedHeaderKeys.filter { retainedIDs.contains($0.taskID) }
        }
    }

    // MARK: - 交互翻页

    private func handleSwipe(_ event: ActivityCardEvents.SwipeEvent) {
        switch event {
        case .began:
            beginSwipe()
        case let .changed(delta):
            swipe.move(by: delta, width: cardWidth)
        case let .ended(velocity):
            swipe.end(velocity: velocity, width: cardWidth, cancelled: false, now: Date())
            if !allowsAnimations {
                completeSwipe()
            }
        case .cancelled:
            swipe.end(velocity: 0, width: cardWidth, cancelled: true, now: Date())
            if !allowsAnimations {
                completeSwipe()
            }
        case let .step(direction):
            completeSwipe()
            guard selection.carouselActivities.count > 1 else { return }
            cardPresentation.setGestureActive(true, owner: gestureOwner)
            cardPresentation.swipe(direction)
            updateContent(currentContent)
        }
    }

    private func beginSwipe() {
        guard selection.isVisible, selection.carouselActivities.count > 1, cardWidth > 0, cardSize.height > 0 else { return }
        cardPresentation.setGestureActive(true, owner: gestureOwner)
        let previous = swipeContent
        let step = swipe.begin(width: cardWidth, now: Date())
        if step != 0, let id = previous?.content(at: step).selectionID {
            cardPresentation.selectAfterSwipe(id, owner: gestureOwner)
        }
        let carousel = selection.carouselActivities
        guard let index = carousel.firstIndex(where: { $0.cardSelectionID == selection.selectedID }) else {
            cancelSwipe()
            return
        }
        func page(_ step: Int) -> ActivityCardContent {
            let activity = carousel[(index + step + carousel.count) % carousel.count]
            return previous?.matching(activity.cardSelectionID) ?? displayContent(for: activity)
        }
        swipeContent = ActivityCardSwipeContent(
            previous: page(-1), current: page(0), next: page(1)
        )
        settleTransition()
    }

    private func completeSwipe() {
        guard let pages = swipeContent else { return }
        let step = swipe.settlement?.step ?? 0
        if step != 0, let id = pages.content(at: step).selectionID {
            cardPresentation.selectAfterSwipe(id, owner: gestureOwner)
        }
        clearSwipe()
        cardPresentation.setGestureActive(false, owner: gestureOwner)
        retainedContent = currentContent
    }

    private func cancelSwipe() {
        guard swipe.isActive || swipeContent != nil || outgoingContent != nil || selection.isGestureActive else { return }
        clearSwipe()
        settleTransition()
        cardPresentation.setGestureActive(false, owner: gestureOwner)
    }

    private func clearSwipe() {
        swipe = ActivityCardSwipe()
        swipeContent = nil
    }

    private func settleTransition() {
        animationGeneration += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingContent = nil
            incomingOffset = 0
            outgoingOffset = 0
            incomingOpacity = 1
            outgoingOpacity = 1
        }
    }

    private func updateContent(_ content: ActivityCardContent?) {
        if let pages = swipeContent {
            let available = Set(selection.activities.compactMap(\.cardSelectionID))
            if selection.isGestureActive, !showsUnavailableState, selection.selectedID == pages.current.selectionID,
               [pages.previous, pages.current, pages.next].allSatisfy({ $0.selectionID.map(available.contains) == true }) {
                return
            }
            cancelSwipe()
        }
        // 退场期间保留最后一份内容, 避免正在收回的区域变为空卡片
        guard let content else { return }
        guard let previous = retainedContent, content.requiresContentTransition(from: previous) else {
            retainedContent = content
            if outgoingContent == nil {
                cardPresentation.setGestureActive(false, owner: gestureOwner)
            }
            return
        }
        settleTransition()
        guard allowsAnimations, cardWidth > 0 else {
            retainedContent = content
            cardPresentation.setGestureActive(false, owner: gestureOwner)
            return
        }
        let generation = animationGeneration
        // 手动切换的方向只用于不同轮播项之间, 同一 thread 的新 turn 仍沿用淡入淡出
        let slides = selection.transitionDirection != nil
            && content.selectionID != nil && previous.selectionID != nil && content.selectionID != previous.selectionID
        let distance = CGFloat(selection.transitionDirection ?? 0) * cardWidth
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            outgoingContent = previous
            retainedContent = content
            incomingOffset = slides ? distance : 0
            incomingOpacity = slides ? 1 : 0
        }
        Task { @MainActor in
            await Task.yield()
            guard generation == animationGeneration else { return }
            let animation = slides
                ? Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)
                : .easeInOut(duration: 0.2)
            withAnimation(animation, completionCriteria: .removed) {
                incomingOffset = 0
                incomingOpacity = 1
                outgoingOffset = slides ? -distance : 0
                outgoingOpacity = slides ? 1 : 0
            } completion: {
                guard generation == animationGeneration else { return }
                outgoingContent = nil
                if slides {
                    cardPresentation.setGestureActive(false, owner: gestureOwner)
                }
            }
        }
    }

    private func card(_ content: ActivityCardContent) -> some View {
        cardPages(content)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ActivityCardNaturalHeightKey.self,
                        value: .init(height: geometry.size.height, isInteractive: swipeContent != nil)
                    )
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if cardWidth != size.width {
                    cancelSwipe()
                }
                cardSize = size
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
            .overlay {
                ActivityCardWaitingEdges(
                    left: selection.waitingSides.left,
                    right: selection.waitingSides.right,
                    animates: allowsAnimations
                )
                .clipShape(RoundedRectangle(cornerRadius: MenuMetrics.panelCornerRadius))
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func cardPages(_ content: ActivityCardContent) -> some View {
        if let pages = swipeContent {
            ActivityCardSwipePages(swipe: swipe, width: cardWidth) { step in
                cardContent(pages.content(at: step))
            }
        } else {
            cardContent(content)
                .offset(x: incomingOffset)
                .opacity(incomingOpacity)
                .overlay(alignment: .topLeading) {
                    if let outgoingContent {
                        cardContent(outgoingContent)
                            .frame(width: cardWidth)
                            .offset(x: outgoingOffset)
                            .opacity(outgoingOpacity)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func cardContent(_ content: ActivityCardContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(content)
                // 切换任务时重建文本状态, 避免前一个任务的数字动画影响新布局
                .id(content.taskID)
                .transition(.identity)
            if let tokenUsage = content.tokenUsage {
                LiquidGlassDivider()
                tokenUsageMetrics(tokenUsage)
            }
        }
        .padding(.horizontal, MenuMetrics.panelPadding)
        // 外侧留白跟随自然内容, 区域伸缩时保持顶部锚定, 不重新分配空白
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        // 文字保持自然排版, 页间位移和可见高度由外层控制
        .transaction { $0.animation = nil }
        // 在内容事务之外统一处理位移, 避免内部文字动画覆盖整张卡片的推入推出
        .geometryGroup()
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
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        if content.showsCurrentEvent {
                            Text(verbatim: String(localized: "activity.live.current-event") + ": ")
                                .foregroundStyle(Color.codexSecondaryLabel)
                                .fixedSize()
                        }
                        ActivityStatusText(
                            text: detail, tint: content.tint, effect: allowsAnimations ? content.statusTextEffect : .none,
                            lineLimit: nil, supplement: content.detailSupplement
                        )
                        .numericTransition(value: [detail, content.detailSupplement])
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(MenuMetrics.bodyFont)
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
    }

    private func statusHeader(_ content: ActivityCardContent) -> some View {
        ActivityCardHeader(
            components: content.headerLines,
            projectName: content.projectName,
            positionText: content.positionText,
            hasPin: content.hasPin,
            isPinned: content.isPinned,
            showsKeepAliveBadge: content.showsKeepAliveBadge,
            usesWrappedLayout: wrappedHeaderLayout(for: content)
        )
    }

    private var retainedHeaderTaskIDs: Set<UUID> {
        Set(snapshot.waitingTasks.map(\.id)
            + snapshot.runningTasks.map(\.id)
            + snapshot.recentCompletions.map { $0.taskID ?? $0.id }
            + snapshot.recentTerminations.map { $0.taskID ?? $0.id })
            .union([retainedContent?.taskID].compactMap(\.self))
    }

    /// 徽标组合变化会改变剩余宽度, 相同组合仍保留任务的换行状态
    private struct HeaderWrappingKey: Hashable {
        let taskID: UUID
        let hasPin: Bool
        let positionLength: Int
        let showsKeepAliveBadge: Bool
    }

    private func wrappedHeaderLayout(for content: ActivityCardContent) -> Binding<Bool>? {
        guard let taskID = content.taskID else { return nil }
        let key = HeaderWrappingKey(
            taskID: taskID,
            hasPin: content.hasPin,
            positionLength: content.positionText?.count ?? 0,
            showsKeepAliveBadge: content.showsKeepAliveBadge
        )
        return Binding(
            get: { wrappedHeaderKeys.contains(key) },
            set: { isWrapped in
                if isWrapped {
                    wrappedHeaderKeys.insert(key)
                }
            }
        )
    }

    private func tokenUsageMetrics(_ tokenUsage: TokenUsage) -> some View {
        ActivityTokenRowLayout {
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

    private func content(for activity: CodexPrimaryActivity, at now: Date) -> ActivityCardContent {
        switch activity {
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
                projectName: completion.projectName,
                symbolName: "checkmark.circle.fill",
                tint: .green,
                detail: nil,
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
                projectName: termination.projectName,
                symbolName: "xmark.circle.fill",
                tint: .red,
                detail: ActivityLiveLabel(termination.isFailure ? "failed" : "interrupted").text,
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
            projectName: task.projectName,
            symbolName: symbolName,
            tint: tint,
            detail: ActivityDisplayFormat.liveStatus(for: task, waiting: waiting),
            tokenUsage: task.tokenUsage,
            header: [
                task.projectName ?? String(localized: "common.codex"),
                ActivityDisplayFormat.modelMetadata(modelName: task.modelName, effort: task.effort)
            ].compactMap(\.self) + summary.prefix(1),
            recent: ActivityDisplayFormat.recentEvent(for: task),
            detailSupplement: summary.dropFirst().first,
            showsCurrentEvent: true,
            statusTextEffect: allowsAnimations ? (waiting ? .ionizing(taskID: task.id) : .shimmer) : .none
        )
    }
}

// MARK: - 辅助视图与展示模型

/// 使用父容器给定的宽度, 防止等分列的浮点累加误差改变卡片的像素对齐
private struct ActivityTokenRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let size = content.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }
}

/// 悬停和选中效果由卡片绘制, 按钮样式保留原有颜色和透明度
private struct ActivityCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct ActivityCardSwipeContent {
    let previous: ActivityCardContent
    let current: ActivityCardContent
    let next: ActivityCardContent

    func content(at step: Int) -> ActivityCardContent {
        step == 0 ? current : (step < 0 ? previous : next)
    }

    func matching(_ id: String?) -> ActivityCardContent? {
        [current, previous, next].first { $0.selectionID == id }
    }
}

private struct ActivityCardContent: Equatable {
    var taskID: UUID?
    var selectionID: String?
    var projectName: String?
    let symbolName: String
    let tint: Color
    let detail: String?
    var tokenUsage: TokenUsage?
    let header: [String]
    var recent: String?
    var detailSupplement: String?
    var showsCurrentEvent = false
    var showsKeepAliveBadge = false
    var positionText: String?
    var hasPin = false
    var isPinned = false
    var statusTextEffect = ActivityStatusText.Effect.none

    func requiresContentTransition(from previous: Self) -> Bool {
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
