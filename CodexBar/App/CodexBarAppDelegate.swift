import AppKit
import os

/// 应用级对象装配点, 持有服务和 ViewModel 生命周期
@MainActor
final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    private lazy var codexStatusService = CodexStatusService(startup: appServerStartup)
    private lazy var appServerStartup = AppServerStartup()
    lazy var viewModel = CodexStatusViewModel(service: codexStatusService)
    let historyViewModel = HistoryViewModel()
    lazy var tuiNotificationSettings = TUINotificationSettings(
        codexStatusService: codexStatusService
    )
    let protectionSettings = ProtectionSettings()
    lazy var activityMonitor = ActivityMonitor(
        protectionSettings: protectionSettings
    )
    lazy var keepAliveController = KeepAliveController(
        activityMonitor: activityMonitor
    )
    let syncSettings = SyncSettings()
    let globalHotKeySettings = GlobalHotKeySettings()
    let menuBarQuotaSettings = MenuBarQuotaSettings()
    let mainPanelSettings = MainPanelSettings()
    let taskGlowSettings = TaskGlowSettings()
    let notificationSettings = NotificationSettings()
    let autoResetSettings = AutoResetSettings()
    let appUpdater = AppUpdater()

    private var statusItemController: StatusItemController?
    private var taskGlowController: TaskGlowController?
    private var notificationService: NotificationService?
    private var autoResetController: AutoResetController?
    private var startupTask: Task<Void, Never>?
    private var terminationPreparationTask: Task<Void, Never>?
    private var hasPreparedForTermination = false

    // MARK: - App 生命周期

    func applicationDidFinishLaunching(_: Notification) {
        AppProcessDiagnostics.install()
        let controller = StatusItemController(
            viewModel: viewModel,
            historyViewModel: historyViewModel,
            tuiNotificationSettings: tuiNotificationSettings,
            activityMonitor: activityMonitor,
            syncSettings: syncSettings,
            globalHotKeySettings: globalHotKeySettings,
            menuBarQuotaSettings: menuBarQuotaSettings,
            mainPanelSettings: mainPanelSettings,
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
        // 低电量触发会中断正在跑的任务, 得让用户知道是谁干的
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
        logLaunchState()
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

    func applicationWillTerminate(_: Notification) {
        AppLog.app.notice("App 即将退出: reason=userQuit")
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
                do { try await AppServerLogStore.shared.finish() } catch {
                    AppLog.app.error("退出 App 前日志写入失败")
                }
            }
            if !success {
                await activityMonitor.resumeAfterTerminationCancellation()
                autoResetController?.resumeAfterTerminationCancellation()
            }
            terminationPreparationTask = nil
            hasPreparedForTermination = success
            NSApplication.shared.reply(toApplicationShouldTerminate: success)
        }
        return .terminateLater
    }

    /// 启动时把各开关的初始值记成一条基线, 之后的变更日志都是相对这条基线的增量
    /// 排查时先看这条就知道当时的配置, 不必让用户逐项回忆
    private func logLaunchState() {
        // 先拼成普通字符串再交给 Logger, 避免在日志 autoclosure 中直接捕获属性
        let state = LogFields.joined(
            "version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")",
            "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-")",
            "keepAlive=\(keepAliveController.isEnabled ? 1 : 0)",
            "keepAliveLimit=\(keepAliveController.maximumDuration.loggedHours)",
            "keepAliveBattery=\(keepAliveController.lowBatteryThreshold.rawValue)",
            "keepAliveWaiting=\(keepAliveController.keepsAwakeWhileWaiting ? 1 : 0)",
            "keepAliveDisplay=\(keepAliveController.keepsDisplayAwake ? 1 : 0)",
            "protectionMinutes=\(protectionSettings.inactivityDuration.loggedMinutes)",
            "sync=\(syncSettings.isEnabled ? 1 : 0)",
            "notification=\(notificationSettings.isEnabled ? 1 : 0)",
            "autoReset=\(autoResetSettings.isEnabled ? 1 : 0)",
            "autoResetLeadTimeSeconds=\(autoResetSettings.leadTime.rawValue)",
            "menuBarQuota=\(menuBarQuotaSettings.selection.rawValue)",
            "mainPanel=\(mainPanelSettings.layout.visibleSections.map(\.rawValue).joined(separator: ","))",
            "hotKey=\(globalHotKeySettings.shortcut == nil ? 0 : 1)"
        )
        AppLog.app.notice("App 已启动: \(state, privacy: .public)")
    }

    func openSettingsFromCommand() {
        statusItemController?.openSettingsFromCommand()
    }
}
