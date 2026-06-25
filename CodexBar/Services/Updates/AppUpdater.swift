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

    private static let missingUpdateConfigurationMessage = "未配置更新资源"

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

        isManualCheckInProgress = true
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

        isManualCheckInProgress = false
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error _: Error) {
        availableUpdateMessage = nil
        panelUpdateMessage = nil

        if isManualCheckInProgress {
            showSettingsStatusMessage("没有可用更新", autoDismissDelay: .milliseconds(1000))
        }

        isManualCheckInProgress = false
    }

    func updater(_: SPUUpdater, didAbortWithError _: Error) {
        guard isManualCheckInProgress else {
            return
        }

        showSettingsStatusMessage("检查更新失败")
        isManualCheckInProgress = false
    }
}
