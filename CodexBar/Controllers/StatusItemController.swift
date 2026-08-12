import AppKit
import Combine
import os
import SwiftUI

/// 菜单栏入口控制器, 统一管理状态图标, 菜单面板, 右键菜单和全局快捷键
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let viewModel: CodexStatusViewModel
    private let workflowViewModel: WorkflowViewModel
    private let codexHookSettings: CodexHookSettings
    private let codexCLINotificationSettings: CodexCLINotificationSettings
    private let activityMonitor: CodexActivityMonitor
    private let syncSettings: WorkflowSyncSettings
    private let globalHotKeySettings: GlobalHotKeySettings
    private let menuBarQuotaSettings: MenuBarQuotaSettings
    private let mainPanelSettings: MainPanelSettings
    private let notificationSettings: NotificationSettings
    private let resetCreditAutomationSettings: ResetCreditAutomationSettings
    private let keepAliveController: KeepAliveController
    private let appUpdater: AppUpdater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let menuSurfaceVisibility = MenuSurfaceVisibilityState()
    private let activityCenterPresentationState = CodexActivityCenterPresentationState()
    private let heatmapDetailPanelController = HeatmapDetailPanelController()
    private let resetCreditsPanelController = ResetCreditsPanelController()
    private lazy var activityCenterPanelController = ActivityCenterPanelController(
        activityMonitor: activityMonitor,
        presentationState: activityCenterPresentationState
    )
    private var activeMenuSurface = ActiveMenuSurface.none
    private lazy var globalHotKeyController = GlobalHotKeyController { [weak self] in
        self?.toggleMenuSurfaceFromHotKey()
    }

    private lazy var fallbackPanelController = FallbackPanelController { [unowned self] in
        makeMenuHostingController(usesPreferredContentSize: false)
    }

    private lazy var settingsWindowController = SettingsWindowController(
        viewModel: viewModel,
        appUpdater: appUpdater,
        codexHookSettings: codexHookSettings,
        codexCLINotificationSettings: codexCLINotificationSettings,
        syncSettings: syncSettings,
        globalHotKeySettings: globalHotKeySettings,
        menuBarQuotaSettings: menuBarQuotaSettings,
        mainPanelSettings: mainPanelSettings,
        notificationSettings: notificationSettings,
        resetCreditAutomationSettings: resetCreditAutomationSettings,
        activityProtectionSettings: activityMonitor.activityProtectionSettings,
        keepAliveController: keepAliveController
    ) { [weak self] in
        self?.statusItem.button?.window?.screen
    } onSyncChanged: { [weak self] _ in
        // setEnabled 在回调之前已经写回属性, 现场求值就是新结论
        self?.workflowSyncScheduler.requestSync(trigger: .settings)
    } onRebuildWorkflowData: { [weak self] dateKeys, completion in
        guard let self else {
            completion(.failure(CancellationError()))
            return
        }
        workflowSyncScheduler.requestRebuild(for: dateKeys, completion: completion)
    }

    private lazy var logWindowController = LogWindowController { [weak self] in
        self?.statusItem.button?.window?.screen
    }

    private lazy var workflowSyncScheduler = WorkflowSyncScheduler(
        viewModel: workflowViewModel,
        syncActivation: { [weak self] in
            self?.workflowSyncActivation ?? .syncOff
        }
    )

    private lazy var menuSurfaceFadeCoordinator = MenuSurfaceFadeCoordinator(
        contentViewProvider: { [weak self] in
            self?.activeMenuSurfaceContentView
        },
        closeActiveMenuSurface: { [weak self] in
            self?.closeActiveMenuSurface()
        }
    )
    private lazy var menuSurfaceDismissMonitor = MenuSurfaceDismissMonitor(
        isPresented: { [weak self] in
            self?.isActiveMenuSurfaceVisible == true
        },
        windowProvider: { [weak self] in
            self?.activeMenuSurfaceWindow
        },
        statusButtonProvider: { [weak self] in
            self?.statusItem.button
        },
        isPointInExtraSurface: { [weak self] screenPoint in
            self?.isPointInDetailPanel(screenPoint) == true
        }
    )
    private var delayedStatusRefreshTask: Task<Void, Never>?
    private var menuSurfaceState = MenuSurfaceState.hidden
    private var cancellables = Set<AnyCancellable>()
    private var statusIconState: StatusIconState?
    private var statusIconAnimationTask: Task<Void, Never>?
    private var statusToolTipTask: Task<Void, Never>?
    private var registeredHotKeyShortcut: GlobalHotKeyShortcut?
    private var auxiliaryWindowFocusRestoreTask: Task<Void, Never>?
    private var activeStatusItemMenu: NSMenu?
    private var pendingStatusItemMenuAction: (@MainActor () -> Void)?

    init(
        viewModel: CodexStatusViewModel,
        workflowViewModel: WorkflowViewModel,
        codexHookSettings: CodexHookSettings,
        codexCLINotificationSettings: CodexCLINotificationSettings,
        activityMonitor: CodexActivityMonitor,
        syncSettings: WorkflowSyncSettings,
        globalHotKeySettings: GlobalHotKeySettings,
        menuBarQuotaSettings: MenuBarQuotaSettings,
        mainPanelSettings: MainPanelSettings,
        notificationSettings: NotificationSettings,
        resetCreditAutomationSettings: ResetCreditAutomationSettings,
        keepAliveController: KeepAliveController,
        appUpdater: AppUpdater
    ) {
        self.viewModel = viewModel
        self.workflowViewModel = workflowViewModel
        self.codexHookSettings = codexHookSettings
        self.codexCLINotificationSettings = codexCLINotificationSettings
        self.activityMonitor = activityMonitor
        self.syncSettings = syncSettings
        self.globalHotKeySettings = globalHotKeySettings
        self.menuBarQuotaSettings = menuBarQuotaSettings
        self.mainPanelSettings = mainPanelSettings
        self.notificationSettings = notificationSettings
        self.resetCreditAutomationSettings = resetCreditAutomationSettings
        self.keepAliveController = keepAliveController
        self.appUpdater = appUpdater
        super.init()
    }

    /// 无状态点和额度条时使用模板渲染, 由系统按菜单栏外观着色
    private static func makeStatusImage(
        _ symbolName: String,
        indicatorTint: NSColor?,
        indicatorVisibility: CGFloat = 1,
        progress: StatusIconProgress?,
        progressVisibility: CGFloat = 1
    ) -> NSImage? {
        guard let symbolImage = makeStatusSymbolImage(symbolName) else {
            return nil
        }

        let usesTemplateRendering = indicatorTint == nil && progress == nil
        let statusImage = NSImage(size: Metrics.progressStatusImageSize, flipped: false) { _ in
            Self.drawStatusSymbol(
                symbolImage,
                in: Metrics.progressStatusSymbolRect,
                tint: usesTemplateRendering ? .black : .labelColor,
                alpha: progress?.isStale == true ? Metrics.staleIconAlpha : 1
            )
            if let progress {
                Self.drawProgress(
                    progress,
                    visibility: progressVisibility
                )
            }
            if let indicatorTint {
                Self.drawStatusIndicator(
                    tint: indicatorTint,
                    visibility: indicatorVisibility
                )
            }
            return true
        }
        statusImage.isTemplate = usesTemplateRendering
        statusImage.alignmentRect = Self.statusImageAlignmentRect(for: symbolImage)
        return statusImage
    }

    private static func makeStatusSymbolImage(_ symbolName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 16,
            weight: .regular,
            scale: .medium
        )
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    private static func drawStatusSymbol(
        _ image: NSImage,
        in rect: NSRect,
        tint: NSColor,
        alpha: CGFloat
    ) {
        NSGraphicsContext.saveGraphicsState()
        tint.withAlphaComponent(alpha).setFill()
        rect.fill()
        image.draw(
            in: rect,
            from: .zero,
            operation: .destinationIn,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawStatusIndicator(
        tint: NSColor,
        visibility: CGFloat
    ) {
        let visibility = clampedVisibility(visibility)
        guard visibility > 0 else {
            return
        }

        tint.withAlphaComponent(visibility).setFill()
        NSBezierPath(ovalIn: Metrics.statusIndicatorRect).fill()
    }

    private static func statusImageAlignmentRect(for symbolImage: NSImage) -> NSRect {
        NSRect(
            x: 0,
            y: symbolImage.alignmentRect.minY,
            width: Metrics.progressStatusImageSize.width,
            height: symbolImage.alignmentRect.height
        )
    }

    private static func drawProgress(
        _ progress: StatusIconProgress,
        visibility: CGFloat
    ) {
        let visibility = clampedVisibility(visibility)
        guard visibility > 0 else {
            return
        }

        let trackRect = Metrics.progressTrackRect
        let cornerRadius = Metrics.progressTrackCornerRadius
        let progressAlpha = (progress.isStale ? Metrics.staleProgressAlpha : 1) * visibility
        NSColor.tertiaryLabelColor
            .withAlphaComponent(Metrics.progressTrackAlpha * progressAlpha)
            .setFill()
        NSBezierPath(
            roundedRect: trackRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        .fill()

        let fillHeight = trackRect.height * CGFloat(progress.percent) / 100
        guard fillHeight > 0 else {
            return
        }

        let fillRect = NSRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: trackRect.width,
            height: fillHeight
        )
        QuotaPalette.nsColor(for: progress.percent)
            .withAlphaComponent(progressAlpha)
            .setFill()
        NSBezierPath(
            roundedRect: fillRect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        .fill()
    }

    private static func clampedVisibility(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    /// 色彩空间转换失败时 blended 返回 nil, 统一退到较近的一端
    private static func blendedColor(
        _ source: NSColor,
        _ destination: NSColor,
        progress: CGFloat
    ) -> NSColor {
        let progress = clampedVisibility(progress)
        return source.blended(withFraction: progress, of: destination)
            ?? (progress < 0.5 ? source : destination)
    }

    /// 图标动画中一条 0↔1 的过渡: 起止由布尔状态决定, 按动画进度取中间值
    private static func transitionValue(
        from source: Bool,
        to destination: Bool,
        progress: CGFloat
    ) -> CGFloat {
        let start: CGFloat = source ? 1 : 0
        let end: CGFloat = destination ? 1 : 0
        return start + (end - start) * progress
    }

    private static func easedVisibility(_ value: CGFloat) -> CGFloat {
        let value = clampedVisibility(value)
        return value * value * (3 - 2 * value)
    }

    private struct StatusIconState: Equatable {
        let usesErrorImage: Bool
        let progress: StatusIconProgress?
        let activity: CodexActivitySnapshot

        var symbolName: String {
            usesErrorImage ? Metrics.errorStatusSymbolName : Metrics.normalStatusSymbolName
        }

        var indicator: ActivityIndicator? {
            switch activity.primaryActivity {
            case .waiting:
                .waiting
            case .running:
                .running
            case .completed(_, highlighted: true):
                .completed
            case .completed, .terminated, .idle:
                nil
            }
        }

        /// 只包含影响图像像素的字段; tooltip 文本变化不应触发重绘
        var renderState: StatusIconRenderState {
            StatusIconRenderState(symbolName: symbolName, indicator: indicator, progress: progress)
        }

        var hasLiveDuration: Bool {
            activity.hasActiveTasks
        }

        func toolTip(at now: Date) -> String? {
            var lines: [String] = []
            if usesErrorImage {
                lines.append(String(localized: "Codex 账号异常"))
            }

            if let activityText = activityToolTip(at: now) {
                lines.append(activityText)
            }
            if activity.activeCount > 1 {
                lines.append(
                    String(localized: "等待 \(activity.waitingCount) • 运行 \(activity.runningCount)")
                )
            }
            if let progress {
                lines.append(progress.toolTip)
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }

        private func activityToolTip(at now: Date) -> String? {
            switch activity.primaryActivity {
            case let .waiting(task):
                var text = String(localized: "Codex 等待批准")
                if let projectName = task.projectName {
                    text += " • \(projectName)"
                }
                if let toolName = task.toolName {
                    text += " • \(toolName)"
                }
                text += " • \(CodexActivityDisplayFormat.waitingDurationFragment(since: task.stateChangedAt, now: now))"
                return text
            case let .running(task):
                var text = String(localized: "Codex 正在运行")
                if let projectName = task.projectName {
                    text += " • \(projectName)"
                }
                if task.showsPreciseDuration, let startedAt = task.startedAt {
                    text += " • \(CodexActivityDisplayFormat.runningDurationFragment(since: startedAt, now: now))"
                }
                return text
            case .completed(let completion, highlighted: true):
                var text = String(localized: "Codex 刚刚完成")
                if let projectName = completion.projectName {
                    text += " • \(projectName)"
                }
                if let duration = completion.duration {
                    text += " • \(CodexActivityDisplayFormat.elapsedDurationFragment(for: duration))"
                }
                return text
            case .completed, .terminated, .idle:
                return nil
            }
        }
    }

    /// 状态图标中影响像素的渲染子状态, 用于跳过 tooltip-only 变化引发的重绘
    private struct StatusIconRenderState: Equatable {
        let symbolName: String
        let indicator: ActivityIndicator?
        let progress: StatusIconProgress?
    }

    private enum ActivityIndicator: Equatable {
        case waiting
        case running
        case completed

        var color: NSColor {
            switch self {
            case .waiting: .systemOrange
            case .running: .systemBlue
            case .completed: .systemGreen
            }
        }
    }

    private struct StatusIconProgress: Equatable {
        let label: String
        let percent: Int
        let isStale: Bool

        var toolTip: String {
            let percentText = CodexPercentageFormat.string(from: percent)
            return String(localized: "\(label) 剩余 \(percentText)")
        }

        init?(snapshot: CodexQuotaSnapshot?, selection: MenuBarQuotaSelection) {
            guard let targetKind = selection.windowKind,
                  let snapshot,
                  let window = snapshot.codexLimit?.window(ofKind: targetKind),
                  window.hasData else {
                return nil
            }

            label = window.label
            percent = window.remainingPercent
            isStale = snapshot.isRateLimitsStale
        }
    }

    // MARK: - 装配与对外入口

    func install() {
        configureStatusButton()
        configurePopover()
        observeGlobalHotKeySettings()
        // 订阅时 CombineLatest 会同步发出当前值, 初始图标由订阅路径统一渲染
        observeViewModel()
        observeWorkflowSyncState()
        codexHookSettings.refresh()
        viewModel.startAutoRefresh()
    }

    func uninstall() {
        closeMenuSurface(animated: false)
        auxiliaryWindowFocusRestoreTask?.cancel()
        statusIconAnimationTask?.cancel()
        statusToolTipTask?.cancel()
        workflowSyncScheduler.cancel()
        setAuxiliaryWindowKeyFocus(true)
        globalHotKeyController.uninstall()
        cancellables.removeAll()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func openSettingsFromCommand() {
        closeMenuSurface(animated: false)
        openSettings()
    }

    /// 通知点击回调: 面板未展示时按快捷键路径打开(含 fallback 面板兜底)
    func openMenuSurfaceFromNotification() {
        guard menuSurfaceWillOpenOnToggle else {
            return
        }

        toggleMenuSurfaceFromHotKey()
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else {
            return
        }

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configurePopover() {
        let hostingController = makeMenuHostingController(usesPreferredContentSize: true)

        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = hostingController
    }

    private func makeMenuHostingController(usesPreferredContentSize: Bool) -> NSHostingController<AnyView> {
        let rootView = CodexStatusMenuView(
            viewModel: viewModel,
            workflowViewModel: workflowViewModel,
            codexHookSettings: codexHookSettings,
            mainPanelSettings: mainPanelSettings,
            activityMonitor: activityMonitor,
            syncSettings: syncSettings,
            keepAliveController: keepAliveController,
            menuSurfaceVisibility: menuSurfaceVisibility,
            activityCenterPresentationState: activityCenterPresentationState,
            onUsageHeatmapHoverChange: { [weak self] context in
                self?.updateHeatmapDetailPanel(context)
            },
            onResetCreditsTap: { [weak self] context in
                self?.toggleResetCreditsPanel(context)
            },
            onActivityCenterTap: { [weak self] context in
                self?.toggleActivityCenterPanel(context)
            }
        )
        .environmentObject(appUpdater)
        .frame(width: CodexStatusMenuView.menuWidth)

        let hostingController = NSHostingController(rootView: AnyView(rootView))
        if usesPreferredContentSize {
            hostingController.sizingOptions = [.preferredContentSize]
        }
        return hostingController
    }

    // MARK: - 订阅与全局快捷键

    private func observeViewModel() {
        let hasQuotaSnapshot = viewModel.$snapshot
            .map { $0 != nil }
            .removeDuplicates()

        let hasTaskCenterContent = activityMonitor.$snapshot
            .map(\.hasTaskCenterContent)
            .removeDuplicates()

        let isTaskCenterVisible = Publishers.CombineLatest(
            codexHookSettings.$isEnabled,
            mainPanelSettings.$showsTaskCenter
        )
        .map { isHookEnabled, showsTaskCenter in
            isHookEnabled && showsTaskCenter
        }
        .removeDuplicates()

        Publishers.CombineLatest4(
            menuSurfaceVisibility.$isVisible,
            hasQuotaSnapshot,
            hasTaskCenterContent,
            isTaskCenterVisible
        )
        .map { isMenuVisible, hasQuotaSnapshot, hasActivity, isTaskCenterVisible in
            isMenuVisible && hasQuotaSnapshot && hasActivity && isTaskCenterVisible
        }
        .removeDuplicates()
        .sink { [weak self] isActive in
            self?.activityCenterPresentationState.setTimelineActive(isActive)
        }
        .store(in: &cancellables)

        Publishers.CombineLatest4(
            viewModel.$loadState,
            viewModel.$snapshot,
            menuBarQuotaSettings.$selection,
            activityMonitor.$snapshot
        )
        .map { loadState, snapshot, selection, activity in
            StatusIconState(
                usesErrorImage: loadState.isError || snapshot?.hasTrustedData == false,
                progress: StatusIconProgress(snapshot: snapshot, selection: selection),
                activity: snapshot == nil ? .empty : activity
            )
        }
        .removeDuplicates()
        .sink { [weak self] state in
            self?.updateStatusImage(state)
        }
        .store(in: &cancellables)

        viewModel.$autoRefreshCountdownStartedAt
            .compactMap(\.self)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                refreshWorkflowIfHookEnabled(performMaintenance: true)
            }
            .store(in: &cancellables)

        hasQuotaSnapshot
            .sink { [weak self] isAvailable in
                guard let self, !isAvailable else {
                    return
                }
                activityCenterPanelController.hide(immediate: true)
            }
            .store(in: &cancellables)

        mainPanelSettings.$showsTaskCenter
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.activityCenterPanelController.hide(immediate: true)
            }
            .store(in: &cancellables)
    }

    private func observeWorkflowSyncState() {
        codexHookSettings.$isEnabled
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                guard let self else {
                    return
                }

                if isEnabled {
                    // 回调跑在 willSet, codexHookSettings.isEnabled 此刻还是旧值, 只能用参数
                    workflowSyncScheduler.requestSync(
                        trigger: .hookEnabled,
                        activation: syncSettings.activation(isHookEnabled: true)
                    )
                } else {
                    workflowSyncScheduler.clearPendingMaintenance()
                    activityCenterPanelController.hide(immediate: true)
                }
            }
            .store(in: &cancellables)

        syncSettings.$syncAvailability
            .removeDuplicates()
            .sink { [weak self] availability in
                self?.handleSyncChanged(isSyncAvailable: availability.isAvailable)
            }
            .store(in: &cancellables)
    }

    private func observeGlobalHotKeySettings() {
        globalHotKeySettings.$shortcut
            .removeDuplicates()
            .sink { [weak self] shortcut in
                self?.applyGlobalHotKey(shortcut)
            }
            .store(in: &cancellables)
    }

    private func applyGlobalHotKey(_ shortcut: GlobalHotKeyShortcut?) {
        guard shortcut != registeredHotKeyShortcut else {
            return
        }

        guard let shortcut else {
            globalHotKeyController.uninstall()
            registeredHotKeyShortcut = nil
            return
        }

        if globalHotKeyController.install(shortcut: shortcut) {
            registeredHotKeyShortcut = shortcut
            globalHotKeySettings.clearError()
            return
        }

        let message = hotKeyConflictMessage(for: shortcut)
        guard let previousShortcut = registeredHotKeyShortcut else {
            // 启动阶段冲突时还没有成功注册过任何快捷键
            // 此时 restoreShortcut(nil) 会清空用户保存的配置, 只能提示冲突
            globalHotKeySettings.setRegistrationError(message)
            return
        }

        globalHotKeySettings.restoreShortcut(previousShortcut, message: message)
    }

    private func hotKeyConflictMessage(for shortcut: GlobalHotKeyShortcut) -> String {
        if shortcut == .default {
            return String(localized: "默认快捷键 \(shortcut.label) 已被占用")
        }

        return String(localized: "快捷键已被占用")
    }

    // MARK: - 菜单栏图标

    private func updateStatusImage(_ state: StatusIconState) {
        statusItem.button?.toolTip = state.toolTip(at: Date())

        guard state != statusIconState else {
            return
        }

        let previousState = statusIconState
        statusIconState = state
        if previousState?.hasLiveDuration != state.hasLiveDuration {
            configureStatusToolTipRefresh(for: state)
        }

        guard let previousState else {
            statusIconAnimationTask?.cancel()
            renderStatusImage(state)
            return
        }
        // tooltip-only 变化不重绘, 也不打断进行中的图标动画
        guard previousState.renderState != state.renderState else {
            return
        }
        statusIconAnimationTask?.cancel()

        let progressVisibilityChanged = (previousState.progress == nil) != (state.progress == nil)
        if previousState.indicator != state.indicator || progressVisibilityChanged {
            animateStatusImage(from: previousState, to: state)
            return
        }

        renderStatusImage(state)
    }

    private func renderStatusImage(_ state: StatusIconState) {
        statusItem.button?.image = Self.makeStatusImage(
            state.symbolName,
            indicatorTint: state.indicator?.color,
            progress: state.progress
        )
    }

    private func animateStatusImage(from previousState: StatusIconState, to finalState: StatusIconState) {
        let renderedProgress = finalState.progress ?? previousState.progress

        statusIconAnimationTask = Task { @MainActor [weak self] in
            for frame in 0 ... Metrics.statusIconAnimationFrameCount {
                guard let self,
                      !Task.isCancelled,
                      statusIconState?.renderState == finalState.renderState else {
                    return
                }

                let rawProgress = CGFloat(frame) / CGFloat(Metrics.statusIconAnimationFrameCount)
                let easedProgress = Self.easedVisibility(rawProgress)
                statusItem.button?.image = Self.makeStatusImage(
                    finalState.symbolName,
                    indicatorTint: Self.interpolatedIndicatorTint(
                        from: previousState.indicator,
                        to: finalState.indicator,
                        progress: easedProgress
                    ),
                    indicatorVisibility: Self.transitionValue(
                        from: previousState.indicator != nil,
                        to: finalState.indicator != nil,
                        progress: easedProgress
                    ),
                    progress: renderedProgress,
                    progressVisibility: Self.transitionValue(
                        from: previousState.progress != nil,
                        to: finalState.progress != nil,
                        progress: easedProgress
                    )
                )

                if frame < Metrics.statusIconAnimationFrameCount {
                    try? await Task.sleep(
                        nanoseconds: Metrics.statusIconAnimationFrameDelayNanoseconds
                    )
                }
            }

            guard let self,
                  !Task.isCancelled,
                  statusIconState?.renderState == finalState.renderState else {
                return
            }

            renderStatusImage(finalState)
            statusIconAnimationTask = nil
        }
    }

    private func configureStatusToolTipRefresh(for state: StatusIconState) {
        statusToolTipTask?.cancel()
        statusToolTipTask = nil
        guard state.hasLiveDuration else {
            return
        }

        statusToolTipTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self,
                      !Task.isCancelled,
                      let state = statusIconState,
                      state.hasLiveDuration else {
                    return
                }
                statusItem.button?.toolTip = state.toolTip(at: Date())
            }
        }
    }

    private static func interpolatedIndicatorTint(
        from source: ActivityIndicator?,
        to destination: ActivityIndicator?,
        progress: CGFloat
    ) -> NSColor? {
        switch (source, destination) {
        case let (source?, destination?):
            // 只在两端都有指示点时混色; 单端的显隐交给 indicatorVisibility
            blendedColor(source.color, destination.color, progress: progress)
        case let (indicator?, nil), let (nil, indicator?):
            indicator.color
        case (nil, nil):
            nil
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApplication.shared.currentEvent else {
            toggleMenuSurface(relativeTo: sender)
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(relativeTo: sender)
        } else {
            toggleMenuSurface(relativeTo: sender)
        }
    }

    // MARK: - 菜单面板开合

    private func toggleMenuSurface(relativeTo button: NSStatusBarButton) {
        toggleMenuSurface {
            openPopover(relativeTo: button)
        }
    }

    private func toggleMenuSurface(open: () -> Void) {
        switch menuSurfaceState {
        case .hidden:
            open()
        case .opening, .shown:
            closeMenuSurface()
        case .closing:
            completeMenuSurfaceClose()
            open()
        }
    }

    /// toggle 将走"打开"分支的状态谓词, 与 toggleMenuSurface 的分支口径一致
    private var menuSurfaceWillOpenOnToggle: Bool {
        menuSurfaceState == .hidden || menuSurfaceState == .closing
    }

    private func toggleMenuSurfaceFromHotKey() {
        let targetScreen = NSScreen.containingMouse() ?? NSScreen.main
        let opensMenuSurface = menuSurfaceWillOpenOnToggle
        if opensMenuSurface {
            suspendAuxiliaryWindowKeyFocus()
        }

        toggleMenuSurface {
            openMenuSurfaceFromHotKey(on: targetScreen)
        }

        if opensMenuSurface {
            scheduleAuxiliaryWindowKeyFocusRestore()
        }
    }

    private func openMenuSurfaceFromHotKey(on targetScreen: NSScreen?) {
        guard let button = statusItem.button,
              isTrustedStatusItemAnchor(button, on: targetScreen) else {
            openFallbackPanel(on: targetScreen)
            return
        }

        openPopover(relativeTo: button)
    }

    private func isTrustedStatusItemAnchor(
        _ button: NSStatusBarButton,
        on targetScreen: NSScreen?
    ) -> Bool {
        // 全局快捷键打开时必须确认 status item 锚点真实可用
        // 否则使用无箭头 fallback 面板
        guard let window = button.window,
              let screen = window.screen,
              !button.isHidden,
              !button.bounds.isEmpty else {
            return false
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = window.convertToScreen(buttonRectInWindow)
        guard buttonScreenRect.isValidScreenRect,
              buttonScreenRect.width >= Metrics.minimumTrustedAnchorLength,
              buttonScreenRect.height >= Metrics.minimumTrustedAnchorLength else {
            return false
        }

        let trustedScreenFrame = (targetScreen ?? screen).frame.insetBy(
            dx: -Metrics.anchorScreenTolerance,
            dy: -Metrics.anchorScreenTolerance
        )
        return trustedScreenFrame.intersects(buttonScreenRect)
    }

    private func cancelMenuSurfaceTasks() {
        delayedStatusRefreshTask?.cancel()
        delayedStatusRefreshTask = nil
        menuSurfaceFadeCoordinator.cancel()
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        cancelMenuSurfaceTasks()

        menuSurfaceState = .opening
        activeMenuSurface = .popover

        menuSurfaceFadeCoordinator.prepareForFadeIn()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        completeMenuSurfaceOpen()
    }

    private func openFallbackPanel(on screen: NSScreen?) {
        cancelMenuSurfaceTasks()

        fallbackPanelController.prepareForDisplay(on: screen)
        menuSurfaceState = .opening
        activeMenuSurface = .fallbackPanel

        menuSurfaceFadeCoordinator.prepareForFadeIn()
        fallbackPanelController.show()
        completeMenuSurfaceOpen()
    }

    private func completeMenuSurfaceOpen() {
        menuSurfaceVisibility.isVisible = true
        refreshWorkflowIfHookEnabled(performMaintenance: false)
        menuSurfaceDismissMonitor.install(
            onDismiss: { [weak self] in
                self?.closeMenuSurface()
            },
            onLogShortcut: { [weak self] in
                self?.openLogFromShortcut()
            }
        )

        menuSurfaceFadeCoordinator.fadeIn(duration: Metrics.fadeInDuration) { [weak self] in
            self?.menuSurfaceState = .shown
        }

        scheduleDelayedStatusRefresh()
    }

    // MARK: - 右键菜单

    private func showContextMenu(relativeTo button: NSStatusBarButton) {
        closeMenuSurface(animated: false)
        presentStatusItemMenu(makeContextMenu(), relativeTo: button)
    }

    private func presentStatusItemMenu(_ menu: NSMenu, relativeTo button: NSStatusBarButton) {
        pendingStatusItemMenuAction = nil
        activeStatusItemMenu = menu
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
        finishStatusItemMenuPresentation(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        finishStatusItemMenuPresentation(menu)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(
            title: "设置",
            action: #selector(openSettings),
            keyEquivalent: ",",
            symbolName: "gearshape"
        ))

        menu.addItem(menuItem(
            title: "日志",
            action: #selector(openLog),
            keyEquivalent: "l",
            symbolName: "doc.text.magnifyingglass"
        ))

        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "退出",
            action: #selector(quit),
            keyEquivalent: "q",
            symbolName: "power"
        ))

        return menu
    }

    private func menuItem(
        title: LocalizedStringResource,
        action: Selector,
        keyEquivalent: String,
        symbolName: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: String(localized: title),
            action: action,
            keyEquivalent: keyEquivalent
        )
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        item.target = self
        return item
    }

    @objc private func openSettings() {
        openAuxiliaryWindow { [weak self] in
            self?.settingsWindowController.open()
        }
    }

    @objc private func openLog() {
        openAuxiliaryWindow { [weak self] in
            self?.logWindowController.open()
        }
    }

    // MARK: - 辅助窗口与焦点

    private func openLogFromShortcut() {
        closeMenuSurface(animated: false)
        openLog()
    }

    private func openAuxiliaryWindow(_ open: @escaping @MainActor () -> Void) {
        guard activeStatusItemMenu == nil else {
            pendingStatusItemMenuAction = { [weak self] in
                self?.openAuxiliaryWindow(open)
            }
            return
        }

        auxiliaryWindowFocusRestoreTask?.cancel()
        auxiliaryWindowFocusRestoreTask = nil
        setAuxiliaryWindowKeyFocus(true)
        open()
    }

    private func runPendingStatusItemMenuAction() {
        guard let pendingStatusItemMenuAction else {
            return
        }

        self.pendingStatusItemMenuAction = nil
        DispatchQueue.main.async {
            pendingStatusItemMenuAction()
        }
    }

    private func finishStatusItemMenuPresentation(_ menu: NSMenu) {
        guard activeStatusItemMenu === menu else {
            return
        }

        menu.delegate = nil
        activeStatusItemMenu = nil

        if statusItem.menu === menu {
            statusItem.menu = nil
        }

        runPendingStatusItemMenuAction()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 关闭流程

    private func closeMenuSurface(animated: Bool = true) {
        if menuSurfaceState == .closing, animated {
            return
        }

        cancelMenuSurfaceTasks()
        hideSideDetailPanels()
        menuSurfaceDismissMonitor.remove()
        menuSurfaceVisibility.isVisible = false

        guard isActiveMenuSurfaceVisible else {
            menuSurfaceFadeCoordinator.resetAlpha()
            menuSurfaceState = .hidden
            activeMenuSurface = .none
            return
        }

        guard animated else {
            // 关闭菜单面板时短暂禁止辅助窗口抢回 key
            // 避免设置/日志窗口闪前
            suspendAuxiliaryWindowKeyFocus()
            completeMenuSurfaceClose(hidesDetailPanel: false)
            return
        }

        suspendAuxiliaryWindowKeyFocus()
        menuSurfaceState = .closing
        let didStartFadeOut = menuSurfaceFadeCoordinator.fadeOut(duration: Metrics.fadeOutDuration) { [weak self] in
            self?.menuSurfaceState = .hidden
            self?.scheduleAuxiliaryWindowKeyFocusRestore()
        }

        if !didStartFadeOut {
            completeMenuSurfaceClose()
        }
    }

    private func completeMenuSurfaceClose(hidesDetailPanel: Bool = true) {
        cancelMenuSurfaceTasks()
        if hidesDetailPanel {
            hideSideDetailPanels()
        }
        menuSurfaceDismissMonitor.remove()

        closeActiveMenuSurface()

        menuSurfaceVisibility.isVisible = false
        menuSurfaceFadeCoordinator.resetAlpha()
        menuSurfaceState = .hidden
        activeMenuSurface = .none
        scheduleAuxiliaryWindowKeyFocusRestore()
    }

    /// 侧边面板互斥名册: 新增面板只需要加入这里, 显隐与点击区域判定即可覆盖
    private var sideDetailPanels: [MenuSideDetailPanel] {
        [heatmapDetailPanelController, resetCreditsPanelController, activityCenterPanelController]
    }

    private func hideSideDetailPanels(
        except kept: MenuSideDetailPanel? = nil,
        immediate: Bool = true
    ) {
        for panel in sideDetailPanels where panel !== kept {
            panel.hide(immediate: immediate)
        }
    }

    private func isPointInDetailPanel(_ screenPoint: NSPoint) -> Bool {
        sideDetailPanels.contains { $0.containsScreenPoint(screenPoint) }
    }

    private func suspendAuxiliaryWindowKeyFocus() {
        auxiliaryWindowFocusRestoreTask?.cancel()
        auxiliaryWindowFocusRestoreTask = nil
        setAuxiliaryWindowKeyFocus(false)
    }

    private func scheduleAuxiliaryWindowKeyFocusRestore() {
        auxiliaryWindowFocusRestoreTask?.cancel()
        auxiliaryWindowFocusRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Metrics.auxiliaryWindowKeyFocusRestoreDelayMilliseconds))
            guard let self, !Task.isCancelled else {
                return
            }

            setAuxiliaryWindowKeyFocus(true)
            auxiliaryWindowFocusRestoreTask = nil
        }
    }

    private func setAuxiliaryWindowKeyFocus(_ allowsKeyFocus: Bool) {
        settingsWindowController.setAllowsKeyFocus(allowsKeyFocus)
        logWindowController.setAllowsKeyFocus(allowsKeyFocus)
    }

    // MARK: - 刷新与同步

    private func scheduleDelayedStatusRefresh() {
        delayedStatusRefreshTask?.cancel()
        delayedStatusRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self, !Task.isCancelled, isActiveMenuSurfaceVisible else {
                return
            }

            viewModel.refreshIfNeeded(trigger: .panelOpen)
        }
    }

    private func refreshWorkflowIfHookEnabled(performMaintenance: Bool) {
        // Hook 开关可能被外部 Codex 配置改动, 每次需要统计前都先读 hooks.json
        codexHookSettings.refresh()
        guard codexHookSettings.isEnabled else {
            workflowSyncScheduler.clearPendingMaintenance()
            return
        }

        if performMaintenance {
            // 统计维护挂在额度刷新完成事件上, 触发来源继承那一次刷新
            workflowSyncScheduler.requestMaintenance(
                allowsSync: true,
                trigger: viewModel.lastRefreshTrigger
            )
        } else {
            workflowViewModel.refreshIfNeeded()
        }
    }

    /// isSyncAvailable 由调用方传入
    /// 从 $syncAvailability 的订阅进来时 syncSettings.isSyncAvailable 还是旧值, 只有回调参数是新的
    /// 不在这里判断该不该跳过: requestSync 的 guard 已经统一处理并记下 reason=
    private func handleSyncChanged(isSyncAvailable: Bool) {
        workflowSyncScheduler.requestSync(
            trigger: .settings,
            activation: syncSettings.activation(
                isHookEnabled: codexHookSettings.isEnabled,
                isSyncAvailable: isSyncAvailable
            )
        )
    }

    private var workflowSyncActivation: WorkflowSyncActivation {
        syncSettings.activation(isHookEnabled: codexHookSettings.isEnabled)
    }

    // MARK: - 侧边面板

    private func updateHeatmapDetailPanel(_ context: UsageHeatmapHoverContext?) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            heatmapDetailPanelController.hide(immediate: true)
            return
        }

        if context != nil {
            hideSideDetailPanels(except: heatmapDetailPanelController, immediate: false)
        }

        heatmapDetailPanelController.update(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: menuSurfaceContentView
        )
    }

    private func toggleResetCreditsPanel(_ context: ResetCreditsPanelContext) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            resetCreditsPanelController.hide(immediate: true)
            return
        }

        hideSideDetailPanels(except: resetCreditsPanelController)
        resetCreditsPanelController.toggle(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: menuSurfaceContentView
        )
    }

    private func toggleActivityCenterPanel(_ context: CodexActivityCenterPanelContext) {
        guard isActiveMenuSurfaceVisible,
              let menuSurfaceContentView = activeMenuSurfaceContentView,
              let menuSurfaceWindow = activeMenuSurfaceWindow else {
            activityCenterPanelController.hide(immediate: true)
            return
        }

        hideSideDetailPanels(except: activityCenterPanelController)
        activityCenterPanelController.toggle(
            context: context,
            relativeTo: menuSurfaceWindow,
            contentView: menuSurfaceContentView
        )
    }

    private var isActiveMenuSurfaceVisible: Bool {
        switch activeMenuSurface {
        case .none:
            false
        case .popover:
            popover.isShown
        case .fallbackPanel:
            fallbackPanelController.isVisible
        }
    }

    private var activeMenuSurfaceContentView: NSView? {
        switch activeMenuSurface {
        case .none:
            nil
        case .popover:
            popover.contentViewController?.view
        case .fallbackPanel:
            fallbackPanelController.contentView
        }
    }

    private var activeMenuSurfaceWindow: NSWindow? {
        switch activeMenuSurface {
        case .none:
            nil
        case .popover:
            popover.contentViewController?.view.window
        case .fallbackPanel:
            fallbackPanelController.window
        }
    }

    private func closeActiveMenuSurface() {
        if popover.isShown {
            popover.performClose(nil)
        }

        fallbackPanelController.orderOut()

        activeMenuSurface = .none
    }

    private enum Metrics {
        static let normalStatusSymbolName = "person.fill.checkmark"
        static let errorStatusSymbolName = "person.fill.xmark"
        static let fadeInDuration: TimeInterval = 0.24
        static let fadeOutDuration: TimeInterval = 0.18
        static let auxiliaryWindowKeyFocusRestoreDelayMilliseconds: UInt64 = 120
        static let minimumTrustedAnchorLength: CGFloat = 1
        static let anchorScreenTolerance: CGFloat = 1
        static let progressStatusSymbolSize = NSSize(width: 24, height: 17)
        static let progressStatusExtraWidth: CGFloat = 3
        static let progressStatusContentOffsetX: CGFloat = 1
        static let progressStatusImageSize = NSSize(
            width: progressStatusSymbolSize.width + progressStatusExtraWidth,
            height: progressStatusSymbolSize.height
        )
        static let progressStatusSymbolRect = NSRect(
            x: progressStatusExtraWidth + progressStatusContentOffsetX,
            y: 0,
            width: progressStatusSymbolSize.width,
            height: progressStatusSymbolSize.height
        )
        static let progressTrackRect = NSRect(
            x: 0.5 + progressStatusContentOffsetX,
            y: 1,
            width: 2,
            height: 15
        )
        static let progressTrackCornerRadius: CGFloat = 1
        static let progressTrackAlpha: CGFloat = 0.34
        static let statusIndicatorRect = NSRect(x: 21.5, y: 1, width: 5, height: 5)
        static let staleIconAlpha: CGFloat = 0.75
        static let staleProgressAlpha: CGFloat = 0.55
        static let statusIconAnimationDuration: TimeInterval = 0.18
        static let statusIconAnimationFrameCount = 10
        static let statusIconAnimationFrameDelayNanoseconds = UInt64(
            statusIconAnimationDuration
                / Double(statusIconAnimationFrameCount)
                * 1000000000
        )
    }

    private enum MenuSurfaceState {
        case hidden
        case opening
        case shown
        case closing
    }

    private enum ActiveMenuSurface {
        case none
        case popover
        case fallbackPanel
    }
}

/// 菜单侧边面板的互斥名册接口; 面板间互斥和点击区域判定统一走名册遍历
private protocol MenuSideDetailPanel: AnyObject {
    func hide(immediate: Bool)
    func containsScreenPoint(_ screenPoint: NSPoint) -> Bool
}

extension HeatmapDetailPanelController: MenuSideDetailPanel {}
extension ResetCreditsPanelController: MenuSideDetailPanel {}
extension ActivityCenterPanelController: MenuSideDetailPanel {}
