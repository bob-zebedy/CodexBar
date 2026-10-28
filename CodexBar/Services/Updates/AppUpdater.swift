import AppKit
import Combine
import os
import Sparkle

/// Sparkle 更新状态桥接层, 同时驱动设置窗和菜单面板的更新提示
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private var settingsCheckMessage: String?
    @Published private var pendingInstallation: (version: String, install: () -> Void)?
    @Published private(set) var availableUpdateMessage: String?
    @Published private(set) var automaticallyChecksForUpdates = false

    var settingsStatusMessage: String? {
        if let pendingInstallation {
            return String(
                localized: "updater.status.ready-to-install.settings",
                defaultValue: "\(pendingInstallation.version)"
            )
        }
        return settingsCheckMessage
    }

    var isUpdateReadyToInstall: Bool {
        pendingInstallation != nil
    }

    var canConfigureAutomaticChecks: Bool {
        updaterController != nil
    }

    private var updaterController: SPUStandardUpdaterController?
    private var clearSettingsStatusMessageTask: Task<Void, Never>?
    private var manualCheckTimeoutTask: Task<Void, Never>?

    private var isManualCheckInProgress: Bool {
        manualCheckTimeoutTask != nil
    }

    private static let missingUpdateConfigurationMessage = String(localized: "updater.status.missing-configuration")
    /// Sparkle 启动失败时检查请求可能直接返回, 不触发完成回调
    /// 兜底复位手动检查状态, 避免后续后台结果被误认为手动检查
    private static let manualCheckTimeout = Duration.seconds(30)

    init(bundle: Bundle = .main) {
        super.init()

        // 开发环境可能没有 Sparkle feed 或公钥
        // 此时保留设置 UI, 但禁用更新能力

        guard Self.hasUsableSparkleConfiguration(in: bundle) else {
            return
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        refreshAutomaticCheckSetting()
    }

    func checkForUpdates() {
        if availableUpdateMessage != nil {
            clearSettingsStatusMessage()
            return
        }

        guard let updaterController else {
            showSettingsStatusMessage(Self.missingUpdateConfigurationMessage)
            return
        }

        guard !updaterController.updater.sessionInProgress else { return }

        AppLog.app.notice("检查更新开始: trigger=\(LogTrigger.manual.rawValue, privacy: .public)")
        beginManualCheck()
        showSettingsStatusMessage(
            String(localized: "updater.status.checking")
        )
        updaterController.updater.checkForUpdateInformation()
    }

    func startUpdate() {
        if let pendingInstallation {
            // 退出被取消后仍可重试, 直到 Sparkle 结束更新会话才释放回调
            pendingInstallation.install()
            return
        }

        guard let updaterController else {
            showSettingsStatusMessage(Self.missingUpdateConfigurationMessage)
            return
        }

        guard updaterController.updater.canCheckForUpdates else { return }

        NSApplication.shared.activate()
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        guard let updaterController else {
            automaticallyChecksForUpdates = false
            showSettingsStatusMessage(Self.missingUpdateConfigurationMessage)
            return
        }

        AppLog.app.notice("自动检查更新变更: enabled=\(isEnabled ? 1 : 0)")
        updaterController.updater.automaticallyChecksForUpdates = isEnabled
        refreshAutomaticCheckSetting()
    }

    func refreshAutomaticCheckSetting() {
        automaticallyChecksForUpdates = updaterController?.updater.automaticallyChecksForUpdates ?? false
    }

    private func beginManualCheck() {
        manualCheckTimeoutTask?.cancel()
        manualCheckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.manualCheckTimeout)
            guard !Task.isCancelled, let self else {
                return
            }

            manualCheckTimeoutTask = nil
        }
    }

    /// 手动与自动检查共用 Sparkle 回调, 触发来源由当前手动检查状态判断
    private var checkTrigger: LogTrigger {
        isManualCheckInProgress ? .manual : .auto
    }

    /// 手动检查态决定是否在设置窗显示检查结果, 检查结束后统一复位
    private func finishManualCheck() {
        manualCheckTimeoutTask?.cancel()
        manualCheckTimeoutTask = nil
    }

    private func clearSettingsStatusMessage() {
        clearSettingsStatusMessageTask?.cancel()
        clearSettingsStatusMessageTask = nil
        settingsCheckMessage = nil
    }

    private func showSettingsStatusMessage(_ message: String, autoDismissDelay: Duration = .seconds(3)) {
        clearSettingsStatusMessage()
        settingsCheckMessage = message

        clearSettingsStatusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.settingsCheckMessage = nil
        }
    }

    private static func hasUsableSparkleConfiguration(in bundle: Bundle) -> Bool {
        guard
            let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let scheme = URL(string: feedURLString)?.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }

        return !publicKey.isEmpty
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(
        _: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // 保留当前安装会话, 避免重新检查时恢复已下载更新的信息
        pendingInstallation = (item.displayVersionString, immediateInstallHandler)
        return true
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error: Error?) {
        pendingInstallation = nil
        defer { finishManualCheck() }

        guard let error else { return }
        let errorCode = (error as NSError).code
        // 没有更新和稍后授权不作为检查失败处理
        guard errorCode != Int(SUError.noUpdateError.rawValue),
              errorCode != Int(SUError.installationAuthorizeLaterError.rawValue) else { return }

        let details = LogFields.joined(
            "trigger=\(checkTrigger.rawValue)",
            "detail=\(error.localizedDescription)"
        )
        AppLog.app.error("检查更新失败: \(details, privacy: .public)")

        if isManualCheckInProgress {
            showSettingsStatusMessage(
                String(localized: "updater.status.check-failed")
            )
        }
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let message = String(
            localized: "updater.status.update-available",
            defaultValue: "\(version)"
        )
        availableUpdateMessage = message
        let trigger = checkTrigger.rawValue
        let details = LogFields.joined(
            "trigger=\(trigger)",
            "result=available",
            "version=\(version)"
        )
        AppLog.app.notice("检查更新完成: \(details, privacy: .public)")

        if isManualCheckInProgress {
            clearSettingsStatusMessage()
        }

        finishManualCheck()
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: Error) {
        availableUpdateMessage = nil
        let trigger = checkTrigger.rawValue
        let details = LogFields.joined(
            "trigger=\(trigger)",
            "result=upToDate"
        )
        AppLog.app.notice("检查更新完成: \(details, privacy: .public)")

        if isManualCheckInProgress {
            showSettingsStatusMessage(
                String(localized: "updater.status.up-to-date"),
                autoDismissDelay: .milliseconds(1000)
            )
        }

        finishManualCheck()
    }
}
