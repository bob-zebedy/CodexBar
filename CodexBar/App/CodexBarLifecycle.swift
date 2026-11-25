import AppKit
import Combine
import os

/// 创建并持有应用级服务和 ViewModel
@MainActor
final class CodexBarLifecycle: NSObject, NSApplicationDelegate {
    private lazy var codexStatusService = CodexStatusService(logStorage: .shared, startup: appServerStartup)
    private let desktopLaunchSettings = CodexDesktopLaunchSettings()
    private lazy var appServerStartup = AppServerStartup(onFirstReady: desktopLaunchSettings.applySavedPreference)
    lazy var viewModel = CodexStatusViewModel(service: codexStatusService, serviceStatusMonitor: serviceStatusMonitor)
    let historyViewModel = HistoryViewModel()
    lazy var tuiNotificationSettings = TUINotificationSettings(
        codexStatusService: codexStatusService,
        connectionAvailability: viewModel.$codexConnectionInfo.map { $0 != nil }.eraseToAnyPublisher()
    )
    let protectionSettings = ProtectionSettings()
    lazy var activityMonitor = ActivityMonitor(
        protectionSettings: protectionSettings, logStorage: .shared
    )
    lazy var keepAliveController = KeepAliveController(
        activityMonitor: activityMonitor
    )
    let syncSettings = SyncSettings()
    let globalHotKeySettings = GlobalHotKeySettings()
    let menuBarIndicatorSettings = MenuBarIndicatorSettings()
    let appearanceSettings = AppearanceSettings()
    let mainPanelSettings = MainPanelSettings()
    let serviceStatusMonitor = CodexServiceStatusMonitor()
    let taskGlowSettings = TaskGlowSettings()
    let notificationSettings = NotificationSettings()
    let autoResetSettings = AutoResetSettings()
    let appUpdater = AppUpdater()

    private var statusItemController: StatusItemController?
    private var appearanceObserver: AnyCancellable?
    private var appearanceTransition: AppearanceTransition?
    private var taskGlowController: TaskGlowController?
    private var notificationService: NotificationService?
    private var autoResetController: AutoResetController?
    private var startupTask: Task<Void, Never>?
    private var terminationPreparationTask: Task<Void, Never>?
    private var hasPreparedForTermination = false

    // MARK: - App 生命周期

    func applicationDidFinishLaunching(_: Notification) {
        AppProcessDiagnostics.install()
        Task { await BridgeHost.shared.restoreAtLaunch() }
        configureAppearance()
        let controller = StatusItemController(
            viewModel: viewModel,
            historyViewModel: historyViewModel,
            tuiNotificationSettings: tuiNotificationSettings,
            activityMonitor: activityMonitor,
            syncSettings: syncSettings,
            globalHotKeySettings: globalHotKeySettings,
            desktopLaunchSettings: desktopLaunchSettings,
            menuBarIndicatorSettings: menuBarIndicatorSettings,
            appearanceSettings: appearanceSettings,
            mainPanelSettings: mainPanelSettings,
            serviceStatusMonitor: serviceStatusMonitor,
            taskGlowSettings: taskGlowSettings,
            notificationSettings: notificationSettings,
            autoResetSettings: autoResetSettings,
            keepAliveController: keepAliveController,
            appUpdater: appUpdater
        )
        controller.install()
        statusItemController = controller

        let notificationService = NotificationService(
            settings: notificationSettings,
            statusViewModel: viewModel,
            activityMonitor: activityMonitor
        ) { [weak controller] in
            controller?.openMenuSurfaceFromNotification()
        }
        notificationService.start()
        self.notificationService = notificationService

        let autoResetController = AutoResetController(
            settings: autoResetSettings,
            statusViewModel: viewModel,
            service: codexStatusService,
            notificationService: notificationService,
            keepAliveController: keepAliveController
        )
        autoResetController.start()
        self.autoResetController = autoResetController
        // 低电量保护会解除防睡眠, 通知说明恢复系统睡眠策略的原因
        keepAliveController.onLowBatteryTriggered = { [weak notificationService] percent in
            await notificationService?.notifyLowBatteryProtection(percent: percent) ?? false
        }
        keepAliveController.onKeepAliveLimitTriggered = { [weak notificationService] duration in
            await notificationService?.notifyKeepAliveLimitReached(durationText: duration.title) ?? false
        }
        activityMonitor.onAccountChange = { [weak viewModel] change in
            viewModel?.receiveAccountChange(change)
        }
        activityMonitor.onProtectionTriggered = { [weak notificationService] notice in
            await notificationService?.notifyProtection(notice) ?? false
        }
        activityMonitor.onProtectionInvalidated = { [weak notificationService] taskID, attemptID in
            notificationService?.invalidateProtectionNotification(taskID: taskID, attemptID: attemptID)
        }
        let taskGlowController = TaskGlowController(
            settings: taskGlowSettings,
            activityMonitor: activityMonitor
        )
        taskGlowController.start()
        self.taskGlowController = taskGlowController
        keepAliveController.start()
        let version = Bundle.main.shortVersionString ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        AppLog.app.notice("App 已启动: version=\(version, privacy: .public) build=\(build, privacy: .public)")
        startupTask = Task { [weak self, startup = appServerStartup] in
            do {
                try await startup.ensureStarted()
            } catch is CancellationError {
                return
            } catch {
                AppLog.app.error("Codex 后台服务准备失败")
                AppServerLogStore.shared.recordFailure(method: "daemon/start", message: error.localizedDescription)
            }
            guard let self, !Task.isCancelled else { return }
            startupTask = nil
            viewModel.startAutoRefresh()
            activityMonitor.start()
        }
    }

