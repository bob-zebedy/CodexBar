import AppKit
import os

/// 应用级对象装配点, 持有共享服务和 ViewModel 生命周期
@MainActor
final class CodexBarAppDelegate: NSObject, NSApplicationDelegate {
    private let codexStatusService = CodexStatusService()
    lazy var viewModel = CodexStatusViewModel(service: codexStatusService)
    let workflowViewModel = WorkflowViewModel()
    lazy var codexHookSettings = CodexHookSettings(codexStatusService: codexStatusService)
    lazy var codexCLINotificationSettings = CodexCLINotificationSettings(
        codexStatusService: codexStatusService
    )
    let activityProtectionSettings = ActivityProtectionSettings()
    lazy var activityMonitor = CodexActivityMonitor(
        codexHookSettings: codexHookSettings,
        activityProtectionSettings: activityProtectionSettings
    )
    lazy var keepAliveController = KeepAliveController(
        activityMonitor: activityMonitor,
        codexHookSettings: codexHookSettings
    )
    let syncSettings = WorkflowSyncSettings()
    let globalHotKeySettings = GlobalHotKeySettings()
    let menuBarQuotaSettings = MenuBarQuotaSettings()
    let mainPanelSettings = MainPanelSettings()
    let notificationSettings = NotificationSettings()
    let autoResetSettings = AutoResetSettings()
    let appUpdater = AppUpdater()

    private var statusItemController: StatusItemController?
    private var notificationService: CodexNotificationService?
    private var autoResetController: AutoResetController?
    private var terminationPreparationTask: Task<Void, Never>?
    private var hasPreparedForTermination = false

    // MARK: - App 生命周期

    func applicationDidFinishLaunching(_: Notification) {
        // Hook 子进程模式绝不会走到这里, 干净退出标志因此不会被它改写
        AppProcessDiagnostics.install()
        let controller = StatusItemController(
            viewModel: viewModel,
            workflowViewModel: workflowViewModel,
            codexHookSettings: codexHookSettings,
            codexCLINotificationSettings: codexCLINotificationSettings,
            activityMonitor: activityMonitor,
            syncSettings: syncSettings,
            globalHotKeySettings: globalHotKeySettings,
            menuBarQuotaSettings: menuBarQuotaSettings,
            mainPanelSettings: mainPanelSettings,
            notificationSettings: notificationSettings,
            autoResetSettings: autoResetSettings,
            keepAliveController: keepAliveController,
            appUpdater: appUpdater
        )
        controller.install()
        statusItemController = controller

        let notificationService = CodexNotificationService(
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
        activityMonitor.onInactivityProtectionTriggered = { [weak notificationService] notice in
            await notificationService?.notifyActivityProtection(notice) ?? false
        }
        activityMonitor.onInactivityProtectionInvalidated = { [weak notificationService] taskID, attemptID in
            notificationService?.invalidateActivityProtectionNotification(taskID: taskID, attemptID: attemptID)
        }
        activityMonitor.start()
        keepAliveController.start()
        logLaunchState()
    }

    func applicationWillTerminate(_: Notification) {
        AppLog.app.notice("App 即将退出: reason=userQuit")
        terminationPreparationTask?.cancel()
        terminationPreparationTask = nil
        AppProcessDiagnostics.recordCleanExit()
        statusItemController?.uninstall()
        autoResetController?.stop()
        keepAliveController.stop()
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
            let success = await keepAliveController.prepareForTermination()
            guard !Task.isCancelled else {
                return
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
            "hook=\(codexHookSettings.isEnabled ? 1 : 0)",
            "keepAlive=\(keepAliveController.isEnabled ? 1 : 0)",
            "keepAliveLimit=\(keepAliveController.maximumDuration.loggedHours)",
            "keepAliveBattery=\(keepAliveController.lowBatteryThreshold.rawValue)",
            "keepAliveWaiting=\(keepAliveController.keepsAwakeWhileWaiting ? 1 : 0)",
            "keepAliveDisplay=\(keepAliveController.keepsDisplayAwake ? 1 : 0)",
            "activityProtectionMinutes=\(activityProtectionSettings.inactivityDuration.loggedMinutes)",
            "sync=\(syncSettings.isEnabled ? 1 : 0)",
            "notification=\(notificationSettings.isEnabled ? 1 : 0)",
            "autoReset=\(autoResetSettings.isEnabled ? 1 : 0)",
            "autoResetLeadTimeSeconds=\(autoResetSettings.leadTime.rawValue)",
            "menuBarQuota=\(menuBarQuotaSettings.selection.rawValue)",
            "taskCenter=\(mainPanelSettings.showsTaskCenter ? 1 : 0)",
            "hotKey=\(globalHotKeySettings.shortcut == nil ? 0 : 1)"
        )
        AppLog.app.notice("App 已启动: \(state, privacy: .public)")
    }

    func openSettingsFromCommand() {
        statusItemController?.openSettingsFromCommand()
    }
}
