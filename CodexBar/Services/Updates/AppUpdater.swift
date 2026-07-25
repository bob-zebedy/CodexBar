import AppKit
import Combine
import Sparkle
import SwiftUI

/// Sparkle 更新状态桥接层, 同时驱动设置窗和菜单面板的更新提示
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    @Published private(set) var settingsStatusMessage: String?
    @Published private(set) var panelUpdateMessage: String?
    @Published private(set) var availableUpdateMessage: String?
    @Published private(set) var automaticallyChecksForUpdates = false

    var canConfigureAutomaticChecks: Bool {
        updaterController != nil
    }

    private var updaterController: SPUStandardUpdaterController?
    private var clearSettingsStatusMessageTask: Task<Void, Never>?
    private var isManualCheckInProgress = false
    private var manualCheckTimeoutTask: Task<Void, Never>?

    private static let missingUpdateConfigurationMessage = "未配置更新资源"
    /// Sparkle 可能既不回调 didFindValidUpdate / didNotFindUpdate 也不回调 didAbortWithError
    /// (后台检查已在进行, 或 feed 请求被放弃), 超时复位避免永久停留在手动检查态
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
        guard let updaterController else {
            showSettingsStatusMessage(Self.missingUpdateConfigurationMessage)
            return
        }

        if let availableUpdateMessage {
            showSettingsStatusMessage(availableUpdateMessage, autoDismissDelay: nil)
            return
        }

        beginManualCheck()
        showSettingsStatusMessage("正在检查更新")
        updaterController.updater.checkForUpdateInformation()
    }

    func startUpdate() {
        guard let updaterController else {
            showSettingsStatusMessage(Self.missingUpdateConfigurationMessage)
            return
        }

        NSApplication.shared.activate()
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
        guard let updaterController else {
            automaticallyChecksForUpdates = false
            showSettingsStatusMessage(Self.missingUpdateConfigurationMessage)
            return
        }

        updaterController.updater.automaticallyChecksForUpdates = isEnabled
        refreshAutomaticCheckSetting()
    }

    func refreshAutomaticCheckSetting() {
        automaticallyChecksForUpdates = updaterController?.updater.automaticallyChecksForUpdates ?? false
    }

    private func beginManualCheck() {
        isManualCheckInProgress = true

        manualCheckTimeoutTask?.cancel()
        manualCheckTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.manualCheckTimeout)
            guard !Task.isCancelled, let self else {
                return
            }

            isManualCheckInProgress = false
            manualCheckTimeoutTask = nil
        }
    }

    /// 手动检查态只影响结果去向 (设置窗 vs 菜单面板), 复位失败会永久隐藏面板更新提示
    private func finishManualCheck() {
        manualCheckTimeoutTask?.cancel()
        manualCheckTimeoutTask = nil
        isManualCheckInProgress = false
    }

    private func showSettingsStatusMessage(_ message: String, autoDismissDelay: Duration? = .seconds(3)) {
        clearSettingsStatusMessageTask?.cancel()
        settingsStatusMessage = message

        guard let autoDismissDelay else {
            clearSettingsStatusMessageTask = nil
            return
        }

        clearSettingsStatusMessageTask = Task { [weak self] in
            try? await Task.sleep(for: autoDismissDelay)
            guard !Task.isCancelled else { return }
            self?.settingsStatusMessage = nil
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
    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let message = "发现新版本: v\(item.displayVersionString)"
        availableUpdateMessage = message

        if isManualCheckInProgress {
            showSettingsStatusMessage(message, autoDismissDelay: nil)
        } else {
            panelUpdateMessage = message
        }

        finishManualCheck()
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: Error) {
        availableUpdateMessage = nil
        panelUpdateMessage = nil

        if isManualCheckInProgress {
            showSettingsStatusMessage("没有可用更新", autoDismissDelay: .milliseconds(1000))
        }

        finishManualCheck()
    }

    func updater(_: SPUUpdater, didAbortWithError _: Error) {
        guard isManualCheckInProgress else {
            return
        }

        showSettingsStatusMessage("检查更新失败")
        finishManualCheck()
    }
}