    private func configureAppearance() {
        NSApplication.shared.appearance = appearanceSettings.theme.appearance
        appearanceTransition = AppearanceTransition { [weak self] in
            self?.mainPanelSettings.areAnimationsEnabled ?? false
        }
        appearanceObserver = appearanceSettings.$theme
            .dropFirst()
            // @Published 在属性赋值前通知, 截图必须等本轮赋值完成后再刷新 SwiftUI
            .receive(on: RunLoop.main)
            .sink { [weak self] theme in
                guard let self,
                      theme == appearanceSettings.theme else { return }
                // 连续选择只应用最终主题及其来源, 即使外观未变也要清除本次保存的过渡起点
                let origin = appearanceSettings.takeTransitionOrigin()
                guard NSApplication.shared.appearance?.name != theme.appearance?.name else { return }
                appearanceTransition?.performChange(from: origin) {
                    NSApplication.shared.appearance = theme.appearance
                    statusItemController?.applyAppearance(theme.appearance)
                }
            }
    }

    func applicationWillTerminate(_: Notification) {
        AppLog.app.notice("App 即将退出: reason=userQuit")
        appearanceTransition?.stop()
        startupTask?.cancel()
        startupTask = nil
        terminationPreparationTask?.cancel()
        terminationPreparationTask = nil
        AppProcessDiagnostics.recordCleanExit()
        statusItemController?.uninstall()
        autoResetController?.stop()
        keepAliveController.stop()
        taskGlowController?.stop()
        activityMonitor.stop()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if hasPreparedForTermination {
            return .terminateNow
        }
        if terminationPreparationTask != nil {
            return .terminateLater
        }

        terminationPreparationTask = Task { @MainActor [weak self] in
            guard let self else {
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
                return
            }
            await desktopLaunchSettings.prepareForTermination()
            await startupTask?.value
            autoResetController?.prepareForTermination()
            let activitySaved = await activityMonitor.prepareForTermination()
            if !activitySaved {
                AppLog.app.error("退出 App 前数据保存失败")
            }
            let success = await keepAliveController.prepareForTermination()
            guard !Task.isCancelled else {
                return
            }
            if success {
                await BridgeHost.shared.stop()
                do { try await AppServerLogStore.shared.close() } catch {
                    AppLog.app.error("退出 App 前日志写入失败")
                }
            } else {
                desktopLaunchSettings.resumeAfterTerminationCancellation()
                await activityMonitor.resumeAfterTerminationCancellation()
                autoResetController?.resumeAfterTerminationCancellation()
            }
            terminationPreparationTask = nil
            hasPreparedForTermination = success
            NSApplication.shared.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }

    func openSettingsFromCommand() {
        statusItemController?.openSettingsFromCommand()
    }
}
